// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MozaikAccount} from "../../src/account/MozaikAccount.sol";

/// @notice Forwards calls to the account so Echidna can drive the direct-call authority paths
///         (msg.sender == a signer) without signing UserOps. Each shim is a distinct address that
///         can be installed as the spending or recovery signer, so rotations move authority between
///         real, controllable principals.
contract SignerShim {
    MozaikAccount internal account;

    /// @dev Wired once by the harness after the proxy exists (the proxy needs the shim addresses at
    ///      init, so the account cannot be known at shim construction).
    function setAccount(MozaikAccount account_) external {
        require(address(account) == address(0), "account already set");
        account = account_;
    }

    function doExecute(address target, uint256 value, bytes calldata data) external {
        account.execute(target, value, data);
    }

    function doRotateSpending(address newSigner) external {
        account.rotateSpendingSigner(newSigner);
    }

    function doRotateRecovery(address newSigner) external {
        account.rotateRecoverySigner(newSigner);
    }

    function doUpgrade(address newImplementation) external {
        account.upgradeToAndCall(newImplementation, "");
    }
}

/// @notice Echidna fuzz target for MozaikAccount.
/// @dev Echidna cannot sign UserOps, so the EntryPoint path is out of reach. Instead the two signers
///      are shim contracts, which lets the fuzzer exercise every direct-call authority path:
///      the spending signer executes calls, the recovery signer rotates signers and upgrades. The
///      invariants assert the account's core guarantees survive any sequence of those calls:
///
///        - the two signers stay distinct and non-zero (the two-key separation never collapses);
///        - the spending key can never rotate a signer or upgrade;
///        - the recovery key can never execute an arbitrary call;
///        - the on-chain signers only ever change through an authorized recovery rotation.
///
///      Authorized rotations are routed through the current recovery shim and cycle within a fixed
///      pool of shims, so the state machine stays drivable after each rotation.
contract AccountEchidna {
    uint256 internal constant POOL_SIZE = 4;

    /// @dev A codeless address used as the target of probe executions. Calling an EOA with empty
    ///      data and zero value always succeeds, so a probe reverts only when the account's authority
    ///      check rejects the caller, never because the inner call failed.
    address internal constant BENIGN_TARGET = address(0xBEEF);

    MozaikAccount internal account;
    MozaikAccount internal altImplementation;
    SignerShim[POOL_SIZE] internal pool;

    uint256 internal currentSpendingIdx;
    uint256 internal currentRecoveryIdx;

    bool internal keySeparationBroken;

    constructor() {
        MozaikAccount impl = new MozaikAccount();
        altImplementation = new MozaikAccount();

        for (uint256 i = 0; i < POOL_SIZE; i++) {
            pool[i] = new SignerShim();
        }

        currentSpendingIdx = 0;
        currentRecoveryIdx = 1;

        bytes memory initData = abi.encodeCall(MozaikAccount.initialize, (address(pool[0]), address(pool[1])));
        account = MozaikAccount(payable(address(new ERC1967Proxy(address(impl), initData))));

        for (uint256 i = 0; i < POOL_SIZE; i++) {
            pool[i].setAccount(account);
        }
    }

    // Authorized paths: driven through the current recovery / spending shim.

    /// @notice Recovery rotates the spending signer to another pooled shim.
    function rotateSpending(uint8 sel) external {
        uint256 idx = sel % POOL_SIZE;

        try pool[currentRecoveryIdx].doRotateSpending(address(pool[idx])) {
            currentSpendingIdx = idx;
        } catch {}
    }

    /// @notice Recovery rotates the recovery signer to another pooled shim.
    function rotateRecovery(uint8 sel) external {
        uint256 idx = sel % POOL_SIZE;

        try pool[currentRecoveryIdx].doRotateRecovery(address(pool[idx])) {
            currentRecoveryIdx = idx;
        } catch {}
    }

    /// @notice Spending executes a call. Target is pinned to an EOA so a nested call can never reach
    ///         the account's rotation entrypoints and mutate a signer outside the tracked path.
    function spendingExecute(uint256 value, bytes calldata data) external {
        try pool[currentSpendingIdx].doExecute(BENIGN_TARGET, value, data) {} catch {}
    }

    /// @notice Recovery upgrades to an alternate implementation (an authorized recovery power).
    function recoveryUpgrade() external {
        try pool[currentRecoveryIdx].doUpgrade(address(altImplementation)) {} catch {}
    }

    // Forbidden paths: each must revert. A success flips keySeparationBroken.

    /// @notice The spending key attempts a rotation to a valid free signer. Must be rejected.
    function spendingTriesRotate() external {
        try pool[currentSpendingIdx].doRotateSpending(address(pool[_freeIndex()])) {
            keySeparationBroken = true;
        } catch {}
    }

    /// @notice The spending key attempts an upgrade. Must be rejected.
    function spendingTriesUpgrade() external {
        try pool[currentSpendingIdx].doUpgrade(address(altImplementation)) {
            keySeparationBroken = true;
        } catch {}
    }

    /// @notice The recovery key attempts to execute a call. Must be rejected.
    function recoveryTriesExecute() external {
        try pool[currentRecoveryIdx].doExecute(BENIGN_TARGET, 0, "") {
            keySeparationBroken = true;
        } catch {}
    }

    // Invariants.

    /// @notice The two signers are always distinct: the two-key separation never collapses.
    function echidna_signers_distinct() external view returns (bool) {
        return account.spendingSigner() != account.recoverySigner();
    }

    /// @notice Neither signer is ever the zero address.
    function echidna_signers_nonzero() external view returns (bool) {
        return account.spendingSigner() != address(0) && account.recoverySigner() != address(0);
    }

    /// @notice The spending key never rotates or upgrades; the recovery key never executes.
    function echidna_key_separation_holds() external view returns (bool) {
        return !keySeparationBroken;
    }

    /// @notice The on-chain signers only change through an authorized recovery rotation, so they
    ///         always equal the pooled shims the harness recorded from those rotations.
    function echidna_signers_match_ghost() external view returns (bool) {
        return account.spendingSigner() == address(pool[currentSpendingIdx])
            && account.recoverySigner() == address(pool[currentRecoveryIdx]);
    }

    /// @notice An address that is neither signer nor the EntryPoint cannot execute.
    function echidna_stranger_cannot_execute() external returns (bool) {
        (bool ok,) = address(account).call(abi.encodeCall(account.execute, (BENIGN_TARGET, 0, "")));
        return !ok;
    }

    /// @dev The lowest pool index that is neither the current spending nor recovery signer. With
    ///      POOL_SIZE >= 3 and two signers in use, at least one such index always exists.
    function _freeIndex() internal view returns (uint256) {
        for (uint256 i = 0; i < POOL_SIZE; i++) {
            if (i != currentSpendingIdx && i != currentRecoveryIdx) return i;
        }

        return 0;
    }
}
