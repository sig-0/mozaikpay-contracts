// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {MozaikCCTPForwarder} from "../../src/cctp/MozaikCCTPForwarder.sol";
import {MozaikCCTPForwarderFactory} from "../../src/cctp/MozaikCCTPForwarderFactory.sol";
import {ITokenMessengerV2} from "../../src/cctp/ITokenMessengerV2.sol";
import {CCTPBaseTest} from "./CCTPBaseTest.t.sol";

contract MozaikCCTPForwarderFactoryTest is CCTPBaseTest {
    function test_Constructor_SetsImplementation() public view {
        assertEq(address(factory.FORWARDER_IMPLEMENTATION()), address(implementation));
    }

    function test_Constructor_InvalidImplementation() public {
        vm.expectRevert(MozaikCCTPForwarderFactory.InvalidImplementation.selector);
        new MozaikCCTPForwarderFactory(MozaikCCTPForwarder(address(0)));

        vm.expectRevert(MozaikCCTPForwarderFactory.InvalidImplementation.selector);
        new MozaikCCTPForwarderFactory(MozaikCCTPForwarder(makeAddr("codeless")));
    }

    function test_Deploy_ValidAtPredictedAddress() public {
        address other = makeAddr("other");
        address predicted = factory.predict(other);
        assertEq(predicted.code.length, 0, "not deployed yet");

        vm.expectEmit(true, true, true, true, address(factory));
        emit MozaikCCTPForwarderFactory.ForwarderDeployed(other, predicted);

        address deployed = factory.deploy(other);

        assertEq(deployed, predicted);
        assertEq(MozaikCCTPForwarder(deployed).account(), other);
    }

    function test_Deploy_CloneLayout() public view {
        bytes memory code = address(forwarder).code;

        assertEq(code.length, 45 + 20, "ERC-1167 runtime plus one address");
        assertEq(Clones.fetchCloneArgs(address(forwarder)), abi.encodePacked(account));
    }

    function test_Deploy_IdempotencyNoEvent() public {
        vm.recordLogs();

        address again = factory.deploy(account);

        assertEq(again, address(forwarder));
        assertEq(vm.getRecordedLogs().length, 0, "no event on repeat deploy");
    }

    function test_Predict_InvalidZeroAccount() public {
        vm.expectRevert(MozaikCCTPForwarderFactory.ZeroAddress.selector);
        factory.predict(address(0));
    }

    function test_Deploy_InvalidZeroAccount() public {
        vm.expectRevert(MozaikCCTPForwarderFactory.ZeroAddress.selector);
        factory.deploy(address(0));
    }

    function test_Deploy_AddressDependsOnFactoryAndImplementation() public {
        MozaikCCTPForwarderFactory otherFactory = new MozaikCCTPForwarderFactory(implementation);
        MozaikCCTPForwarderFactory otherImplementation = new MozaikCCTPForwarderFactory(
            new MozaikCCTPForwarder(ITokenMessengerV2(address(messenger)), address(baseUsdc), 84532)
        );

        assertNotEq(otherFactory.predict(account), address(forwarder));
        assertNotEq(otherImplementation.predict(account), address(forwarder));
    }

    function test_DeployAndForward_DeploysThenForwards() public {
        address other = makeAddr("other");
        address predicted = factory.predict(other);
        usdc.mint(predicted, 1_000_000);

        vm.recordLogs();
        address deployed = factory.deployAndForward(other, 1_000_000, 0, 2000);

        assertEq(deployed, predicted);
        assertEq(messenger.burnCount(), 1);
        assertEq(messenger.burnAt(0).mintRecipient, bytes32(uint256(uint160(other))));
        assertEq(usdc.balanceOf(predicted), 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawDeploy;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(factory)
                    && logs[i].topics[0] == MozaikCCTPForwarderFactory.ForwarderDeployed.selector
            ) {
                sawDeploy = true;
            }
        }
        assertTrue(sawDeploy, "ForwarderDeployed emitted");
    }

    function test_DeployAndForward_ExistingForwarder() public {
        vm.chainId(BASE_CHAIN_ID);
        baseUsdc.mint(address(forwarder), 1_000_000);

        address deployed = factory.deployAndForward(account, 1_000_000, 0, 0);

        assertEq(deployed, address(forwarder));
        assertEq(baseUsdc.balanceOf(account), 1_000_000);
    }

    function test_DeployAndForward_RevertsWithForwardError() public {
        address other = makeAddr("other");

        vm.expectRevert(MozaikCCTPForwarder.InvalidInput.selector);
        factory.deployAndForward(other, 0, 0, 2000);

        assertEq(factory.predict(other).code.length, 0, "deploy rolled back");
    }

    function test_DeployAndForward_InvalidZeroAccount() public {
        vm.expectRevert(MozaikCCTPForwarderFactory.ZeroAddress.selector);
        factory.deployAndForward(address(0), 1, 0, 2000);
    }

    function testFuzz_Predict_MatchesDeploy(address other) public {
        vm.assume(other != address(0));

        address predicted = factory.predict(other);
        address deployed = factory.deploy(other);

        assertEq(deployed, predicted);
        assertEq(MozaikCCTPForwarder(deployed).account(), other);
    }
}
