// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {MozaikCCTPForwarder} from "../../src/cctp/MozaikCCTPForwarder.sol";
import {ITokenMessengerV2} from "../../src/cctp/ITokenMessengerV2.sol";
import {CCTPBaseTest, MockTokenMessengerV2} from "./CCTPBaseTest.t.sol";

/// @dev Contract without a receive or fallback, so native-coin sends to it fail.
contract NativeRejecter {}

contract MozaikCCTPForwarderTest is CCTPBaseTest {
    uint256 internal constant AMOUNT = 50_000_000; // 50 USDC
    uint256 internal constant FEE_CAP = AMOUNT * 20 / 10_000; // 20 bps

    function _assertBurn(uint256 amount, uint256 maxFee, uint32 threshold) internal view {
        assertEq(messenger.burnCount(), 1, "burn count");

        MockTokenMessengerV2.Burn memory burn = messenger.burnAt(0);
        assertEq(burn.depositor, address(forwarder), "depositor");
        assertEq(burn.amount, amount, "amount");
        assertEq(burn.destinationDomain, BASE_DOMAIN, "destination domain");
        assertEq(burn.mintRecipient, _accountSender(), "mint recipient");
        assertEq(burn.burnToken, address(usdc), "burn token");
        assertEq(burn.destinationCaller, bytes32(0), "destination caller");
        assertEq(burn.maxFee, maxFee, "max fee");
        assertEq(burn.minFinalityThreshold, threshold, "threshold");

        assertEq(usdc.balanceOf(address(forwarder)), 0, "forwarder balance");
        assertEq(usdc.balanceOf(address(minter)), amount, "burned amount");
        assertEq(usdc.allowance(address(forwarder), address(messenger)), 0, "leftover allowance");
    }

    function test_Constructor_SetsConfig() public view {
        assertEq(address(implementation.TOKEN_MESSENGER()), address(messenger));
        assertEq(implementation.BASE_USDC(), address(baseUsdc));
        assertEq(implementation.BASE_CHAIN_ID(), BASE_CHAIN_ID);
        assertEq(implementation.MAX_FEE_BPS(), 20);
    }

    function test_Constructor_InvalidZeroConfig() public {
        ITokenMessengerV2 m = ITokenMessengerV2(address(messenger));

        vm.expectRevert(MozaikCCTPForwarder.InvalidInput.selector);
        new MozaikCCTPForwarder(ITokenMessengerV2(address(0)), address(baseUsdc), BASE_CHAIN_ID);

        vm.expectRevert(MozaikCCTPForwarder.InvalidInput.selector);
        new MozaikCCTPForwarder(m, address(0), BASE_CHAIN_ID);

        vm.expectRevert(MozaikCCTPForwarder.InvalidInput.selector);
        new MozaikCCTPForwarder(m, address(baseUsdc), 0);
    }

    function test_Account_ReturnsCloneArgument() public view {
        assertEq(forwarder.account(), account);
    }

    function test_Forward_ValidFastAtFeeCap() public {
        usdc.mint(address(forwarder), AMOUNT);

        vm.expectEmit(true, true, true, true, address(forwarder));
        emit MozaikCCTPForwarder.Forwarded(AMOUNT, FEE_CAP, 1000);

        vm.prank(makeAddr("anyone"));
        forwarder.forward(AMOUNT, FEE_CAP, 1000);

        _assertBurn(AMOUNT, FEE_CAP, 1000);
    }

    function test_Forward_ValidFastWithZeroFee() public {
        usdc.mint(address(forwarder), AMOUNT);

        forwarder.forward(AMOUNT, 0, 1000);

        _assertBurn(AMOUNT, 0, 1000);
    }

    function test_Forward_ValidStandard() public {
        usdc.mint(address(forwarder), AMOUNT);

        forwarder.forward(AMOUNT, 0, 2000);

        _assertBurn(AMOUNT, 0, 2000);
    }

    function test_Forward_ValidPartialBalance() public {
        usdc.mint(address(forwarder), AMOUNT);

        forwarder.forward(AMOUNT / 2, 0, 2000);

        assertEq(usdc.balanceOf(address(forwarder)), AMOUNT / 2);
        assertEq(usdc.balanceOf(address(minter)), AMOUNT / 2);
    }

    function test_Forward_SourceIgnoresBaseUsdc() public {
        baseUsdc.mint(address(forwarder), AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(forwarder), 0, AMOUNT)
        );
        forwarder.forward(AMOUNT, 0, 2000);

        assertEq(baseUsdc.balanceOf(address(forwarder)), AMOUNT);
    }

    function test_Forward_InvalidZeroAmount() public {
        vm.expectRevert(MozaikCCTPForwarder.InvalidInput.selector);
        forwarder.forward(0, 0, 2000);
    }

    function test_Forward_InvalidFeeAboveCap() public {
        usdc.mint(address(forwarder), AMOUNT);

        vm.expectRevert(MozaikCCTPForwarder.InvalidInput.selector);
        forwarder.forward(AMOUNT, FEE_CAP + 1, 1000);
    }

    function test_Forward_ValidStandardAtFeeCap() public {
        usdc.mint(address(forwarder), AMOUNT);

        forwarder.forward(AMOUNT, FEE_CAP, 2000);

        _assertBurn(AMOUNT, FEE_CAP, 2000);
    }

    function test_Forward_InvalidStandardFeeAboveCap() public {
        usdc.mint(address(forwarder), AMOUNT);

        vm.expectRevert(MozaikCCTPForwarder.InvalidInput.selector);
        forwarder.forward(AMOUNT, FEE_CAP + 1, 2000);
    }

    function test_Forward_InvalidThresholds() public {
        usdc.mint(address(forwarder), AMOUNT);

        uint32[6] memory thresholds = [uint32(0), 500, 999, 1001, 1999, 2001];
        for (uint256 i = 0; i < thresholds.length; i++) {
            vm.expectRevert(MozaikCCTPForwarder.InvalidInput.selector);
            forwarder.forward(AMOUNT, 0, thresholds[i]);
        }
    }

    function test_Forward_InvalidInsufficientBalance() public {
        usdc.mint(address(forwarder), AMOUNT - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(forwarder), AMOUNT - 1, AMOUNT
            )
        );
        forwarder.forward(AMOUNT, 0, 2000);
    }

    function test_Forward_InvalidUnlinkedUsdc() public {
        minter.setLocalToken(BASE_DOMAIN, address(baseUsdc), address(0));
        usdc.mint(address(forwarder), AMOUNT);

        vm.expectRevert(MozaikCCTPForwarder.UnsupportedChain.selector);
        forwarder.forward(AMOUNT, 0, 2000);
    }

    function test_Forward_BaseTransfersToAccount() public {
        vm.chainId(BASE_CHAIN_ID);
        baseUsdc.mint(address(forwarder), AMOUNT);

        vm.expectEmit(true, true, true, true, address(forwarder));
        emit MozaikCCTPForwarder.Forwarded(AMOUNT, 0, 0);

        vm.prank(makeAddr("anyone"));
        forwarder.forward(AMOUNT, 0, 0);

        assertEq(baseUsdc.balanceOf(account), AMOUNT, "account balance");
        assertEq(baseUsdc.balanceOf(address(forwarder)), 0, "forwarder balance");
        assertEq(messenger.burnCount(), 0, "no burn on Base");
    }

    function test_Forward_BaseIgnoresThreshold() public {
        vm.chainId(BASE_CHAIN_ID);
        baseUsdc.mint(address(forwarder), AMOUNT);

        forwarder.forward(AMOUNT, 0, 12345);

        assertEq(baseUsdc.balanceOf(account), AMOUNT);
    }

    function test_Forward_BaseInvalidFee() public {
        vm.chainId(BASE_CHAIN_ID);
        baseUsdc.mint(address(forwarder), AMOUNT);

        vm.expectRevert(MozaikCCTPForwarder.InvalidInput.selector);
        forwarder.forward(AMOUNT, 1, 1000);
    }

    function test_Forward_BaseWorksWithoutCircleContracts() public {
        vm.chainId(BASE_CHAIN_ID);
        vm.etch(address(messenger), "");
        baseUsdc.mint(address(forwarder), AMOUNT);

        forwarder.forward(AMOUNT, 0, 0);

        assertEq(baseUsdc.balanceOf(account), AMOUNT);
    }

    function test_Rescue_ValidErc20OnBase() public {
        vm.chainId(BASE_CHAIN_ID);
        ERC20Mock token = new ERC20Mock();
        token.mint(address(forwarder), 7);
        address to = makeAddr("to");

        vm.expectEmit(true, true, true, true, address(forwarder));
        emit MozaikCCTPForwarder.Rescued(address(token), to, 7);

        vm.prank(account);
        forwarder.rescue(address(token), to, 7);

        assertEq(token.balanceOf(to), 7);
    }

    function test_Rescue_ValidNativeOnBase() public {
        vm.chainId(BASE_CHAIN_ID);
        vm.deal(address(forwarder), 1 ether);
        address to = makeAddr("to");

        vm.expectEmit(true, true, true, true, address(forwarder));
        emit MozaikCCTPForwarder.Rescued(address(0), to, 1 ether);

        vm.prank(account);
        forwarder.rescue(address(0), to, 1 ether);

        assertEq(to.balance, 1 ether);
        assertEq(address(forwarder).balance, 0);
    }

    function test_Rescue_ValidWithoutCircleContracts() public {
        vm.chainId(BASE_CHAIN_ID);
        vm.etch(address(messenger), "");
        baseUsdc.mint(address(forwarder), AMOUNT);

        vm.prank(account);
        forwarder.rescue(address(baseUsdc), account, AMOUNT);

        assertEq(baseUsdc.balanceOf(account), AMOUNT);
    }

    function test_Rescue_InvalidNativeToRejecter() public {
        vm.chainId(BASE_CHAIN_ID);
        vm.deal(address(forwarder), 1 ether);
        address to = address(new NativeRejecter());

        vm.prank(account);
        vm.expectRevert(Errors.FailedCall.selector);
        forwarder.rescue(address(0), to, 1 ether);
    }

    function test_Rescue_InvalidNonAccount() public {
        vm.chainId(BASE_CHAIN_ID);
        baseUsdc.mint(address(forwarder), AMOUNT);
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(MozaikCCTPForwarder.UnauthorizedCaller.selector, attacker));
        forwarder.rescue(address(baseUsdc), attacker, AMOUNT);
    }

    function test_Rescue_InvalidOffBase() public {
        usdc.mint(address(forwarder), AMOUNT);

        vm.prank(account);
        vm.expectRevert(MozaikCCTPForwarder.UnsupportedChain.selector);
        forwarder.rescue(address(usdc), account, AMOUNT);
    }

    function test_HandleFinalized_ValidErc20() public {
        ERC20Mock token = new ERC20Mock();
        token.mint(address(forwarder), 9);
        address to = makeAddr("to");

        vm.expectEmit(true, true, true, true, address(forwarder));
        emit MozaikCCTPForwarder.Rescued(address(token), to, 9);

        bool ok = transmitter.deliver(
            address(forwarder), BASE_DOMAIN, _accountSender(), 2000, _rescueBody(address(token), to, 9)
        );

        assertTrue(ok);
        assertEq(token.balanceOf(to), 9);
    }

    function test_HandleFinalized_ValidNative() public {
        vm.deal(address(forwarder), 2 ether);
        address to = makeAddr("to");

        transmitter.deliver(
            address(forwarder), BASE_DOMAIN, _accountSender(), 2000, _rescueBody(address(0), to, 2 ether)
        );

        assertEq(to.balance, 2 ether);
    }

    function test_HandleFinalized_ValidAboveStandardThreshold() public {
        usdc.mint(address(forwarder), AMOUNT);
        address to = makeAddr("to");

        transmitter.deliver(
            address(forwarder), BASE_DOMAIN, _accountSender(), 2500, _rescueBody(address(usdc), to, AMOUNT)
        );

        assertEq(usdc.balanceOf(to), AMOUNT);
    }

    function test_HandleFinalized_InvalidBelowStandardThreshold() public {
        usdc.mint(address(forwarder), AMOUNT);

        uint32[3] memory thresholds = [uint32(0), 1000, 1999];
        for (uint256 i = 0; i < thresholds.length; i++) {
            vm.prank(address(transmitter));
            vm.expectRevert(MozaikCCTPForwarder.InvalidMessage.selector);
            forwarder.handleReceiveFinalizedMessage(
                BASE_DOMAIN, _accountSender(), thresholds[i], _rescueBody(address(usdc), account, AMOUNT)
            );
        }

        assertEq(usdc.balanceOf(address(forwarder)), AMOUNT);
    }

    function test_HandleFinalized_InvalidCaller() public {
        usdc.mint(address(forwarder), AMOUNT);
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(MozaikCCTPForwarder.UnauthorizedCaller.selector, attacker));
        forwarder.handleReceiveFinalizedMessage(
            BASE_DOMAIN, _accountSender(), 2000, _rescueBody(address(usdc), attacker, AMOUNT)
        );
    }

    function test_HandleFinalized_InvalidSourceDomain() public {
        usdc.mint(address(forwarder), AMOUNT);

        vm.expectRevert(MozaikCCTPForwarder.InvalidMessage.selector);
        transmitter.deliver(address(forwarder), 0, _accountSender(), 2000, _rescueBody(address(usdc), account, AMOUNT));
    }

    function test_HandleFinalized_InvalidSender() public {
        usdc.mint(address(forwarder), AMOUNT);
        bytes32 other = bytes32(uint256(uint160(makeAddr("other"))));

        vm.expectRevert(MozaikCCTPForwarder.InvalidMessage.selector);
        transmitter.deliver(address(forwarder), BASE_DOMAIN, other, 2000, _rescueBody(address(usdc), account, AMOUNT));
    }

    function test_HandleFinalized_InvalidDirtySenderPadding() public {
        usdc.mint(address(forwarder), AMOUNT);
        bytes32 dirty = _accountSender() | bytes32(uint256(1) << 200);

        vm.expectRevert(MozaikCCTPForwarder.InvalidMessage.selector);
        transmitter.deliver(address(forwarder), BASE_DOMAIN, dirty, 2000, _rescueBody(address(usdc), account, AMOUNT));
    }

    function test_HandleFinalized_InvalidShortBody() public {
        usdc.mint(address(forwarder), AMOUNT);

        vm.expectRevert(bytes(""));
        transmitter.deliver(address(forwarder), BASE_DOMAIN, _accountSender(), 2000, abi.encode(address(usdc)));

        assertEq(usdc.balanceOf(address(forwarder)), AMOUNT);
    }

    function test_HandleFinalized_ValidIgnoresTrailingBytes() public {
        usdc.mint(address(forwarder), AMOUNT);
        address to = makeAddr("to");
        bytes memory body = bytes.concat(_rescueBody(address(usdc), to, AMOUNT), bytes1(0xff));

        transmitter.deliver(address(forwarder), BASE_DOMAIN, _accountSender(), 2000, body);

        assertEq(usdc.balanceOf(to), AMOUNT);
    }

    /// @dev A rescue that failed to deliver cannot move a later deposit after its deadline.
    function test_HandleFinalized_FailedRescueExpires() public {
        usdc.mint(address(forwarder), AMOUNT);
        address to = makeAddr("to");
        bytes memory body = abi.encode(address(usdc), to, AMOUNT, block.timestamp + 1 hours);

        forwarder.forward(AMOUNT, 0, 2000);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(forwarder), 0, AMOUNT)
        );
        transmitter.deliver(address(forwarder), BASE_DOMAIN, _accountSender(), 2000, body);

        vm.warp(block.timestamp + 1 hours + 1);
        usdc.mint(address(forwarder), AMOUNT);

        vm.expectRevert(MozaikCCTPForwarder.InvalidMessage.selector);
        transmitter.deliver(address(forwarder), BASE_DOMAIN, _accountSender(), 2000, body);

        assertEq(usdc.balanceOf(address(forwarder)), AMOUNT);
        assertEq(usdc.balanceOf(to), 0);
    }

    function test_HandleFinalized_InvalidBodyWithoutDeadline() public {
        usdc.mint(address(forwarder), AMOUNT);

        vm.expectRevert(bytes(""));
        transmitter.deliver(
            address(forwarder), BASE_DOMAIN, _accountSender(), 2000, abi.encode(address(usdc), account, AMOUNT)
        );

        assertEq(usdc.balanceOf(address(forwarder)), AMOUNT);
    }

    function test_HandleFinalized_InvalidDirtyAddressInBody() public {
        usdc.mint(address(forwarder), AMOUNT);
        bytes memory body =
            abi.encode(uint256(uint160(address(usdc))) | (uint256(1) << 200), account, AMOUNT, block.timestamp);

        vm.expectRevert(bytes(""));
        transmitter.deliver(address(forwarder), BASE_DOMAIN, _accountSender(), 2000, body);
    }

    function test_HandleUnfinalized_AlwaysReverts() public {
        usdc.mint(address(forwarder), AMOUNT);

        vm.expectRevert(MozaikCCTPForwarder.InvalidMessage.selector);
        transmitter.deliver(
            address(forwarder), BASE_DOMAIN, _accountSender(), 1000, _rescueBody(address(usdc), account, AMOUNT)
        );
    }

    function test_Implementation_RejectsEveryEntryPoint() public {
        usdc.mint(address(implementation), AMOUNT);

        vm.expectRevert(MozaikCCTPForwarder.NotClone.selector);
        implementation.account();

        vm.expectRevert(MozaikCCTPForwarder.NotClone.selector);
        implementation.forward(AMOUNT, 0, 2000);

        vm.expectRevert(MozaikCCTPForwarder.NotClone.selector);
        implementation.rescue(address(usdc), account, AMOUNT);

        vm.prank(address(transmitter));
        vm.expectRevert(MozaikCCTPForwarder.NotClone.selector);
        implementation.handleReceiveFinalizedMessage(
            BASE_DOMAIN, _accountSender(), 2000, _rescueBody(address(usdc), account, AMOUNT)
        );

        assertEq(usdc.balanceOf(address(implementation)), AMOUNT);
    }

    function test_Receive_RejectsNativeCoin() public {
        vm.deal(address(this), 1 ether);

        (bool ok,) = address(forwarder).call{value: 1 ether}("");

        assertFalse(ok);
        assertEq(address(forwarder).balance, 0);
    }

    function testFuzz_Forward_FeeBound(uint256 amount, uint256 maxFee, bool standard) public {
        amount = bound(amount, 1, 1e18);
        maxFee = bound(maxFee, 0, amount);
        uint32 threshold = standard ? 2000 : 1000;
        usdc.mint(address(forwarder), amount);

        if (maxFee * 10_000 > amount * 20) {
            vm.expectRevert(MozaikCCTPForwarder.InvalidInput.selector);
            forwarder.forward(amount, maxFee, threshold);

            return;
        }

        forwarder.forward(amount, maxFee, threshold);

        _assertBurn(amount, maxFee, threshold);
    }

    function testFuzz_Forward_AnyCallerAnyAmountReachesAccount(address caller, uint256 amount, bool base) public {
        amount = bound(amount, 1, 1e18);
        if (base) vm.chainId(BASE_CHAIN_ID);
        (base ? baseUsdc : usdc).mint(address(forwarder), amount);

        vm.prank(caller);
        forwarder.forward(amount, 0, 2000);

        if (base) {
            assertEq(baseUsdc.balanceOf(account), amount);
        } else {
            _assertBurn(amount, 0, 2000);
        }
    }

    function testFuzz_HandleFinalized_RejectsForeignSenders(uint32 sourceDomain, bytes32 sender) public {
        vm.assume(sourceDomain != BASE_DOMAIN || sender != _accountSender());
        usdc.mint(address(forwarder), AMOUNT);

        vm.expectRevert(MozaikCCTPForwarder.InvalidMessage.selector);
        transmitter.deliver(
            address(forwarder), sourceDomain, sender, 2000, _rescueBody(address(usdc), address(this), AMOUNT)
        );
    }

    function testFuzz_HandleFinalized_Deadline(uint256 deadline) public {
        vm.warp(1_790_000_000);
        usdc.mint(address(forwarder), AMOUNT);
        address to = makeAddr("to");
        bytes memory body = abi.encode(address(usdc), to, AMOUNT, deadline);

        if (deadline < block.timestamp) {
            vm.expectRevert(MozaikCCTPForwarder.InvalidMessage.selector);
            transmitter.deliver(address(forwarder), BASE_DOMAIN, _accountSender(), 2000, body);
            assertEq(usdc.balanceOf(to), 0);
        } else {
            transmitter.deliver(address(forwarder), BASE_DOMAIN, _accountSender(), 2000, body);
            assertEq(usdc.balanceOf(to), AMOUNT);
        }
    }

    function testFuzz_Rescue_RejectsNonAccount(address caller, uint256 chainId) public {
        vm.assume(caller != account);
        vm.chainId(bound(chainId, 1, type(uint64).max));
        usdc.mint(address(forwarder), AMOUNT);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(MozaikCCTPForwarder.UnauthorizedCaller.selector, caller));
        forwarder.rescue(address(usdc), caller, AMOUNT);
    }

    function testFuzz_Rescue_OnlyOnBase(uint256 chainId) public {
        chainId = bound(chainId, 1, type(uint64).max);
        vm.chainId(chainId);
        usdc.mint(address(forwarder), AMOUNT);

        vm.prank(account);
        if (chainId != BASE_CHAIN_ID) {
            vm.expectRevert(MozaikCCTPForwarder.UnsupportedChain.selector);
            forwarder.rescue(address(usdc), account, AMOUNT);

            return;
        }

        forwarder.rescue(address(usdc), account, AMOUNT);
        assertEq(usdc.balanceOf(account), AMOUNT);
    }
}
