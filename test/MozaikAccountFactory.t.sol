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
        address expected = factory.getAddress(owner);

        vm.prank(senderCreator);
        MozaikAccount acct = factory.createAccount(owner);

        assertEq(address(acct), expected);
        assertTrue(address(acct).code.length > 0);
    }

    function test_CreateAccount_IsIdempotent() public {
        vm.prank(senderCreator);
        MozaikAccount first = factory.createAccount(owner);

        vm.prank(senderCreator);
        MozaikAccount second = factory.createAccount(owner);

        assertEq(address(first), address(second));
    }

    function test_GetAddress_MatchesDeployedAddress() public {
        address predicted = factory.getAddress(owner);

        vm.prank(senderCreator);
        MozaikAccount acct = factory.createAccount(owner);

        assertEq(address(acct), predicted);
    }

    function test_GetAddress_IsStableAcrossMultipleCalls() public view {
        address first = factory.getAddress(owner);
        address second = factory.getAddress(owner);

        assertEq(first, second);
    }

    function test_AccountImplementationIsShared() public {
        address other = makeAddr("other");

        vm.prank(senderCreator);
        MozaikAccount acct1 = factory.createAccount(owner);

        vm.prank(senderCreator);
        MozaikAccount acct2 = factory.createAccount(other);

        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address impl1 = address(uint160(uint256(vm.load(address(acct1), slot))));
        address impl2 = address(uint160(uint256(vm.load(address(acct2), slot))));

        assertEq(impl1, impl2);
        assertEq(impl1, address(factory.ACCOUNT_IMPLEMENTATION()));
    }

    function test_DeployedAccountOwnerIsCorrect() public {
        vm.prank(senderCreator);
        MozaikAccount acct = factory.createAccount(owner);

        assertTrue(acct.signers(owner));
    }

    function testFuzz_DifferentOwnersDifferentAddresses(address a, address b) public view {
        vm.assume(a != b);

        assertNotEq(factory.getAddress(a), factory.getAddress(b));
    }

    function test_RevertWhen_CreateAccountCalledByNonSenderCreator() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(MozaikAccountFactory.NotSenderCreator.selector, attacker));

        factory.createAccount(owner);
    }
}
