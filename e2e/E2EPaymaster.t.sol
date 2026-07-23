// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";

import {E2EBase} from "./E2EBase.t.sol";

/// @title E2E: the paymaster sponsors gas from its own deposit, not the account.
contract E2EPaymasterTest is E2EBase {
    function test_Paymaster_SponsorsGasFromDeposit() public {
        AccountFixture memory a = _createAccount("acct");

        ERC20Mock usdc = new ERC20Mock();
        usdc.mint(a.addr, 1000e6);
        address recipient = makeAddr("recipient");

        uint256 depositBefore = ep.getDepositInfo(address(paymaster)).deposit;

        _sendSpendingOp(
            a.addr,
            a.spendingKey,
            abi.encodeCall(BaseAccount.execute, (address(usdc), 0, abi.encodeCall(usdc.transfer, (recipient, 100e6))))
        );

        assertLt(ep.getDepositInfo(address(paymaster)).deposit, depositBefore, "sponsor deposit not debited");
        assertEq(a.addr.balance, 0, "account paid gas itself");
        assertEq(usdc.balanceOf(recipient), 100e6, "transfer did not land");
    }
}
