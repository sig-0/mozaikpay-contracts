// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ITokenMessengerV2} from "./ITokenMessengerV2.sol";
import {MozaikCCTPForwarder} from "./MozaikCCTPForwarder.sol";

/**
 * @title MozaikCCTPArcForwarder
 * @notice MozaikCCTPForwarder that also accepts the native coin, for Arc, whose native coin is USDC.
 * @dev On Arc, the native balance and the USDC ERC-20 balance are the same funds, in 18 and 6 decimals. forward()
 *      burns them through the ERC-20 interface, so it also moves native deposits. A native remainder below 1e12,
 *      which the 6-decimal balance does not show, stays in the forwarder until the account authorizes a rescue.
 */
contract MozaikCCTPArcForwarder is MozaikCCTPForwarder {
    constructor(ITokenMessengerV2 tokenMessenger, address baseUsdc, uint256 baseChainId)
        MozaikCCTPForwarder(tokenMessenger, baseUsdc, baseChainId)
    {}

    /**
     * @notice Accepts the native coin.
     */
    receive() external payable {}
}
