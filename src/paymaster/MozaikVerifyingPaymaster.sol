// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {BasePaymaster} from "account-abstraction/core/BasePaymaster.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";
import {_packValidationData} from "account-abstraction/core/Helpers.sol";

/**
 * @title MozaikVerifyingPaymaster
 * @notice ERC-4337 paymaster that sponsors gas for Mozaik Pay users based on a short-lived
 *         off-chain signature from the Mozaik Pay backend.
 * @dev The backend (sponsor key) enforces Mozaik Pay's own sponsorship policy off-chain and
 *      issues a per-operation approval valid for a fixed time window. The paymaster verifies
 *      that approval on-chain before agreeing to pay for gas.
 *
 *      The approval digest binds to: this contract's address, chainId, the sender account,
 *      the account nonce, the exact callData, the gas limits, and the time window. This
 *      prevents replay, cross-chain reuse, gas inflation by a bundler, and sponsorship of
 *      operations the backend did not explicitly approve.
 *
 *      Ownership (for sponsor rotation and ETH withdrawals) is inherited via BasePaymaster.
 */
contract MozaikVerifyingPaymaster is BasePaymaster {
    /**
     * @notice The hot-wallet address whose ECDSA signature authorises gas sponsorship.
     * @dev Rotatable by the owner via setSponsor. The backend signs with the corresponding
     *      private key and embeds the signature in paymasterAndData.
     */
    address public sponsor;

    /**
     * @notice Emitted when the sponsor address is updated.
     * @param oldSponsor The previous sponsor address.
     * @param newSponsor The new sponsor address.
     */
    event SponsorUpdated(address indexed oldSponsor, address indexed newSponsor);

    /**
     * @notice Thrown when a zero address is supplied where one is not permitted.
     */
    error ZeroAddress();

    /**
     * @param _entryPoint The ERC-4337 EntryPoint this paymaster is staked with.
     * @param _sponsor    The initial backend signing address.
     */
    constructor(IEntryPoint _entryPoint, address _sponsor) BasePaymaster(_entryPoint, msg.sender) {
        if (_sponsor == address(0)) revert ZeroAddress();

        sponsor = _sponsor;
    }

    /**
     * @notice Replaces the sponsor address. Used to rotate the backend signing key.
     * @param newSponsor The new sponsor address.
     */
    function setSponsor(address newSponsor) external onlyOwner {
        if (newSponsor == address(0)) revert ZeroAddress();

        emit SponsorUpdated(sponsor, newSponsor);

        sponsor = newSponsor;
    }

    /**
     * @dev Validates the backend's sponsorship approval embedded in paymasterAndData.
     *
     *      paymasterAndData layout (after the standard 52-byte EntryPoint header):
     *        validUntil (6 bytes) || validAfter (6 bytes) || sig (65 bytes) || uint16(65) || MAGIC (8 bytes)
     *
     *      userOpHash and maxCost are intentionally ignored: the digest is constructed
     *      over only the fields the backend commits to (see _paymasterDigest), and
     *      Mozaik Pay sponsors unconditionally with no per-op cost cap.
     *
     *      Never reverts - a bad signature returns sigFailed=true which the EntryPoint
     *      treats as a validation failure without reverting the bundle.
     */
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32, // userOpHash - not used; we build our own digest
        uint256 // maxCost   - not used; Mozaik Pay sponsors unconditionally
    )
        internal
        view
        override
        returns (bytes memory context, uint256 validationData)
    {
        bytes calldata paymasterAndData = userOp.paymasterAndData;
        uint256 offset = UserOperationLib.PAYMASTER_DATA_OFFSET;

        uint48 validUntil = uint48(bytes6(paymasterAndData[offset:offset + 6]));
        uint48 validAfter = uint48(bytes6(paymasterAndData[offset + 6:offset + 12]));

        bytes calldata pmSig = UserOperationLib.getPaymasterSignature(paymasterAndData);

        bytes32 digest = _paymasterDigest(userOp, validUntil, validAfter);

        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, pmSig);
        bool sigFailed = err != ECDSA.RecoverError.NoError || recovered != sponsor;

        return ("", _packValidationData(sigFailed, validUntil, validAfter));
    }

    /**
     * @dev Constructs the digest the backend must sign to approve sponsorship of a UserOp.
     *
     *      Binds to:
     *        - address(this)             -  prevents use on a different paymaster
     *        - block.chainid             -  prevents cross-chain replay
     *        - userOp.sender             -  approves a specific account
     *        - userOp.nonce              -  approves a single operation (EntryPoint enforces uniqueness)
     *        - keccak256(userOp.callData) -  approves a specific operation, not arbitrary calls
     *        - userOp.accountGasLimits   -  prevents a bundler from inflating gas limits
     *        - userOp.preVerificationGas -  included for the same reason
     *        - userOp.gasFees            -  prevents a bundler from inflating the fee cap
     *        - validUntil / validAfter   -  constrains the approval to a time window
     *
     */
    function _paymasterDigest(PackedUserOperation calldata userOp, uint48 validUntil, uint48 validAfter)
        private
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                address(this),
                block.chainid,
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.callData),
                userOp.accountGasLimits,
                userOp.preVerificationGas,
                userOp.gasFees,
                validUntil,
                validAfter
            )
        );
    }
}
