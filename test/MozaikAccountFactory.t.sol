// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./BaseTest.t.sol";
import {MozaikAccount} from "../src/account/MozaikAccount.sol";
import {MozaikAccountFactory} from "../src/account/MozaikAccountFactory.sol";

contract MozaikAccountFactoryTest is BaseTest {
    address internal senderCreator;

    function setUp() public override {
        super.setUp();

        senderCreator = address(localEntryPoint.senderCreator());
    }

    function test_CreateAccount_DeploysProxyAtExpectedAddress() public {
        address expected = factory.computeAddress(spendingSigner, recoverySigner);

        vm.prank(senderCreator);
        MozaikAccount account = factory.createAccount(spendingSigner, recoverySigner);

        assertEq(address(account), expected);
        assertTrue(address(account).code.length > 0);
    }

    function test_CreateAccount_IsIdempotent() public {
        vm.prank(senderCreator);
        MozaikAccount first = factory.createAccount(spendingSigner, recoverySigner);

        vm.prank(senderCreator);
        MozaikAccount second = factory.createAccount(spendingSigner, recoverySigner);

        assertEq(address(first), address(second));
    }

    function test_CreateAccount_SetsSpendingAndRecoverySigner() public {
        vm.prank(senderCreator);
        MozaikAccount account = factory.createAccount(spendingSigner, recoverySigner);

        assertEq(account.spendingSigner(), spendingSigner);
        assertEq(account.recoverySigner(), recoverySigner);
    }

    function test_GetAddress_IsStableAcrossMultipleCalls() public view {
        assertEq(
            factory.computeAddress(spendingSigner, recoverySigner),
            factory.computeAddress(spendingSigner, recoverySigner)
        );
    }

    function testFuzz_GetAddress_DifferentSpendingKeysYieldDifferentAddresses(address a, address b) public view {
        vm.assume(a != address(0));
        vm.assume(b != address(0));
        vm.assume(a != b);

        assertNotEq(factory.computeAddress(a, recoverySigner), factory.computeAddress(b, recoverySigner));
    }

    function test_RevertWhen_CreateAccountCalledByNonSenderCreator() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(MozaikAccountFactory.NotSenderCreator.selector, attacker));
        factory.createAccount(spendingSigner, recoverySigner);
    }

    function test_RevertWhen_CreateAccountCalledWithZeroSpendingSigner() public {
        vm.prank(senderCreator);
        vm.expectRevert(MozaikAccountFactory.ZeroAddress.selector);
        factory.createAccount(address(0), recoverySigner);
    }

    function test_RevertWhen_CreateAccountCalledWithZeroRecoverySigner() public {
        vm.prank(senderCreator);
        vm.expectRevert(MozaikAccountFactory.ZeroAddress.selector);
        factory.createAccount(spendingSigner, address(0));
    }
}
