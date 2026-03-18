// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {SIG_VALIDATION_FAILED, SIG_VALIDATION_SUCCESS} from "account-abstraction/core/Helpers.sol";

/**
 * @title MozaikAccount
 * @notice ERC-4337 smart account used by Mozaik Pay. Deployed as a UUPS proxy via MozaikAccountFactory.
 * @dev Two keys govern the account with strictly separated powers:
 *
 *      - spendingSigner  (secp256k1, lives on the user's device)
 *        Can execute arbitrary calls (execute / executeBatch). Rotated only by the recovery key.
 *
 *      - recoverySigner  (secp256k1, stored in a secure backup)
 *        Can rotate either signer and authorize contract upgrades.
 *        Cannot execute arbitrary calls.
 *
 *      Key separation is enforced in _validateSignature by inspecting the first 4 bytes of
 *      userOp.callData before ECDSA recovery. A spending-key UserOp whose callData does not
 *      target execute/executeBatch is rejected; a recovery-key UserOp whose callData does not
 *      target a rotation/upgrade function is rejected.
 */
contract MozaikAccount is BaseAccount, UUPSUpgradeable, Initializable {
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
        if (newSpendingSigner == address(0)) revert ZeroAddress();

        MozaikAccountStorage storage $ = _getMozaikAccountStorage();
        address previousSigner = $.spendingSigner;
        $.spendingSigner = newSpendingSigner;

        emit SpendingSignerRotated(previousSigner, newSpendingSigner);
    }

    /**
     * @notice Replaces the recovery signer. Callable only via a recovery-key UserOp or
     *         directly by the current recoverySigner.
     * @param newRecoverySigner The address to install as the new recovery signer.
     */
    function rotateRecoverySigner(address newRecoverySigner) external {
        _requireRecovery();
        if (newRecoverySigner == address(0)) revert ZeroAddress();

        MozaikAccountStorage storage $ = _getMozaikAccountStorage();
        address previousSigner = $.recoverySigner;
        $.recoverySigner = newRecoverySigner;

        emit RecoverySignerRotated(previousSigner, newRecoverySigner);
    }

    /**
     * @dev Validates the UserOp signature. Called by the EntryPoint before execution.
     *
     *      userOp.signature layout: sigType(1) || ecdsaSig(65)
     *        - 0x00 (SIG_SPENDING): callData must target execute or executeBatch; ECDSA must recover spendingSigner.
     *        - 0x01 (SIG_RECOVERY): callData must target rotateSpendingSigner, rotateRecoverySigner, or
     *          upgradeToAndCall; ECDSA must recover recoverySigner.
     *
     *      Key separation is enforced here by checking the callData selector before ECDSA recovery.
     *      The execution guards trust the EntryPoint to only call execution after successful validation.
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

        if (userOp.callData.length < 4) return SIG_VALIDATION_FAILED;

        bytes4 selector = bytes4(userOp.callData[:4]);

        MozaikAccountStorage storage $ = _getMozaikAccountStorage();

        if (sigType == SIG_SPENDING) {
            if (selector != this.execute.selector && selector != this.executeBatch.selector) {
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
            selector != this.rotateSpendingSigner.selector && selector != this.rotateRecoverySigner.selector
                && selector != this.upgradeToAndCall.selector
        ) {
            return SIG_VALIDATION_FAILED;
        }

        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(userOpHash, ecdsaSig);

        if (err != ECDSA.RecoverError.NoError || recovered != $.recoverySigner) return SIG_VALIDATION_FAILED;

        return SIG_VALIDATION_SUCCESS;
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
