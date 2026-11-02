// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MozaikCCTPArcForwarder} from "../../src/cctp/MozaikCCTPArcForwarder.sol";
import {MozaikCCTPForwarder} from "../../src/cctp/MozaikCCTPForwarder.sol";
import {MozaikCCTPForwarderFactory} from "../../src/cctp/MozaikCCTPForwarderFactory.sol";
import {ITokenMessengerV2} from "../../src/cctp/ITokenMessengerV2.sol";
import {CCTPBaseTest} from "./CCTPBaseTest.t.sol";

contract MozaikCCTPArcForwarderTest is CCTPBaseTest {
    function setUp() public override {
        super.setUp();

        implementation =
            new MozaikCCTPArcForwarder(ITokenMessengerV2(address(messenger)), address(baseUsdc), BASE_CHAIN_ID);
        factory = new MozaikCCTPForwarderFactory(implementation);
        forwarder = MozaikCCTPForwarder(factory.deploy(account));
    }

    function testFuzz_Receive_AcceptsNativeCoin(uint96 amount) public {
        vm.deal(address(this), amount);

        (bool ok,) = address(forwarder).call{value: amount}("");

        assertTrue(ok);
        assertEq(address(forwarder).balance, amount);
    }

    function test_HandleFinalized_ValidNativeReceived() public {
        vm.deal(address(this), 1 ether);
        address to = makeAddr("to");
        (bool ok,) = address(forwarder).call{value: 1 ether}("");
        assertTrue(ok);

        transmitter.deliver(
            address(forwarder), BASE_DOMAIN, _accountSender(), 2000, _rescueBody(address(0), to, 1 ether)
        );

        assertEq(to.balance, 1 ether);
        assertEq(address(forwarder).balance, 0);
    }
}
