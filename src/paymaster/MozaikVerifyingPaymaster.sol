// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {BasePaymaster} from "account-abstraction/core/BasePaymaster.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";
import {_packValidationData} from "account-abstraction/core/Helpers.sol";

/**
 * @notice Mozaik Pay verifying paymaster: sponsors gas for users based on an off-chain backend signature.
 *
 * In ERC-4337, a paymaster is a contract that pays for a UserOp's gas instead of the account itself.
 * This is the "verifying" variant: before approving sponsorship the paymaster verifies an ECDSA
 * signature from a trusted backend key (verifyingSigner). The backend enforces Mozaik Pay's own policy
 * (rate limits, etc.) off-chain and issues a short-lived, per-operation approval.
 *
 * Flow:
 *   1. User builds a UserOp and sends it to the Mozaik Pay backend.
 *   2. Backend validates eligibility, signs a SponsoredOp struct covering sender + nonce + time window.
 *   3. Backend appends the signature to paymasterAndData and returns the complete UserOp.
 *   4. Bundler submits the UserOp to the EntryPoint.
 *   5. EntryPoint calls validatePaymasterUserOp (via BasePaymaster) which verifies the backend signature.
 *   6. On success, EntryPoint deducts the gas cost from this contract's ETH deposit.
 *
 * Inheritance:
 *   - BasePaymaster (ERC-4337) Provides the public validatePaymasterUserOp / postOp entry points
 *                              (EntryPoint-only gated), plus deposit / withdrawTo / getDeposit helpers
 *                              and Ownable2Step for ownership management.
 *   - EIP712        (OZ)       Provides _hashTypedDataV4 for typed-data signing. Domain name is
 *                              "MozaikPaymaster" so backend signatures cannot be replayed against
 *                              the account's isValidSignature (different domain separator).
 */
