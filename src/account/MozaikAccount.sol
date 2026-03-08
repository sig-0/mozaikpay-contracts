// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {SIG_VALIDATION_FAILED, SIG_VALIDATION_SUCCESS} from "account-abstraction/core/Helpers.sol";
import {IMozaikAccount} from "../interfaces/IMozaikAccount.sol";

/**
 * @notice Mozaik Pay self-custodial ERC-4337 smart account (proxy implementation).
 *
 * Each user deploys their own ERC1967Proxy that delegates here. This contract is therefore
 * shared across all accounts; it is never used directly. State (signers, ETH balance) lives in
 * the proxy's storage, not here.
 *
 * Inheritance:
 *   - BaseAccount      (ERC-4337) Implements validateUserOp. Requires entryPoint() and
 *                                 _validateSignature() from us.
 *   - IMozaikAccount              Declares execute, executeBatch, initialize (see interface).
 *   - UUPSUpgradeable  (OZ)      Provides upgradeToAndCall. Requires _authorizeUpgrade() from us.
 *   - Initializable    (OZ)      Provides the initializer modifier and _disableInitializers().
 *   - EIP712           (OZ)      Provides _hashTypedDataV4 and eip712Domain() for typed signing.
 *                                Used in isValidSignature to prevent cross-context replay attacks.
 *                                Works with UUPS proxies: the domain separator is always rebuilt
 *                                from bytecode-baked immutables because address(this) is the proxy,
 *                                never the cached implementation address.
 */
