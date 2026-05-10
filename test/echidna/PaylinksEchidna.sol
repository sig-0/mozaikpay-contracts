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

    bytes32[] internal _ids;
    mapping(bytes32 => bool) internal _seen;
    mapping(bytes32 => MozaikLinks.Status) internal _lastStatus;

    address internal constant SENDER = address(0xA11CE);

    constructor() {
        usdc = new MintableERC20();
        links = new MozaikLinks(IERC20(address(usdc)));
    }

    // -------------------------------------------------------------------------
    // Action wrappers — fuzzer drives these with random inputs
    // -------------------------------------------------------------------------

    function tryCreate(uint96 idSeed, uint96 pubKeySeed, uint96 amount, uint40 expiryOffset) external {
        if (amount == 0) return;
        if (expiryOffset == 0) return;
        if (pubKeySeed == 0) return; // claimSigner == address(0) is rejected; skip.

        bytes32 id = keccak256(abi.encode("link", idSeed));
        if (_seen[id]) return;

        // Cap amount to avoid silly values that overflow ghosts; 1B units is plenty.
        if (amount > 1_000_000_000) amount = 1_000_000_000;

        uint40 expiresAt = uint40(block.timestamp) + uint40(expiryOffset);
        if (expiresAt <= block.timestamp) return;

        address claimSigner = address(uint160(uint256(keccak256(abi.encode("k", pubKeySeed)))));
        if (claimSigner == address(0)) return;

        usdc.mint(SENDER, amount);

        // The "sender" is a fixed pseudo-EOA so revoke is testable from a single principal.
        // Echidna can't `vm.prank`; we route through a tiny shim that approves+forwards.
        _proxyCreate(id, claimSigner, amount, expiresAt);

        _ids.push(id);
        _seen[id] = true;
        activeTotal += amount;
        createCount += 1;
        _trackStatus(id);
    }

    function tryRevoke(uint96 idIndex) external {
        if (_ids.length == 0) return;
        bytes32 id = _ids[idIndex % _ids.length];

        MozaikLinks.Link memory link = links.getLink(id);
        if (link.status != MozaikLinks.Status.Active) return;
        if (block.timestamp >= link.expiresAt) return; // revoke pre-expiry only

        try EchidnaSenderShim(senderShim()).revoke(id) {
            activeTotal -= link.amount;
            revokeCount += 1;
        } catch {
            // Revert is acceptable in fuzzing — fuzzer ignores and moves on.
        }
        _trackStatus(id);
    }

    function trySweepExpired(uint96 idIndex) external {
        if (_ids.length == 0) return;
        bytes32 id = _ids[idIndex % _ids.length];

        MozaikLinks.Link memory link = links.getLink(id);
        if (link.status != MozaikLinks.Status.Active) return;
        if (block.timestamp < link.expiresAt) return;

        try links.sweepExpired(id) {
            activeTotal -= link.amount;
            sweepCount += 1;
        } catch {}
        _trackStatus(id);
    }

    function tryDust(uint96 amount) external {
        if (amount == 0) return;
        usdc.mint(address(this), amount);
        usdc.transfer(address(links), amount);
    }

    // -------------------------------------------------------------------------
    // Properties (Echidna asserts each returns true after every fuzz call)
    // -------------------------------------------------------------------------

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

    // -------------------------------------------------------------------------
    // Internal plumbing
    // -------------------------------------------------------------------------

    EchidnaSenderShim internal _senderShim;

    function senderShim() public returns (address) {
        if (address(_senderShim) == address(0)) {
            _senderShim = new EchidnaSenderShim(links, usdc);
        }
        return address(_senderShim);
    }

    function _proxyCreate(bytes32 id, address claimSigner, uint256 amount, uint40 expiresAt) internal {
        EchidnaSenderShim shim = EchidnaSenderShim(senderShim());
        usdc.mint(address(shim), amount);
        shim.create(id, claimSigner, amount, expiresAt);
    }

    function _trackStatus(bytes32 id) internal {
        MozaikLinks.Status current = links.getLink(id).status;
        MozaikLinks.Status prev = _lastStatus[id];
        if (uint256(current) < uint256(prev)) statusEverWentBackwards = true;
        _lastStatus[id] = current;
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

    function create(bytes32 id, address claimSigner, uint256 amount, uint40 expiresAt) external {
        links.create(id, claimSigner, amount, expiresAt);
    }

    function revoke(bytes32 id) external {
        links.revoke(id);
    }
}
