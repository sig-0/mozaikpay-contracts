// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {E2EBase} from "./E2EBase.t.sol";

/// @title E2E: the deployed contract stack is live and configured.
contract E2EDeploymentTest is E2EBase {
    function test_Deployment_StackIsLive() public view {
        assertTrue(address(factory).code.length > 0, "factory not deployed");
        assertTrue(address(paymaster).code.length > 0, "paymaster not deployed");
        assertTrue(address(factory.ACCOUNT_IMPLEMENTATION()).code.length > 0, "account impl not deployed");
        assertTrue(ep.getDepositInfo(address(paymaster)).deposit > 0, "paymaster has no deposit");
        assertEq(paymaster.sponsor(), SPONSOR_ADDR, "wrong sponsor");
    }
}
