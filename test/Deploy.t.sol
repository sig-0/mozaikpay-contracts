// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./BaseTest.t.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {MozaikAccount} from "../src/account/MozaikAccount.sol";
import {MozaikAccountFactory} from "../src/account/MozaikAccountFactory.sol";
import {MozaikVerifyingPaymaster} from "../src/paymaster/MozaikVerifyingPaymaster.sol";

contract DeployScriptTest is BaseTest {
    MozaikAccountFactory internal deployedFactory;
    MozaikVerifyingPaymaster internal deployedPaymaster;

    function setUp() public override {
        super.setUp();

        deployedFactory = new MozaikAccountFactory();
        deployedPaymaster = new MozaikVerifyingPaymaster(verifyingSignerAddr);
    }

    function test_Deploy_FactoryAddressNonZero() public view {
        assertTrue(address(deployedFactory) != address(0));
    }

    function test_Deploy_PaymasterAddressNonZero() public view {
        assertTrue(address(deployedPaymaster) != address(0));
    }

    function test_Deploy_AccountImplementationNonZero() public view {
        assertTrue(address(deployedFactory.ACCOUNT_IMPLEMENTATION()) != address(0));
    }

    function test_Deploy_ComputeAddressNonZero() public view {
        address counterfactual = deployedFactory.computeAddress(address(1), address(2));

        assertTrue(counterfactual != address(0));
    }

    function test_Deploy_OwnershipIsDeployer() public view {
        assertEq(deployedPaymaster.owner(), address(this));
    }

    function test_Deploy_VerifyingSignerIsCorrect() public view {
        assertEq(deployedPaymaster.sponsor(), verifyingSignerAddr);
    }

    function test_Deploy_EntryPointConsistency() public {
        MozaikAccount acct = _deployAccount();
        address canonicalCreator = address(IEntryPoint(ENTRY_POINT_V09).senderCreator());

        assertEq(address(acct.entryPoint()), ENTRY_POINT_V09);
        assertEq(address(deployedFactory.ACCOUNT_IMPLEMENTATION().entryPoint()), ENTRY_POINT_V09);
        assertEq(address(deployedFactory.SENDER_CREATOR()), canonicalCreator);
        assertEq(address(deployedPaymaster.entryPoint()), ENTRY_POINT_V09);
    }
}
