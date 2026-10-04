// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {MozaikCCTPForwarder} from "./MozaikCCTPForwarder.sol";

/**
 * @title MozaikCCTPForwarderFactory
 * @notice Deploys MozaikCCTPForwarder clones at deterministic addresses.
 * @dev A forwarder's address depends only on this factory, the implementation and the account, so it is the
 *      same on every chain where the factory has the same address. Anyone can deploy any account's forwarder.
 */
contract MozaikCCTPForwarderFactory {
    /**
     * @notice The MozaikCCTPForwarder logic contract that every clone delegates to.
     */
    MozaikCCTPForwarder public immutable FORWARDER_IMPLEMENTATION;

    /**
     * @notice Emitted when a forwarder is deployed.
     * @param account   The account the forwarder serves.
     * @param forwarder The address of the new forwarder.
     */
    event ForwarderDeployed(address indexed account, address indexed forwarder);

    /**
     * @notice Thrown when the account is the zero address.
     */
    error ZeroAddress();

    /**
     * @notice Thrown when the implementation has no code.
     */
    error InvalidImplementation();

    /**
     * @param implementation The MozaikCCTPForwarder logic contract.
     */
    constructor(MozaikCCTPForwarder implementation) {
        if (address(implementation).code.length == 0) revert InvalidImplementation();

        FORWARDER_IMPLEMENTATION = implementation;
    }

    /**
     * @notice Computes the address of the account's forwarder, deployed or not.
     * @dev Reverts for the zero account, whose forwarder can never be deployed.
     * @param account The account the forwarder serves.
     * @return The address where the forwarder is (or will be) deployed.
     */
    function predict(address account) public view returns (address) {
        if (account == address(0)) revert ZeroAddress();

        return Clones.predictDeterministicAddressWithImmutableArgs(
            address(FORWARDER_IMPLEMENTATION), abi.encodePacked(account), bytes32(0)
        );
    }

    /**
     * @notice Deploys the account's forwarder, or returns the existing one if it is already deployed.
     * @param account The account the forwarder serves.
     * @return forwarder The deployed (or pre-existing) forwarder.
     */
    function deploy(address account) public returns (address forwarder) {
        forwarder = predict(account);
        if (forwarder.code.length > 0) return forwarder;

        forwarder = Clones.cloneDeterministicWithImmutableArgs(
            address(FORWARDER_IMPLEMENTATION), abi.encodePacked(account), bytes32(0)
        );

        emit ForwarderDeployed(account, forwarder);
    }

    /**
     * @notice Deploys the account's forwarder if needed, then calls its forward().
     * @param account              The account the forwarder serves.
     * @param amount               Most USDC to move, in token-minor units. See MozaikCCTPForwarder.forward.
     * @param maxFee               Maximum CCTP fee. See MozaikCCTPForwarder.forward.
     * @param minFinalityThreshold CCTP finality threshold. See MozaikCCTPForwarder.forward.
     * @return forwarder The forwarder.
     */
    function deployAndForward(address account, uint256 amount, uint256 maxFee, uint32 minFinalityThreshold)
        external
        returns (address forwarder)
    {
        forwarder = deploy(account);

        MozaikCCTPForwarder(forwarder).forward(amount, maxFee, minFinalityThreshold);
    }
}