contract MozaikVerifyingPaymaster is BasePaymaster, EIP712 {
    using UserOperationLib for PackedUserOperation;
    using UserOperationLib for bytes;

    /**
     * @notice The hot-wallet address whose ECDSA signature approves gas sponsorship.
     * @dev    Rotatable by the owner via setVerifyingSigner. Should be a dedicated key.
     */
    address public verifyingSigner;

    /**
     * @notice Layout of the paymaster-specific section of paymasterAndData (after the 52-byte header).
     * @dev    The ERC-4337 paymasterAndData field is structured as:
     *           [0  : 20] paymaster address           (static, set by bundler/SDK)
     *           [20 : 36] paymasterValidationGasLimit (16 bytes)
     *           [36 : 52] paymasterPostOpGasLimit     (16 bytes)
     *           -- PAYMASTER_DATA_OFFSET = 52 --
     *           [52 : 58] validUntil                  (uint48, 6 bytes) <- our data starts here
     *           [58 : 64] validAfter                  (uint48, 6 bytes)
     *           [64 : end] ECDSA signature            (magic-suffixed, see UserOperationLib)
     *
     *         The paymaster signature is appended at the end with a magic sentinel so the EntryPoint
     *         can distinguish what the user signed (the full UserOp hash) from what the paymaster
     *         added (the approval signature). The user's signature covers paymasterAndData up to but
     *         not including the paymaster signature.
     */

    /**
     * @notice EIP-712 struct type hash for the approval the backend signs.
     * @dev    SponsoredOp binds the approval to:
     *           - sender:     the specific account being sponsored (not transferable to other users)
     *           - nonce:      the EntryPoint's per-sender nonce; prevents replaying an approval at a
     *                         different operation index
     *           - validUntil: expiry timestamp (0 = no expiry)
     *           - validAfter: not-before timestamp (0 = no constraint); for scheduled operations
     */
    bytes32 private constant SPONSORED_OP_TYPEHASH =
    keccak256("SponsoredOp(address sender,uint256 nonce,uint48 validUntil,uint48 validAfter)");

    /**
     * @notice Emitted when the verifying signer is rotated.
     * @param oldSigner The previous signer address.
     * @param newSigner The new signer address.
     */
    event VerifyingSignerUpdated(address indexed oldSigner, address indexed newSigner);

    /**
     * @notice Thrown when address(0) is passed as the verifying signer.
     */
    error InvalidSignerAddress();

    /**
     * @notice Deploys the paymaster, registering it with the EntryPoint and setting initial state.
     * @dev    BasePaymaster validates that _entryPoint implements the correct IEntryPoint interface
     *         (ERC-165 check) and stores it as an immutable. EIP712 seeds the domain separator
     *         immutables for "MozaikPaymaster" v1.
     * @param _entryPoint      The canonical ERC-4337 EntryPoint for this chain.
     * @param _verifyingSigner The backend hot-wallet address that signs SponsoredOp approvals.
     * @param _owner           The address that will own this contract (can rotate signer, withdraw).
     */
    constructor(IEntryPoint _entryPoint, address _verifyingSigner, address _owner)
    BasePaymaster(_entryPoint, _owner)
    EIP712("MozaikPaymaster", "1")
    {
        if (_verifyingSigner == address(0)) revert InvalidSignerAddress();

        verifyingSigner = _verifyingSigner;
    }

    /**
     * @notice Rotate the backend signing key.
     * @dev    Only callable by the owner.
     * @param newSigner The replacement signer address.
     */
    function setVerifyingSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert InvalidSignerAddress();

        emit VerifyingSignerUpdated(verifyingSigner, newSigner);

        verifyingSigner = newSigner;
    }

    /**
     * @notice Core paymaster logic: verify the approval signature and return the validity window.
     * @dev    Called by BasePaymaster.validatePaymasterUserOp after confirming the caller is the
     *         EntryPoint. Must not revert, as the EntryPoint expects a return value even on failure.
     *
     *         Steps:
     *           1. Slice validUntil and validAfter from paymasterAndData[52:64].
     *           2. Extract the ECDSA signature from the magic-suffixed end of paymasterAndData.
     *           3. Build the EIP-712 digest over SponsoredOp(sender, nonce, validUntil, validAfter).
     *           4. Recover the signer; set sigFailed = true if recovery fails or signer doesn't match.
     *           5. Pack and return (empty context, validationData) where validationData encodes
     *              the sig result and the validity timestamps for the EntryPoint to enforce.
     *
     *         Empty context means _postOp will not be invoked with meaningful data; no cleanup needed.
     *
     * @param userOp  The packed UserOperation. Only sender and nonce are read from it.
     * @return context        Empty bytes. No post-operation work needed.
     * @return validationData Packed uint256: sig-failed flag (bit 0), validUntil (bits 160-207),
     *                        validAfter (bits 208-255). Format defined by ERC-4337.
     */
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32, // userOpHash
        uint256 // maxCost
    )
    internal
    view
    override
    returns (bytes memory context, uint256 validationData)
    {
        bytes calldata paymasterAndData = userOp.paymasterAndData;
        uint256 offset = UserOperationLib.PAYMASTER_DATA_OFFSET;

        uint48 validUntil = uint48(bytes6(paymasterAndData[offset : offset + 6]));
        uint48 validAfter = uint48(bytes6(paymasterAndData[offset + 6 : offset + 12]));

        bytes calldata pmSig = UserOperationLib.getPaymasterSignature(paymasterAndData);

        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(SPONSORED_OP_TYPEHASH, userOp.sender, userOp.nonce, validUntil, validAfter))
        );

        (address recovered, ECDSA.RecoverError err, bytes32 errArg) = ECDSA.tryRecover(digest, pmSig);

        bool sigFailed = err != ECDSA.RecoverError.NoError || errArg != bytes32(0) || recovered != verifyingSigner;

        return ("", _packValidationData(sigFailed, validUntil, validAfter));
    }

    /**
     * @notice Post-operation hook, left intentionally empty.
     * @dev    Required override because BasePaymaster._postOp reverts with MustOverride() by default,
     *         assuming any non-empty context needs cleanup. We return empty context from
     *         _validatePaymasterUserOp so this is never called with meaningful data.
     */
    function _postOp(PostOpMode, bytes calldata, uint256, uint256) internal pure override {}
}
