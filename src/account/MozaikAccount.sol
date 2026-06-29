// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";
import {IAccountExecute} from "account-abstraction/interfaces/IAccountExecute.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {Exec} from "account-abstraction/utils/Exec.sol";
import {SIG_VALIDATION_FAILED, SIG_VALIDATION_SUCCESS} from "account-abstraction/core/Helpers.sol";

/**
 * @title MozaikAccount
 * @notice ERC-4337 smart account used by MozaikPay. Deployed as a UUPS proxy via MozaikAccountFactory.
 * @dev Two keys govern the account with strictly separated powers:
 *
 *      - spendingSigner  (secp256k1, lives on the user's device)
 *        Can execute arbitrary calls (execute / executeBatch). Rotated only by the recovery key.
 *
 *      - recoverySigner  (secp256k1, stored in a secure backup)
 *        Can rotate either signer and authorize contract upgrades.
 *        Cannot execute arbitrary calls.
 *
 *      EntryPoint operations are wrapped in executeUserOp (ERC-4337 IAccountExecute): the callData
 *      is executeUserOp's selector followed by the inner action (execute/executeBatch for the
 *      spending key; rotateSpendingSigner/rotateRecoverySigner/upgradeToAndCall for the recovery
 *      key). _validateSignature enforces key separation on the inner selector before ECDSA recovery,
 *      and executeUserOp re-recovers the signer at execution time and checks it against the current
 *      signer, so a key rotated by an earlier operation in the same bundle can no longer act.
 *
 *      The two signers must always be distinct addresses. Equality is rejected at
 *      initialization and on either rotation, so the two-key separation cannot collapse
 *      into a single key that holds both spend and upgrade authority.
 */
