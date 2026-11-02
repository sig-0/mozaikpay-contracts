// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {MozaikCCTPArcForwarder} from "../../src/cctp/MozaikCCTPArcForwarder.sol";
import {MozaikCCTPForwarder} from "../../src/cctp/MozaikCCTPForwarder.sol";
import {MozaikCCTPForwarderFactory} from "../../src/cctp/MozaikCCTPForwarderFactory.sol";
import {ITokenMessengerV2} from "../../src/cctp/ITokenMessengerV2.sol";
import {CCTPBaseTest, MockMessageTransmitterV2} from "./CCTPBaseTest.t.sol";
import {ForwarderHandler, MozaikCCTPForwarderInvariantTest} from "./MozaikCCTPForwarder.invariant.t.sol";

/// @notice ForwarderHandler that also sends the native coin to an Arc forwarder and rescues it.
/// @dev Ghost totals count the native coin that entered the forwarder and left it through a rescue.
contract ArcForwarderHandler is ForwarderHandler {
    uint256 public nativeFunded;
    uint256 public nativeRescued;
    bool public nativeSendReverted;

    constructor(
        MozaikCCTPForwarder _forwarder,
        MozaikCCTPForwarder _implementation,
        MockMessageTransmitterV2 _transmitter,
        ERC20Mock _usdc,
        address _account,
        uint256 _burnLimit
    ) ForwarderHandler(_forwarder, _implementation, _transmitter, _usdc, _account, _burnLimit) {}

    function sendNative(uint256 amount) external {
        amount = bound(amount, 1, 1e30);
        vm.deal(address(this), amount);

        (bool ok,) = address(forwarder).call{value: amount}("");
        if (!ok) {
            nativeSendReverted = true;

            return;
        }

        nativeFunded += amount;
    }

    function rescueNativeDirect(address caller, bool asAccount, uint256 amount) external {
        nativeRescued += _rescueDirect(address(0), caller, asAccount, amount);
    }

    function rescueNativeMessage(
        uint8 route,
        bool fromAccount,
        bytes32 sender,
        uint32 sourceDomain,
        uint32 threshold,
        uint256 amount,
        uint256 deadline
    ) external {
        nativeRescued += _rescueMessage(
            address(0), route, fromAccount, sender, sourceDomain, threshold, amount, deadline
        );
    }
}

/// @notice Runs every v1 forwarder invariant on an Arc forwarder clone, plus the native coin invariants.
contract MozaikCCTPArcForwarderInvariantTest is MozaikCCTPForwarderInvariantTest {
    ArcForwarderHandler internal arcHandler;

    function setUp() public override {
        CCTPBaseTest.setUp();
        _shareUsdc();

        implementation =
            new MozaikCCTPArcForwarder(ITokenMessengerV2(address(messenger)), address(baseUsdc), BASE_CHAIN_ID);
        factory = new MozaikCCTPForwarderFactory(implementation);
        forwarder = MozaikCCTPForwarder(factory.deploy(account));
        arcHandler = new ArcForwarderHandler(forwarder, implementation, transmitter, usdc, account, BURN_LIMIT);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = ArcForwarderHandler.sendNative.selector;
        selectors[1] = ArcForwarderHandler.rescueNativeDirect.selector;
        selectors[2] = ArcForwarderHandler.rescueNativeMessage.selector;
        _target(arcHandler, selectors);
    }

    /// @dev In this model the mock USDC and the native coin are separate balances, so forward cannot move native coin
    ///      and native coin leaves only through rescues to the rescue recipient. On Arc they are one balance.
    function invariant_NativeBalanceMatchesExits() public view {
        assertEq(
            address(forwarder).balance + arcHandler.nativeRescued(),
            arcHandler.nativeFunded(),
            "forwarder native balance does not match its rescues"
        );
        assertEq(arcHandler.rescueTo().balance, arcHandler.nativeRescued(), "recipient balance does not match rescues");
    }

    /// @dev Every plain native coin send to the clone succeeds.
    function invariant_NativeSendsSucceed() public view {
        assertFalse(arcHandler.nativeSendReverted(), "a native send reverted");
    }
}
