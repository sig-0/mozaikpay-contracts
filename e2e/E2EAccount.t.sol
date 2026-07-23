// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";

import {E2EBase} from "./E2EBase.t.sol";

/// @title E2E: account creation via UserOp and USDC transfers.
contract E2EAccountTest is E2EBase {
    function test_Account_CreatedViaUserOp() public {
        AccountFixture memory a = _createAccount("acct");

        assertTrue(a.addr.code.length > 0, "account not deployed");
        assertEq(a.account.spendingSigner(), a.spendingSigner, "wrong spending signer");
        assertEq(a.account.recoverySigner(), a.recoverySigner, "wrong recovery signer");
    }

    function test_Account_ExecutesUSDCTransfer() public {
        AccountFixture memory a = _createAccount("acct");

        ERC20Mock usdc = new ERC20Mock();
        usdc.mint(a.addr, 1000e6);
        address recipient = makeAddr("recipient");

        _sendSpendingOp(
            a.addr,
            a.spendingKey,
            abi.encodeCall(
                BaseAccount.execute,
                (address(usdc), 0, abi.encodeCall(usdc.transfer, (recipient, 100e6)))
            )
        );

        assertEq(usdc.balanceOf(recipient), 100e6, "recipient didn't receive USDC");
        assertEq(usdc.balanceOf(a.addr), 900e6, "account balance incorrect");
    }
}