contract MozaikAccount is BaseAccount, IMozaikAccount, UUPSUpgradeable, Initializable, EIP712 {
    /**
     * @notice The canonical ERC-4337 v0.9 EntryPoint address on every supported chain.
     * @dev    Stored as an internal constant rather than a storage variable to avoid the ~2100 gas
     *         cold SLOAD on every validateUserOp call. The tradeoff is that upgrading to a new
     *         EntryPoint version requires a contract upgrade (via _authorizeUpgrade).
     */
    address internal constant ENTRY_POINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;

    /**
     * @notice EIP-712 struct type hash for the message envelope used in isValidSignature.
     * @dev    Callers must sign using eth_signTypedData_v4 with:
     *           domain  = { name: "MozaikAccount", version: "1",
     *                       chainId: <id>, verifyingContract: <this account> }
     *           types   = { MozaikMessage: [{ name: "hash", type: "bytes32" }] }
     *           message = { hash: <the digest being approved> }
     */
    bytes32 private constant _MSG_TYPEHASH = keccak256("MozaikMessage(bytes32 hash)");

    /**
     * @notice The set of addresses authorized to sign UserOps and call execute directly.
     * @dev    Stored as a mapping rather than a single owner address to leave room for a
     *         recovery key or guardian without requiring a storage layout migration.
     */
    mapping(address => bool) public signers;

    /**
     * @notice Thrown when execute or executeBatch is called by an address that is neither the
     *         EntryPoint nor a registered signer. Includes the caller for debugging.
     */
    error NotOwnerOrEntryPoint(address caller);

    /**
     * @notice Thrown when executeBatch is called with arrays of different lengths.
     */
    error ArrayLengthMismatch();

    /**
     * @notice Thrown when a call inside execute or executeBatch reverts. Bubbles up the raw
     *         return data from the target so callers can decode the inner revert reason.
     */
    error CallFailed(bytes reason);

    /**
     * @notice Thrown when execute is called with dest == address(0).
     */
    error ZeroDestination();

    /**
     * @notice Allows the account to receive ETH directly (ex. from a refund or plain transfer).
     * @dev    Required because execute forwards ETH and the account must be able to hold a balance.
     */
    receive() external payable {}

    /**
     * @notice Locks the bare implementation so it can never be initialized directly.
     * @dev    Without this, anyone could call initialize on the implementation contract itself,
     *         set themselves as a signer, and potentially interfere with future upgrade flows.
     *         _disableInitializers() permanently increments the initializer counter so the
     *         initializer modifier will always revert on the implementation. Proxies are
     *         unaffected because each proxy has its own independent storage.
     *
     *         The EIP712 constructor arguments seed the immutable name and version hashes that
     *         are baked into the bytecode and used to compute the domain separator at runtime.
     */
    constructor() EIP712("MozaikAccount", "1") {
        _disableInitializers();
    }

    /**
     * @notice One-time setup called by the factory immediately after proxy deployment.
     * @dev    Replaces a constructor for the proxy instance. The initializer modifier ensures
     *         this can only ever run once per proxy. After it runs, the proxy's signer set
     *         is permanently seeded and the function is locked.
     * @param owner The address that will control this account.
     */
    function initialize(address owner) external initializer {
        signers[owner] = true;
    }

    /**
     * @notice Returns the EntryPoint this account is bound to.
     * @dev    Called by BaseAccount.validateUserOp to confirm the caller is the EntryPoint before
     *         proceeding with signature validation. Hardcoded to ENTRY_POINT_V09 to avoid a
     *         storage read on every UserOp.
     */
    function entryPoint() public view virtual override returns (IEntryPoint) {
        return IEntryPoint(ENTRY_POINT_V09);
    }

    /**
     * @notice Validates a UserOp's ECDSA signature against the registered signer set.
     * @dev    Called internally by BaseAccount.validateUserOp after nonce verification. The hash
     *         passed in is the EIP-712 UserOp hash produced by the EntryPoint. Signing this hash
     *         proves the signer authorized this specific operation with these exact parameters.
     *
     *         ECDSA.tryRecover returns three values: the recovered address, an error code, and an
     *         error argument. All three are checked: the error code must be NoError, the error
     *         argument must be zero (no partial failure), and the recovered address must be a
     *         registered signer.
     *
     * @param userOp     The packed UserOperation submitted by the bundler.
     * @param userOpHash The EntryPoint-computed EIP-712 hash of the UserOp.
     * @return           SIG_VALIDATION_SUCCESS (0) if valid, SIG_VALIDATION_FAILED (1) if not.
     */
    function _validateSignature(PackedUserOperation calldata userOp, bytes32 userOpHash)
        internal
        virtual
        override
        returns (uint256)
    {
        (address recovered, ECDSA.RecoverError err, bytes32 errArg) = ECDSA.tryRecover(userOpHash, userOp.signature);

        if (err != ECDSA.RecoverError.NoError || errArg != bytes32(0) || !signers[recovered]) {
            return SIG_VALIDATION_FAILED;
        }

        return SIG_VALIDATION_SUCCESS;
    }

    /**
     * @notice Access control gate for execute and executeBatch.
     * @dev    Overrides the BaseAccount hook that is called at the start of both execute functions.
     *         Two callers are permitted:
     *           1. The EntryPoint - normal UserOp execution path (bundler submitted the op).
     *           2. A registered signer - direct EOA call, bypassing the bundler entirely.
     *         Any other caller reverts with NotOwnerOrEntryPoint.
     */
    function _requireForExecute() internal view override {
        if (msg.sender != address(entryPoint()) && !signers[msg.sender]) {
            revert NotOwnerOrEntryPoint(msg.sender);
        }
    }

    /**
     * @notice Execute a single arbitrary call on behalf of the account.
     * @dev    Callable by the EntryPoint (via a validated UserOp) or by a registered signer
     *         directly. Forwards the full remaining gas to the target. If the target reverts the
     *         raw return data is bubbled up inside CallFailed so callers can decode the inner
     *         revert reason.
     * @param dest   Target contract or EOA. Must not be address(0).
     * @param value  ETH to forward with the call, in wei.
     * @param data   ABI-encoded calldata (empty bytes for a plain ETH transfer).
     */
    function execute(address dest, uint256 value, bytes calldata data) external override(BaseAccount, IMozaikAccount) {
        _requireForExecute();

        if (dest == address(0)) revert ZeroDestination();

        (bool ok, bytes memory result) = dest.call{value: value}(data);

        if (!ok) revert CallFailed(result);
    }

    /**
     * @notice Execute multiple calls atomically in a single UserOp.
     * @dev    All three arrays must be the same length; reverts with ArrayLengthMismatch otherwise.
     *         If any individual call reverts the entire batch reverts; there is no partial success.
     *         This is intentional: callers should not batch operations with independent failure
     *         domains. Use separate UserOps for operations that should succeed independently.
     * @param dest   Ordered list of target addresses.
     * @param value  ETH to forward with each call, in wei (use 0 for non-payable targets).
     * @param data   ABI-encoded calldata for each call.
     */
    function executeBatch(address[] calldata dest, uint256[] calldata value, bytes[] calldata data) external {
        _requireForExecute();

        if (dest.length != value.length || dest.length != data.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < dest.length; i++) {
            (bool ok, bytes memory result) = dest[i].call{value: value[i]}(data[i]);

            if (!ok) revert CallFailed(result);
        }
    }

    /**
     * @notice Verify an off-chain signature on behalf of this smart account (ERC-1271).
     * @dev    Called by external contracts (ex. Permit2, Seaport, login flows) that need to
     *         confirm a smart account approved a particular hash. Unlike EOA signatures which are
     *         verified by ecrecover alone, smart accounts need this on-chain method because their
     *         "key" is a contract, not a private key.
     *
     *         The raw hash is NOT signed directly. Instead it is wrapped in a typed EIP-712
     *         envelope via OZ's _hashTypedDataV4:
     *
     *           digest = \x19\x01 || domainSeparator || keccak256(abi.encode(MSG_TYPEHASH, hash))
     *
     *         where domainSeparator binds the digest to this specific account address and chain.
     *         This prevents a signature made for a UserOp or any other context from being replayed
     *         here, and prevents cross-chain replay.
     *
     *         Clients must sign using eth_signTypedData_v4 with:
     *           domain  = { name: "MozaikAccount", version: "1",
     *                       chainId: <id>, verifyingContract: <this account> }
     *           types   = { MozaikMessage: [{ name: "hash", type: "bytes32" }] }
     *           message = { hash: <the digest being approved> }
     *
     * @param hash The 32-byte digest that was signed.
     * @param sig  The ECDSA signature bytes.
     * @return     0x1626ba7e (ERC-1271 magic value) on success, 0xffffffff on failure.
     */
    function isValidSignature(bytes32 hash, bytes memory sig) external view override returns (bytes4) {
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(_MSG_TYPEHASH, hash)));

        (address recovered, ECDSA.RecoverError err, bytes32 errArg) = ECDSA.tryRecover(digest, sig);

        if (err == ECDSA.RecoverError.NoError && errArg == bytes32(0) && signers[recovered]) {
            return IERC1271.isValidSignature.selector;
        }

        return bytes4(0xffffffff);
    }

    /**
     * @notice UUPS upgrade authorization gate.
     * @dev    Called by UUPSUpgradeable.upgradeToAndCall before replacing the implementation.
     *         Only a registered signer may authorize an upgrade. The EntryPoint path is
     *         intentionally excluded here. Upgrades are a high-privilege, irreversible action
     *         and must be performed directly by the account owner, not routed through a bundler.
     * TODO check what this means for account upgrades, and how the user flow would work
     */
    function _authorizeUpgrade(address) internal view override {
        if (!signers[msg.sender]) revert NotOwnerOrEntryPoint(msg.sender);
    }
}
