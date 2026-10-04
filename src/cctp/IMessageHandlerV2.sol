// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IMessageHandlerV2
 * @notice Circle's CCTP V2 interface for a recipient of messages from MessageTransmitterV2.
 * @dev The transmitter calls the finalized handler for messages attested at a finality threshold of 2000 or
 *      more, and the unfinalized handler otherwise. A handler must return true for the message to be received.
 */
interface IMessageHandlerV2 {
    /**
     * @notice Handles a message attested at a finality threshold of 2000 or more.
     * @param sourceDomain              CCTP domain of the chain that sent the message.
     * @param sender                    Sender of the message on the source chain, left-padded to 32 bytes.
     * @param finalityThresholdExecuted Finality at which the message was attested.
     * @param messageBody               Application payload.
     */
    function handleReceiveFinalizedMessage(
        uint32 sourceDomain,
        bytes32 sender,
        uint32 finalityThresholdExecuted,
        bytes calldata messageBody
    ) external returns (bool);

    /**
     * @notice Handles a message attested at a finality threshold below 2000.
     * @param sourceDomain              CCTP domain of the chain that sent the message.
     * @param sender                    Sender of the message on the source chain, left-padded to 32 bytes.
     * @param finalityThresholdExecuted Finality at which the message was attested.
     * @param messageBody               Application payload.
     */
    function handleReceiveUnfinalizedMessage(
        uint32 sourceDomain,
        bytes32 sender,
        uint32 finalityThresholdExecuted,
        bytes calldata messageBody
    ) external returns (bool);
}
