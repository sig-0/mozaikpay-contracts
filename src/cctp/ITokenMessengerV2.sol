// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ITokenMinterV2} from "./ITokenMinterV2.sol";

/**
 * @title ITokenMessengerV2
 * @notice The subset of Circle's CCTP V2 TokenMessengerV2 that MozaikCCTPForwarder uses.
 */
interface ITokenMessengerV2 {
    /**
     * @notice Burns `amount` of `burnToken` from the caller for a mint to `mintRecipient` on `destinationDomain`.
     * @param amount               Amount to burn, in token-minor units.
     * @param destinationDomain    CCTP domain of the destination chain.
     * @param mintRecipient        Mint recipient on the destination chain, left-padded to 32 bytes.
     * @param burnToken            Local token to burn.
     * @param destinationCaller    Only caller allowed to receive the message; zero allows any caller.
     * @param maxFee               Maximum fee paid on the destination chain, in units of `burnToken`.
     * @param minFinalityThreshold Minimum finality at which the burn is attested.
     */
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;

    /**
     * @notice The MessageTransmitterV2 that sends and delivers messages on this chain.
     */
    function localMessageTransmitter() external view returns (address);

    /**
     * @notice The TokenMinterV2 that holds the token links on this chain.
     */
    function localMinter() external view returns (ITokenMinterV2);
}
