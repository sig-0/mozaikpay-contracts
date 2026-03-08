// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccount} from "account-abstraction/interfaces/IAccount.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/**
 * @notice Interface for the Mozaik self-custodial ERC-4337 smart account.
 *
 * Inherits two standards:
 *   - IAccount  (ERC-4337) - required by the EntryPoint to validate UserOps before execution.
 *   - IERC1271  (ERC-1271) - required by dapps and contracts to verify off-chain signatures
 *                            from a smart account (e.g. login flows, Permit2, order signing).
 *
 * Both are declared here rather than on the implementation so that:
 *   a) External code can type a MozaikAccount as IMozaikAccount without importing the full contract.
 *   b) Solidity's multiple inheritance linearization has a single, explicit resolution point for
 *      interfaces that would otherwise appear via two separate inheritance paths.
 */
interface IMozaikAccount is IAccount, IERC1271 {
    /**
     * @notice One-time initializer called by the factory immediately after proxy deployment.
     * @dev    Replaces a constructor. UUPS proxies do not run the implementation's constructor
     *         for each user account. Protected by OpenZeppelin's `initializer` modifier so it
     *         can only ever be called once per proxy instance.
     * @param owner The address that will control this account.
     */
    function initialize(address owner) external;

    /**
     * @notice Execute a single arbitrary call on behalf of the account.
     * @dev    Callable only by the EntryPoint (via a UserOp) or by a registered signer directly.
     *         Reverts with CallFailed if the target call reverts.
     * @param dest   Target contract or EOA.
     * @param value  ETH to forward with the call, in wei.
     * @param data   ABI-encoded calldata (empty bytes for a plain ETH transfer).
     */
    function execute(address dest, uint256 value, bytes calldata data) external;

    /**
     * @notice Execute multiple calls atomically in a single UserOp.
     * @dev    All three arrays must be the same length; reverts with ArrayLengthMismatch otherwise.
     *         If any individual call reverts, the entire batch reverts - there is no partial success.
     *         This is intentional: callers should not batch ops with independent failure domains.
     * @param dest   Ordered list of target addresses.
     * @param value  ETH to forward with each call, in wei (use 0 for non-payable targets).
     * @param data   ABI-encoded calldata for each call.
     */
    function executeBatch(address[] calldata dest, uint256[] calldata value, bytes[] calldata data) external;
}
