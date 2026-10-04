// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ITokenMinterV2
 * @notice The subset of Circle's CCTP V2 TokenMinterV2 that MozaikCCTPForwarder uses.
 */
interface ITokenMinterV2 {
    /**
     * @notice The local token linked to `remoteToken` on `remoteDomain`, or the zero address when none is linked.
     * @param remoteDomain CCTP domain of the remote chain.
     * @param remoteToken  Token address on the remote chain, left-padded to 32 bytes.
     */
    function getLocalToken(uint32 remoteDomain, bytes32 remoteToken) external view returns (address);
}
