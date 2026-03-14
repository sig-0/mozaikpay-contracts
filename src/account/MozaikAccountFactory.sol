// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {ISenderCreator} from "account-abstraction/interfaces/ISenderCreator.sol";
import {MozaikAccount} from "./MozaikAccount.sol";

/**
 * @title MozaikAccountFactory
 * @notice Deploys MozaikAccount proxies at deterministic addresses using Create2.
 * @dev Each account address is derived from (spendingSigner, recoverySigner), so the
 *      counterfactual address can be computed off-chain before the account exists on-chain.
 *      createAccount is restricted to the EntryPoint's SenderCreator, ensuring accounts
 *      are only deployed as part of a validated UserOp flow.
 */
contract MozaikAccountFactory {
    /**
     * @notice The MozaikAccount logic contract that all proxies delegate to.
     */
    MozaikAccount public immutable ACCOUNT_IMPLEMENTATION;

    /**
     * @notice The EntryPoint's SenderCreator, the only address permitted to call createAccount.
     */
    ISenderCreator public immutable SENDER_CREATOR;

    /**
     * @notice Emitted when a new account proxy is deployed.
     * @param account       The address of the newly deployed proxy.
     * @param spendingSigner The spending signer the account was initialized with.
     */
    event AccountCreated(address indexed account, address indexed spendingSigner);

    /**
     * @notice Thrown when createAccount is called by any address other than SenderCreator.
     * @param caller The address that attempted the call.
     */
    error NotSenderCreator(address caller);

    /**
     * @notice Thrown when a zero address is supplied where one is not permitted.
     */
    error ZeroAddress();

    /**
     * @param _entryPoint The ERC-4337 EntryPoint. Used to resolve the SenderCreator address.
     */
    constructor(IEntryPoint _entryPoint) {
        ACCOUNT_IMPLEMENTATION = new MozaikAccount();
        SENDER_CREATOR = _entryPoint.senderCreator();
    }

    /**
     * @notice Deploys a MozaikAccount proxy for the given signer pair, or returns the existing
     *         one if it has already been deployed.
     * @dev Callable only by the EntryPoint's SenderCreator (enforced so accounts can only be
     *      created via a UserOp initCode, not by arbitrary callers).
     *      The proxy address is fully determined by (spendingSigner, recoverySigner) -
     *      calling this function twice with the same arguments is idempotent.
     * @param spendingSigner The secp256k1 address authorized to execute calls.
     * @param recoverySigner The secp256k1 address authorized to rotate signers and upgrade.
     * @return The deployed (or pre-existing) MozaikAccount proxy.
     */
    function createAccount(address spendingSigner, address recoverySigner) external returns (MozaikAccount) {
        if (msg.sender != address(SENDER_CREATOR)) revert NotSenderCreator(msg.sender);

        if (spendingSigner == address(0) || recoverySigner == address(0)) revert ZeroAddress();

        address addr = computeAddress(spendingSigner, recoverySigner);

        if (addr.code.length > 0) return MozaikAccount(payable(addr));

        bytes32 salt = keccak256(abi.encode(spendingSigner, recoverySigner));
        bytes memory initData = abi.encodeCall(MozaikAccount.initialize, (spendingSigner, recoverySigner));

        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(address(ACCOUNT_IMPLEMENTATION), initData);

        emit AccountCreated(address(proxy), spendingSigner);

        return MozaikAccount(payable(address(proxy)));
    }

    /**
     * @notice Computes the counterfactual address of the account for the given signer pair.
     * @dev The address is deterministic and stable - it can be used to pre-fund or pre-approve
     *      the account before it is deployed.
     * @param spendingSigner The spending signer the account would be initialized with.
     * @param recoverySigner The recovery signer the account would be initialized with.
     * @return The CREATE2 address where the proxy would be (or has been) deployed.
     */
    function computeAddress(address spendingSigner, address recoverySigner) public view returns (address) {
        bytes32 salt = keccak256(abi.encode(spendingSigner, recoverySigner));

        return Create2.computeAddress(
            salt,
            keccak256(
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode,
                    abi.encode(
                        address(ACCOUNT_IMPLEMENTATION),
                        abi.encodeCall(MozaikAccount.initialize, (spendingSigner, recoverySigner))
                    )
                )
            )
        );
    }
}
