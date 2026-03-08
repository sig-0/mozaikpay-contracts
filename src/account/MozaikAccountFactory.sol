// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {ISenderCreator} from "account-abstraction/interfaces/ISenderCreator.sol";
import {MozaikAccount} from "./MozaikAccount.sol";

/**
 * @notice Deploys and tracks Mozaik smart accounts.
 *
 * Each user gets their own ERC1967Proxy instance pointing at a single shared MozaikAccount
 * implementation. The factory deploys that implementation once and reuses it for every account,
 * keeping deployment costs low.
 *
 * Accounts are deployed at deterministic addresses via CREATE2, keyed by owner address. This
 * enables counterfactual deployment: the account address is known and usable (ex. to receive
 * funds) before the account contract actually exists on-chain.
 */
contract MozaikAccountFactory {
    /**
     * @notice The single shared MozaikAccount implementation all proxies delegate to.
     * @dev    Deployed once in the constructor. Never changes, as upgrades happen per-proxy,
     *         not here. Kept as an immutable so there is no storage read overhead on every
     *         createAccount call.
     */
    MozaikAccount public immutable ACCOUNT_IMPLEMENTATION;

    /**
     * @notice The EntryPoint's SenderCreator helper contract.
     * @dev    In ERC-4337 v0.9 the EntryPoint no longer calls the factory directly. Instead it
     *         delegates account creation to a dedicated SenderCreator sub-contract. We gate
     *         createAccount on this address so that arbitrary callers cannot deploy accounts
     *         on behalf of users.
     */
    ISenderCreator public immutable SENDER_CREATOR;

    /**
     * @notice Thrown when createAccount is called by anyone other than the EntryPoint's
     *         SenderCreator. Includes the caller address to aid debugging.
     */
    error NotSenderCreator(address caller);

    /**
     * @notice Deploys the shared MozaikAccount implementation and caches the SenderCreator.
     * @dev    The implementation's constructor calls _disableInitializers(), locking it so that
     *         no one can initialize the bare implementation directly (only proxies can be
     *         initialized). See MozaikAccount for details.
     * @param _entryPoint The canonical ERC-4337 EntryPoint for this chain.
     */
    constructor(IEntryPoint _entryPoint) {
        ACCOUNT_IMPLEMENTATION = new MozaikAccount();
        SENDER_CREATOR = _entryPoint.senderCreator();
    }

    /**
     * @notice Deploy a new account for `owner`, or return the existing one if already deployed.
     * @dev    Only callable by the EntryPoint's SenderCreator. This is enforced by ERC-4337 v0.9:
     *         the EntryPoint routes initCode execution through SenderCreator to isolate the
     *         creation call and prevent reentrancy into the EntryPoint itself.
     *
     *         Idempotent by design: if the account already exists at the predicted address the
     *         function returns it without reverting. This lets the EntryPoint safely call the
     *         factory even when replaying or simulating a UserOp.
     *
     * @param owner The address that will control the new account.
     * @return      The deployed (or pre-existing) MozaikAccount proxy.
     */
    function createAccount(address owner) external returns (MozaikAccount) {
        // Sanity check the creator address
        if (msg.sender != address(SENDER_CREATOR)) {
            revert NotSenderCreator(msg.sender);
        }

        // Idempotency (for simulations, etc)
        address addr = getAddress(owner);
        if (addr.code.length > 0) {
            // Account exists (is created), return it
            return MozaikAccount(payable(addr));
        }

        // Compute the salt based on the owner's address
        bytes32 salt;
        assembly ("memory-safe") {
            mstore(0x00, owner)
            salt := keccak256(0x00, 0x20)
        }

        // Compute the init data for the proxy
        bytes memory initData = abi.encodeCall(MozaikAccount.initialize, (owner));

        // Create the proxy
        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(address(ACCOUNT_IMPLEMENTATION), initData);

        return MozaikAccount(payable(address(proxy)));
    }

    /**
     * @notice Compute the counterfactual address of a user's account without deploying it.
     * @dev    The address is derived deterministically from the owner via CREATE2:
     *
     *           address = keccak256(0xff ++ factory ++ salt ++ keccak256(initCode))[12:]
     *
     *         where salt = keccak256(abi.encode(owner)) and initCode is the ERC1967Proxy
     *         creation bytecode with the implementation address and initialize calldata
     *         ABI-encoded as constructor arguments.
     *
     *         Because the address is stable and known ahead of time, users can receive funds
     *         (ETH, tokens) at this address before the account is deployed. The first UserOp
     *         that includes initCode will deploy the account and the pre-existing balance is
     *         preserved.
     *
     * @param owner The prospective account owner.
     * @return      The address the account will be deployed to.
     */
    function getAddress(address owner) public view returns (address) {
        bytes32 salt;
        assembly ("memory-safe") {
            mstore(0x00, owner)
            salt := keccak256(0x00, 0x20)
        }

        return Create2.computeAddress(
            salt,
            keccak256(
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode,
                    abi.encode(address(ACCOUNT_IMPLEMENTATION), abi.encodeCall(MozaikAccount.initialize, (owner)))
                )
            )
        );
    }
}
