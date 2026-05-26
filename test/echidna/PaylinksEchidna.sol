// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MozaikLinks} from "../../src/paylinks/MozaikLinks.sol";

/// @notice Minimal ERC20 with a public mint, for Echidna runs.
contract MintableERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Echidna fuzz target for MozaikLinks.
/// @dev Echidna can't generate valid ECDSA signatures, so this target focuses on the
///      non-cryptographic state machine: createLink, revoke, sweepExpired, direct dust
///      transfers, and the invariants the contract must hold across them.
///
///      Key invariant: sum(active amounts) <= USDC.balanceOf(escrow). The handler tracks
///      a ghost `activeTotal` that increments on successful create and decrements on
///      successful revoke/sweep; the property compares against the contract's USDC balance.
contract PaylinksEchidna {
    MozaikLinks public links;
    MintableERC20 public usdc;

    uint256 public activeTotal;
    uint256 public createCount;
    uint256 public revokeCount;
    uint256 public sweepCount;
    bool public statusEverWentBackwards;

    address[] internal _signers;
    mapping(address => bool) internal _seen;
    mapping(address => MozaikLinks.Status) internal _lastStatus;

    address internal constant SENDER = address(0xA11CE);

    constructor() {
        usdc = new MintableERC20();
        links = new MozaikLinks(IERC20(address(usdc)));
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

        // Cap expiry to Echidna's default maxTimeDelay window (1 week) so sweepExpired is reachable.
        if (expiryOffset > 7 days) expiryOffset = uint64((uint256(expiryOffset) % 7 days) + 1);

        uint64 expiresAt = uint64(block.timestamp) + uint64(expiryOffset);
        if (expiresAt <= block.timestamp) return;

        usdc.mint(SENDER, amount);

        // The "sender" is a fixed pseudo-EOA so revoke is testable from a single principal.
        // Echidna can't `vm.prank`; we route through a tiny shim that approves+forwards.
        _proxyCreate(claimSigner, amount, expiresAt);

        _signers.push(claimSigner);
        _seen[claimSigner] = true;
        activeTotal += amount;
        createCount += 1;

        _trackStatus(claimSigner);
    }

    function tryRevoke(uint96 idIndex) external {
        if (_signers.length == 0) return;
        address claimSigner = _signers[idIndex % _signers.length];

        MozaikLinks.Link memory link = links.getLink(claimSigner);
        if (link.status != MozaikLinks.Status.Active) return;
        if (block.timestamp >= link.expiresAt) return; // revoke pre-expiry only

        try EchidnaSenderShim(senderShim()).revoke(claimSigner) {
            activeTotal -= link.amount;
            revokeCount += 1;
        } catch {
            // Revert is acceptable in fuzzing (fuzzer ignores and moves on)
        }

        _trackStatus(claimSigner);
    }

    function trySweepExpired(uint96 idIndex) external {
        if (_signers.length == 0) return;
        address claimSigner = _signers[idIndex % _signers.length];

        MozaikLinks.Link memory link = links.getLink(claimSigner);
        if (link.status != MozaikLinks.Status.Active) return;
        if (block.timestamp < link.expiresAt) return;

        try links.sweepExpired(claimSigner) {
            activeTotal -= link.amount;
            sweepCount += 1;
        } catch {}

        _trackStatus(claimSigner);
    }

    function tryDust(uint96 amount) external {
        if (amount == 0) return;

        usdc.mint(address(this), amount);
        usdc.transfer(address(links), amount);
    }

    /// @notice Sum of currently-active link amounts must never exceed the escrow's USDC balance.
    function echidna_active_amount_le_balance() external view returns (bool) {
        return activeTotal <= usdc.balanceOf(address(links));
    }

    /// @notice A link's status enum value is monotonic: None(0) -> Active(1) -> {Claimed(2), Revoked(3), Swept(4)}.
    function echidna_status_monotonic() external view returns (bool) {
        return !statusEverWentBackwards;
    }

    /// @notice Read-only sanity: the contract holds at least the sum of all unrevoked, unswept
    ///         active link amounts, and any dust on top.
    function echidna_balance_ge_active() external view returns (bool) {
        return usdc.balanceOf(address(links)) >= activeTotal;
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
        MozaikLinks.Status current = links.getLink(claimSigner).status;
        MozaikLinks.Status prev = _lastStatus[claimSigner];

        if (uint256(current) < uint256(prev)) statusEverWentBackwards = true;

        _lastStatus[claimSigner] = current;
    }
}

/// @dev Standalone "sender" contract so revoke (msg.sender == link.sender) and create work without cheatcodes.
contract EchidnaSenderShim {
    MozaikLinks public links;
    MintableERC20 public usdc;

    constructor(MozaikLinks _links, MintableERC20 _usdc) {
        links = _links;
        usdc = _usdc;

        usdc.approve(address(links), type(uint256).max);
    }

    function create(address claimSigner, uint256 amount, uint64 expiresAt) external {
        links.create(claimSigner, amount, expiresAt);
    }

    function revoke(address claimSigner) external {
        links.revoke(claimSigner);
    }
}
