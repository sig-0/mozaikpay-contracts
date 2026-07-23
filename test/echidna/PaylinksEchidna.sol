// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MozaikPaylinks} from "../../src/paylinks/MozaikPaylinks.sol";

/// @notice Minimal ERC20 with a public mint, for Echidna runs.
contract MintableERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Echidna fuzz target for MozaikPaylinks.
/// @dev Echidna can't generate valid ECDSA signatures, so this target drives the
///      non-cryptographic state machine: create, reclaim (sender-only pre-expiry,
///      permissionless post-expiry), direct dust transfers, and the invariants the
///      contract must hold across them. The claim path needs a real signature and is
///      covered by the Foundry invariant suite (MozaikPaylinks.invariant.t.sol).
///
///      Ghost accounting lets the properties pin down the escrow's balance exactly:
///        - activeTotal: sum of amounts in still-active links (create adds, reclaim subtracts).
///        - createdTotal / dustTotal / reclaimedTotal: every unit that entered escrow via a
///          create or a dust transfer, and every unit reclaimed back out to the sender.
///      With no claim path, the balance is fully determined: created + dust - reclaimed.
contract PaylinksEchidna {
    MozaikPaylinks public links;
    MintableERC20 public usdc;

    uint256 public activeTotal;
    uint256 public createdTotal;
    uint256 public dustTotal;
    uint256 public reclaimedTotal;
    uint256 public createCount;
    uint256 public reclaimSenderCount;
    uint256 public reclaimPermissionlessCount;
    bool public statusEverWentBackwards;

    address[] internal _signers;
    mapping(address => bool) internal _seen;
    mapping(address => MozaikPaylinks.Status) internal _lastStatus;

    constructor() {
        usdc = new MintableERC20();
        links = new MozaikPaylinks(IERC20(address(usdc)));
    }

    function tryCreate(uint96 pubKeySeed, uint96 amount, uint64 expiryOffset) external {
        if (amount == 0) return;
        if (expiryOffset == 0) return;
        if (pubKeySeed == 0) return; // claimSigner == address(0) is rejected; skip.

        address claimSigner = address(uint160(uint256(keccak256(abi.encode("k", pubKeySeed)))));
        if (claimSigner == address(0)) return;
        if (_seen[claimSigner]) return;

        // Cap amount to avoid silly values that overflow ghosts; 1B units is plenty.
        if (amount > 1_000_000_000) amount = 1_000_000_000;

        // Cap expiry to Echidna's default maxTimeDelay window (1 week) so post-expiry reclaim is reachable.
        if (expiryOffset > 7 days) expiryOffset = uint64((uint256(expiryOffset) % 7 days) + 1);

        uint64 expiresAt = uint64(block.timestamp) + uint64(expiryOffset);
        if (expiresAt <= block.timestamp) return;

        // The sender is a fixed shim contract so the sender-only reclaim path is testable from a
        // single principal. Echidna can't vm.prank; the shim approves and forwards on its behalf.
        _proxyCreate(claimSigner, amount, expiresAt);

        _signers.push(claimSigner);
        _seen[claimSigner] = true;
        activeTotal += amount;
        createdTotal += amount;
        createCount += 1;

        _trackStatus(claimSigner);
    }

    function tryReclaimAsSender(uint96 idIndex) external {
        if (_signers.length == 0) return;
        address claimSigner = _signers[idIndex % _signers.length];

        MozaikPaylinks.Link memory link = links.getLink(claimSigner);
        if (link.status != MozaikPaylinks.Status.Active) return;

        try EchidnaSenderShim(senderShim()).reclaim(claimSigner) {
            activeTotal -= link.amount;
            reclaimedTotal += link.amount;
            reclaimSenderCount += 1;
        } catch {
            // Revert is acceptable in fuzzing (fuzzer ignores and moves on)
        }

        _trackStatus(claimSigner);
    }

    function tryReclaimPermissionless(uint96 idIndex) external {
        if (_signers.length == 0) return;
        address claimSigner = _signers[idIndex % _signers.length];

        MozaikPaylinks.Link memory link = links.getLink(claimSigner);
        if (link.status != MozaikPaylinks.Status.Active) return;
        if (block.timestamp < link.expiresAt) return;

        try links.reclaim(claimSigner) {
            activeTotal -= link.amount;
            reclaimedTotal += link.amount;
            reclaimPermissionlessCount += 1;
        } catch {}

        _trackStatus(claimSigner);
    }

    function tryDust(uint96 amount) external {
        if (amount == 0) return;

        usdc.mint(address(this), amount);
        usdc.transfer(address(links), amount);
        dustTotal += amount;
    }

    /// @notice Sum of currently-active link amounts must never exceed the escrow's USDC balance.
    function echidna_active_amount_le_balance() external view returns (bool) {
        return activeTotal <= usdc.balanceOf(address(links));
    }

    /// @notice The escrow balance is exactly what entered (create + dust) minus what was reclaimed.
    function echidna_escrow_conserved() external view returns (bool) {
        return usdc.balanceOf(address(links)) == createdTotal + dustTotal - reclaimedTotal;
    }

    /// @notice Every reclaim returns funds to the original sender (the shim), never to the caller,
    ///         so the shim's balance equals the total ever reclaimed.
    function echidna_reclaim_pays_sender() external view returns (bool) {
        return usdc.balanceOf(address(_senderShim)) == reclaimedTotal;
    }

    /// @notice A link's status enum value is monotonic: None(0) -> Active(1) -> {Claimed(2), Reclaimed(3)}.
    function echidna_status_monotonic() external view returns (bool) {
        return !statusEverWentBackwards;
    }

    EchidnaSenderShim internal _senderShim;

    function senderShim() public returns (address) {
        if (address(_senderShim) == address(0)) {
            _senderShim = new EchidnaSenderShim(links, usdc);
        }

        return address(_senderShim);
    }

    function _proxyCreate(address claimSigner, uint256 amount, uint64 expiresAt) internal {
        EchidnaSenderShim shim = EchidnaSenderShim(senderShim());

        usdc.mint(address(shim), amount);
        shim.create(claimSigner, amount, expiresAt);
    }

    function _trackStatus(address claimSigner) internal {
        MozaikPaylinks.Status current = links.getLink(claimSigner).status;
        MozaikPaylinks.Status prev = _lastStatus[claimSigner];

        if (uint256(current) < uint256(prev)) statusEverWentBackwards = true;

        _lastStatus[claimSigner] = current;
    }
}

/// @dev Standalone "sender" contract so reclaim (msg.sender == link.sender) and create work without cheatcodes.
contract EchidnaSenderShim {
    MozaikPaylinks public links;
    MintableERC20 public usdc;

    constructor(MozaikPaylinks _links, MintableERC20 _usdc) {
        links = _links;
        usdc = _usdc;

        usdc.approve(address(links), type(uint256).max);
    }

    function create(address claimSigner, uint256 amount, uint64 expiresAt) external {
        links.create(claimSigner, amount, expiresAt);
    }

    function reclaim(address claimSigner) external {
        links.reclaim(claimSigner);
    }
}