contract MozaikAccount is BaseAccount, UUPSUpgradeable, Initializable, IAccountExecute {
    /**
     * @dev First byte of userOp.signature: selects which key signed the operation.
     */
    uint8 private constant SIG_SPENDING = 0x00;
    uint8 private constant SIG_RECOVERY = 0x01;

    /**
     * @dev ERC-4337 EntryPoint v0.9 deployed on all supported chains.
     */
    address internal constant ENTRY_POINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;

    /**
     * @dev ERC-7201 namespaced storage for MozaikAccount state.
     *      Slot: keccak256(abi.encode(uint256(keccak256("mozaik.MozaikAccount")) - 1)) & ~bytes32(uint256(0xff))
     */
    /// @custom:storage-location erc7201:mozaik.MozaikAccount
    struct MozaikAccountStorage {
        address spendingSigner;
        address recoverySigner;
    }

    bytes32 private constant _MOZAIK_ACCOUNT_STORAGE_LOCATION =
        0xde7593516e586b97e9201bf35c885cdde0d6f8f83f49a0ddd00230e192220c00;

    function _getMozaikAccountStorage() private pure returns (MozaikAccountStorage storage $) {
        assembly {
            $.slot := _MOZAIK_ACCOUNT_STORAGE_LOCATION
        }
    }

    /**
     * @notice Emitted when the spending signer is replaced.
     * @param previousSigner The signer being replaced.
     * @param newSpendingSigner The new spending signer.
     */
    event SpendingSignerRotated(address indexed previousSigner, address indexed newSpendingSigner);

    /**
     * @notice Emitted when the recovery signer is replaced.
     * @param previousSigner The signer being replaced.
     * @param newRecoverySigner The new recovery signer.
     */
    event RecoverySignerRotated(address indexed previousSigner, address indexed newRecoverySigner);

    /**
     * @notice Thrown when a caller is not authorized to invoke a function.
     * @param caller The address that attempted the call.
     */
    error UnauthorizedCaller(address caller);

    /**
     * @notice Thrown when a zero address is supplied where one is not permitted.
     */
    error ZeroAddress();

    /**
     * @notice Thrown when the spending and recovery signers would be set to the same address.
     */
    error DuplicateSigners();

    /**
     * @notice Thrown when a rotation would set a signer to its current value.
     */
    error SignerUnchanged();

    /**
     * @notice Thrown when the signer recovered for an operation is no longer the current signer
     *         at execution time, e.g. an earlier operation in the same bundle rotated the key.
     */
    error StaleAuthority();

    /**
     * @notice Thrown when a wrapped operation's inner selector is not dispatchable for its
     *         signature type.
     */
    error UnsupportedExecution();

    receive() external payable {}

    /**
     * @dev Disables initializers on the implementation contract so it cannot be
     *      initialized directly - only proxies should be initialized.
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice The key authorized to execute calls on behalf of this account.
     */
    function spendingSigner() public view returns (address) {
        return _getMozaikAccountStorage().spendingSigner;
    }

    /**
     * @notice The key authorized to rotate signers and authorize upgrades.
     */
    function recoverySigner() public view returns (address) {
        return _getMozaikAccountStorage().recoverySigner;
    }

    /**
     * @notice Initialises the proxy with its two signers. Called once by the factory at deployment.
     * @param spender  The initial spending signer (device key).
     * @param recovery The initial recovery signer (backup key).
     */
    function initialize(address spender, address recovery) external initializer {
        if (spender == address(0) || recovery == address(0)) revert ZeroAddress();
        if (spender == recovery) revert DuplicateSigners();

        MozaikAccountStorage storage $ = _getMozaikAccountStorage();
        $.spendingSigner = spender;
        $.recoverySigner = recovery;
    }

    /**
     * @inheritdoc BaseAccount
     */
    function entryPoint() public view virtual override returns (IEntryPoint) {
        return IEntryPoint(ENTRY_POINT_V09);
    }

    /**
     * @notice Replaces the spending signer. Callable only via a recovery-key UserOp or
     *         directly by the current recoverySigner.
     * @param newSpendingSigner The address to install as the new spending signer.
     */
    function rotateSpendingSigner(address newSpendingSigner) external {
        _requireRecovery();
        _rotateSpendingSigner(newSpendingSigner);
    }

    /**
     * @notice Replaces the recovery signer. Callable only via a recovery-key UserOp or
     *         directly by the current recoverySigner.
     * @param newRecoverySigner The address to install as the new recovery signer.
     */
    function rotateRecoverySigner(address newRecoverySigner) external {
        _requireRecovery();
        _rotateRecoverySigner(newRecoverySigner);
    }

    /**
     * @dev Replaces the spending signer. Shared by rotateSpendingSigner and executeUserOp; assumes
     *      recovery authority has already been checked.
     */
    function _rotateSpendingSigner(address newSpendingSigner) private {
        if (newSpendingSigner == address(0)) revert ZeroAddress();

        MozaikAccountStorage storage $ = _getMozaikAccountStorage();
        if (newSpendingSigner == $.recoverySigner) revert DuplicateSigners();
        if (newSpendingSigner == $.spendingSigner) revert SignerUnchanged();

        address previousSigner = $.spendingSigner;
        $.spendingSigner = newSpendingSigner;

        emit SpendingSignerRotated(previousSigner, newSpendingSigner);
    }

    /**
     * @dev Replaces the recovery signer. Shared by rotateRecoverySigner and executeUserOp; assumes
     *      recovery authority has already been checked.
     */
    function _rotateRecoverySigner(address newRecoverySigner) private {
        if (newRecoverySigner == address(0)) revert ZeroAddress();

        MozaikAccountStorage storage $ = _getMozaikAccountStorage();
        if (newRecoverySigner == $.spendingSigner) revert DuplicateSigners();
        if (newRecoverySigner == $.recoverySigner) revert SignerUnchanged();

        address previousSigner = $.recoverySigner;
        $.recoverySigner = newRecoverySigner;

        emit RecoverySignerRotated(previousSigner, newRecoverySigner);
    }

    /**
     * @dev Validates the UserOp signature. Called by the EntryPoint before execution.
     *
     *      userOp.signature layout: sigType(1) || ecdsaSig(65)
     *      userOp.callData layout:  executeUserOp selector(4) || inner selector(4) || inner args
     *        - 0x00 (SIG_SPENDING): inner selector must be execute or executeBatch; ECDSA must recover
     *          spendingSigner.
     *        - 0x01 (SIG_RECOVERY): inner selector must be rotateSpendingSigner, rotateRecoverySigner, or
     *          upgradeToAndCall; ECDSA must recover recoverySigner.
     *
     *      Key separation is enforced here on the inner selector before ECDSA recovery. Execution-time
     *      signer freshness is re-checked in executeUserOp. Returns SIG_VALIDATION_FAILED on any
     *      failure (never reverts), so bundlers can simulate and handleOps aborts via AA24.
     */
    function _validateSignature(PackedUserOperation calldata userOp, bytes32 userOpHash)
        internal
        virtual
        override
        returns (uint256)
    {
        if (userOp.signature.length != 66) return SIG_VALIDATION_FAILED;

        uint8 sigType = uint8(userOp.signature[0]);
        bytes calldata ecdsaSig = userOp.signature[1:];

        if (sigType != SIG_SPENDING && sigType != SIG_RECOVERY) {
            return SIG_VALIDATION_FAILED;
        }

        if (userOp.callData.length < 8) return SIG_VALIDATION_FAILED;
        if (bytes4(userOp.callData[:4]) != IAccountExecute.executeUserOp.selector) return SIG_VALIDATION_FAILED;

        bytes4 innerSelector = bytes4(userOp.callData[4:8]);

        MozaikAccountStorage storage $ = _getMozaikAccountStorage();

        if (sigType == SIG_SPENDING) {
            if (innerSelector != this.execute.selector && innerSelector != this.executeBatch.selector) {
                return SIG_VALIDATION_FAILED;
            }

            (address spendingRecovered, ECDSA.RecoverError spendingErr,) = ECDSA.tryRecover(userOpHash, ecdsaSig);

            if (spendingErr != ECDSA.RecoverError.NoError || spendingRecovered != $.spendingSigner) {
                return SIG_VALIDATION_FAILED;
            }

            return SIG_VALIDATION_SUCCESS;
        }

        // Recovery signer path
        if (
            innerSelector != this.rotateSpendingSigner.selector && innerSelector != this.rotateRecoverySigner.selector
                && innerSelector != this.upgradeToAndCall.selector
        ) {
            return SIG_VALIDATION_FAILED;
        }

        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(userOpHash, ecdsaSig);

        if (err != ECDSA.RecoverError.NoError || recovered != $.recoverySigner) return SIG_VALIDATION_FAILED;

        return SIG_VALIDATION_SUCCESS;
    }

    /**
     * @notice Executes a validated UserOp. The EntryPoint routes here when callData begins with this
     *         selector (ERC-4337 IAccountExecute), passing the full operation and its hash.
     * @dev Re-recovers the signer from userOpHash and, when a signer is recoverable, requires it to
     *      still equal the current signer for the operation's key type before dispatching the inner
     *      action. This avoids the issue where an operation validated against an old signer could still
     *      execute after an earlier operation in the same bundle rotated that signer.
     *
     *      userOp.callData is executeUserOp's selector followed by the inner call; the inner call is
     *      userOp.callData[4:].
     * @param userOp     The operation the EntryPoint validated.
     * @param userOpHash The hash the signature is checked against.
     */
    function executeUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash) external override {
        _requireFromEntryPoint();

        uint8 sigType = uint8(userOp.signature[0]);
        bytes calldata ecdsaSig = userOp.signature[1:];
        bytes calldata innerCallData = userOp.callData[4:];
        bytes4 innerSelector = bytes4(innerCallData[:4]);

        MozaikAccountStorage storage $ = _getMozaikAccountStorage();

        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(userOpHash, ecdsaSig);

        // Skipping the freshness check when ECDSA recovery fails leans on two invariants:
        //   1. handleOps aborts the whole bundle when validateUserOp reports a bad signature, so
        //      a real on-chain execution is only ever reached for an op whose signature validated.
        //   2. _validateSignature rejects any signature that does not recover the current signer, so a
        //      validated op is always recoverable here.
        // This means an unrecoverable signature occurs only during off-chain gas estimation, never in a
        // state-changing execution; letting it through there allows for easy simulations.
        bool recoverable = err == ECDSA.RecoverError.NoError;

        if (sigType == SIG_SPENDING) {
            if (recoverable && recovered != $.spendingSigner) revert StaleAuthority();

            if (innerSelector == this.execute.selector) {
                (address target, uint256 value, bytes memory data) =
                    abi.decode(innerCallData[4:], (address, uint256, bytes));
                _executeCall(target, value, data);

                return;
            }

            if (innerSelector == this.executeBatch.selector) {
                _executeBatch(abi.decode(innerCallData[4:], (Call[])));

                return;
            }

            revert UnsupportedExecution();
        }

        if (sigType == SIG_RECOVERY) {
            if (recoverable && recovered != $.recoverySigner) revert StaleAuthority();

            if (innerSelector == this.rotateSpendingSigner.selector) {
                _rotateSpendingSigner(abi.decode(innerCallData[4:], (address)));

                return;
            }

            if (innerSelector == this.rotateRecoverySigner.selector) {
                _rotateRecoverySigner(abi.decode(innerCallData[4:], (address)));

                return;
            }

            if (innerSelector == this.upgradeToAndCall.selector) {
                (address newImplementation, bytes memory data) = abi.decode(innerCallData[4:], (address, bytes));
                upgradeToAndCall(newImplementation, data);

                return;
            }

            revert UnsupportedExecution();
        }

        revert UnsupportedExecution();
    }

    /**
     * @dev Performs a single call. Shared by executeUserOp's spending path; mirrors BaseAccount.execute.
     */
    function _executeCall(address target, uint256 value, bytes memory data) private {
        bool ok = Exec.call(target, value, data, gasleft());

        if (!ok) Exec.revertWithReturnData();
    }

    /**
     * @dev Performs a batch of calls, reverting on the first failure. Shared by executeUserOp's
     *      spending path; mirrors BaseAccount.executeBatch.
     */
    function _executeBatch(Call[] memory calls) private {
        uint256 callsLength = calls.length;

        for (uint256 i = 0; i < callsLength; i++) {
            Call memory call = calls[i];

            bool ok = Exec.call(call.target, call.value, call.data, gasleft());
            if (!ok) {
                // A single-call batch bubbles the raw revert (like execute); a multi-call batch wraps
                // it with the failing index
                if (callsLength == 1) Exec.revertWithReturnData();

                revert ExecuteError(i, Exec.getReturnData(0));
            }
        }
    }

    /**
     * @dev Guards execute() and executeBatch(). Permits the spending key only.
     *      Via EntryPoint: always allowed; _validateSignature already enforced the spending-key selector.
     *      Direct call: msg.sender must be spendingSigner.
     */
    function _requireForExecute() internal view override {
        if (msg.sender == address(entryPoint())) return;

        if (msg.sender == _getMozaikAccountStorage().spendingSigner) return;

        revert UnauthorizedCaller(msg.sender);
    }

    /**
     * @dev Guards rotateSpendingSigner, rotateRecoverySigner, and _authorizeUpgrade.
     *      Permits the recovery key only.
     *      Via EntryPoint: always allowed; _validateSignature already enforced the recovery-key selector.
     *      Direct call: msg.sender must be recoverySigner.
     */
    function _requireRecovery() internal view {
        if (msg.sender == address(entryPoint())) return;

        if (msg.sender == _getMozaikAccountStorage().recoverySigner) return;

        revert UnauthorizedCaller(msg.sender);
    }

    /**
     * @dev Restricts UUPS upgrades to the recovery key.
     */
    function _authorizeUpgrade(address) internal view override {
        _requireRecovery();
    }
}
