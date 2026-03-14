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

    function test_CreateAccount_ValidProxy() public {
        address expected = factory.computeAddress(spendingSigner, recoverySigner);

        vm.prank(senderCreator);
        MozaikAccount account = factory.createAccount(spendingSigner, recoverySigner);

        assertEq(address(account), expected);
        assertTrue(address(account).code.length > 0);
    }

    function test_CreateAccount_Idempotency() public {
        vm.prank(senderCreator);
        MozaikAccount first = factory.createAccount(spendingSigner, recoverySigner);

        vm.prank(senderCreator);
        MozaikAccount second = factory.createAccount(spendingSigner, recoverySigner);

        assertEq(address(first), address(second));
    }

    function test_CreateAccount_ValidCreate() public {
        vm.prank(senderCreator);
        MozaikAccount account = factory.createAccount(spendingSigner, recoverySigner);

        assertEq(account.spendingSigner(), spendingSigner);
        assertEq(account.recoverySigner(), recoverySigner);
    }

    function test_ComputeAddress_StableCompute() public view {
        assertEq(
            factory.computeAddress(spendingSigner, recoverySigner),
            factory.computeAddress(spendingSigner, recoverySigner)
        );
    }

    function testFuzz_ComputeAddress_DifferentSource(address a, address b) public view {
        vm.assume(a != address(0));
        vm.assume(b != address(0));
        vm.assume(a != b);

        assertNotEq(factory.computeAddress(a, recoverySigner), factory.computeAddress(b, recoverySigner));
    }

    function testFuzz_ComputeAddress_DifferentRecovery(address a, address b) public view {
        vm.assume(a != address(0));
        vm.assume(b != address(0));
        vm.assume(a != b);

        assertNotEq(factory.computeAddress(spendingSigner, a), factory.computeAddress(spendingSigner, b));
    }

    function test_CreateAccount_InvalidCall() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(MozaikAccountFactory.NotSenderCreator.selector, attacker));
        factory.createAccount(spendingSigner, recoverySigner);
    }

    function test_CreateAccount_InvalidSpendingAddr() public {
        vm.prank(senderCreator);
        vm.expectRevert(MozaikAccountFactory.ZeroAddress.selector);
        factory.createAccount(address(0), recoverySigner);
    }

    function test_CreateAccount_InvalidRecoveryAddr() public {
        vm.prank(senderCreator);
        vm.expectRevert(MozaikAccountFactory.ZeroAddress.selector);
        factory.createAccount(spendingSigner, address(0));
    }

    function test_CreateAccount_EmitsEvent() public {
        address expected = factory.computeAddress(spendingSigner, recoverySigner);

        vm.expectEmit(true, true, false, false);
        emit MozaikAccountFactory.AccountCreated(expected, spendingSigner);

        vm.prank(senderCreator);
        factory.createAccount(spendingSigner, recoverySigner);
    }

    function test_CreateAccount_IdempotencyNoEvent() public {
        address expected = factory.computeAddress(spendingSigner, recoverySigner);

        vm.expectEmit(true, true, false, false);
        emit MozaikAccountFactory.AccountCreated(expected, spendingSigner);

        vm.prank(senderCreator);
        factory.createAccount(spendingSigner, recoverySigner);

        vm.recordLogs();

        vm.prank(senderCreator);
        factory.createAccount(spendingSigner, recoverySigner);

        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_CreateAccount_ImplementationSlot() public {
        vm.prank(senderCreator);
        MozaikAccount account = factory.createAccount(spendingSigner, recoverySigner);

        // ERC1967 implementation slot: keccak256("eip1967.proxy.implementation") - 1
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        address impl = address(uint160(uint256(vm.load(address(account), slot))));

        assertEq(impl, address(factory.ACCOUNT_IMPLEMENTATION()));
    }

    function test_AccountImplementation_CannotBeInitialized() public {
        MozaikAccount impl = factory.ACCOUNT_IMPLEMENTATION();

        vm.expectRevert();
        impl.initialize(spendingSigner, recoverySigner);
    }

    function test_Factory_SenderCreatorSet() public view {
        assertEq(address(factory.SENDER_CREATOR()), address(localEntryPoint.senderCreator()));
    }

    function test_Factory_ImplementationHasCode() public view {
        assertTrue(address(factory.ACCOUNT_IMPLEMENTATION()).code.length > 0);
    }

    function test_ComputeAddress_OrderMatters() public view {
        assertNotEq(
            factory.computeAddress(spendingSigner, recoverySigner),
            factory.computeAddress(recoverySigner, spendingSigner)
        );
    }
}
