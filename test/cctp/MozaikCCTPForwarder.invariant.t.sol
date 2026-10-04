// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {MozaikCCTPForwarder} from "../../src/cctp/MozaikCCTPForwarder.sol";
import {CCTPBaseTest, MockMessageTransmitterV2, MockTokenMessengerV2} from "./CCTPBaseTest.t.sol";

/// @notice Invariant handler that drives one forwarder with random forwards, rescues and forged messages.
/// @dev Ghost totals count USDC that left the forwarder through each allowed exit. Any call that succeeds
///      without the account's authorization sets `unauthorizedExit`, and a call that meets every precondition
///      must succeed.
contract ForwarderHandler is Test {
    MozaikCCTPForwarder public forwarder;
    MozaikCCTPForwarder public implementation;
    MockMessageTransmitterV2 public transmitter;
    ERC20Mock public usdc;
    address public account;
    address public rescueTo;

    bool public onBase;

    // Ghost variables for invariant tracking
    uint256 public funded;
    uint256 public burned;
    uint256 public transferred;
    uint256 public rescued;
    bool public unauthorizedExit;
    bool public validCallReverted;
    bool public invalidCallSucceeded;

    constructor(
        MozaikCCTPForwarder _forwarder,
        MozaikCCTPForwarder _implementation,
        MockMessageTransmitterV2 _transmitter,
        ERC20Mock _usdc,
        address _account
    ) {
        forwarder = _forwarder;
        implementation = _implementation;
        transmitter = _transmitter;
        usdc = _usdc;
        account = _account;
        rescueTo = makeAddr("rescueTo");
    }

    /// @dev The chain id does not persist between handler calls, so each call that depends on it sets it.
    function _setChainId() internal {
        vm.chainId(onBase ? 8453 : 42161);
    }

    function fund(uint256 amount) external {
        amount = bound(amount, 1, 1e13);

        usdc.mint(address(forwarder), amount);
        funded += amount;
    }

    function switchChain(bool base) external {
        onBase = base;
    }

    function forward(address caller, uint256 amount, uint256 maxFee, uint256 thresholdSeed) external {
        uint256 balance = usdc.balanceOf(address(forwarder));
        if (balance == 0) return;

        amount = bound(amount, 1, balance);
        maxFee = maxFee % 2 == 0 ? 0 : bound(maxFee, 0, amount * 30 / 10_000);
        uint32 threshold = [uint32(1000), 2000, 0, uint32(thresholdSeed)][thresholdSeed % 4];
        bool valid = onBase ? maxFee == 0 : (threshold == 1000 || threshold == 2000) && maxFee <= amount * 20 / 10_000;

        _setChainId();
        vm.prank(caller);
        try forwarder.forward(amount, maxFee, threshold) {
            if (!valid) invalidCallSucceeded = true;
            if (onBase) {
                transferred += amount;
            } else {
                burned += amount;
            }
        } catch {
            if (valid) validCallReverted = true;
        }
    }

    function rescueDirect(address caller, bool asAccount, uint256 amount) external {
        if (asAccount) caller = account;
        amount = bound(amount, 0, usdc.balanceOf(address(forwarder)));

        bool authorized = caller == account && onBase;

        _setChainId();
        vm.prank(caller);
        try forwarder.rescue(address(usdc), rescueTo, amount) {
            if (!authorized) unauthorizedExit = true;
            rescued += amount;
        } catch {
            if (authorized) validCallReverted = true;
        }
    }

    /// @dev Delivers through the transmitter, a misrouting transmitter or a direct call.
    function rescueMessage(
        uint8 route,
        bool fromAccount,
        bytes32 sender,
        uint32 sourceDomain,
        uint32 threshold,
        uint256 amount,
        uint256 deadline
    ) external {
        if (fromAccount) sender = bytes32(uint256(uint160(account)));
        if (sourceDomain % 4 != 0) sourceDomain = 6;
        if (threshold % 3 == 0) threshold = 1000;
        amount = bound(amount, 0, usdc.balanceOf(address(forwarder)));
        bytes memory body = abi.encode(address(usdc), rescueTo, amount, deadline);

        route %= 3;
        bool authorized = route != 2 && sourceDomain == 6 && sender == bytes32(uint256(uint160(account)))
            && threshold >= 2000 && block.timestamp <= deadline;

        _setChainId();
        bool ok;
        if (route == 0) {
            try transmitter.deliver(address(forwarder), sourceDomain, sender, threshold, body) {
                ok = true;
            } catch {}
        } else if (route == 1) {
            try transmitter.deliverFinalized(address(forwarder), sourceDomain, sender, threshold, body) {
                ok = true;
            } catch {}
        } else {
            try forwarder.handleReceiveFinalizedMessage(sourceDomain, sender, threshold, body) {
                ok = true;
            } catch {}
        }

        if (!ok) {
            if (authorized) validCallReverted = true;

            return;
        }

        if (!authorized) unauthorizedExit = true;
        rescued += amount;
    }

    function callImplementation(uint256 amount) external {
        amount = bound(amount, 1, 1e13);
        usdc.mint(address(implementation), amount);

        try implementation.forward(amount, 0, 2000) {
            unauthorizedExit = true;
        } catch {}
    }
}

contract MozaikCCTPForwarderInvariantTest is CCTPBaseTest {
    ForwarderHandler internal handler;

    /// @dev One token plays both roles (Base USDC and the source-chain USDC linked to it), so the ghost totals
    ///      cover both chains.
    function setUp() public override {
        super.setUp();
        usdc = baseUsdc;
        minter.setLocalToken(BASE_DOMAIN, address(baseUsdc), address(baseUsdc));

        handler = new ForwarderHandler(forwarder, implementation, transmitter, usdc, account);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = ForwarderHandler.fund.selector;
        selectors[1] = ForwarderHandler.switchChain.selector;
        selectors[2] = ForwarderHandler.forward.selector;
        selectors[3] = ForwarderHandler.rescueDirect.selector;
        selectors[4] = ForwarderHandler.rescueMessage.selector;
        selectors[5] = ForwarderHandler.callImplementation.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Every unit that entered the forwarder is still there or left through an allowed exit.
    function invariant_BalanceMatchesExits() public view {
        assertEq(
            usdc.balanceOf(address(forwarder)) + handler.burned() + handler.transferred() + handler.rescued(),
            handler.funded(),
            "forwarder balance does not match its exits"
        );
    }

    /// @dev No call moves value without the account's authorization, and the implementation never forwards.
    function invariant_NoUnauthorizedExit() public view {
        assertFalse(handler.unauthorizedExit(), "value left without the account's authorization");
    }

    /// @dev Calls that meet every precondition succeed, and invalid forwards revert.
    function invariant_CallsMatchModel() public view {
        assertFalse(handler.validCallReverted(), "a valid call reverted");
        assertFalse(handler.invalidCallSucceeded(), "an invalid forward succeeded");
    }

    /// @dev Every burn goes to the account on Base, with no destination caller and a fee within the cap.
    function invariant_BurnsGoOnlyToAccount() public view {
        assertEq(usdc.balanceOf(address(minter)), handler.burned(), "burned total");

        uint256 count = messenger.burnCount();
        for (uint256 i = 0; i < count; i++) {
            MockTokenMessengerV2.Burn memory burn = messenger.burnAt(i);

            assertEq(burn.depositor, address(forwarder), "depositor");
            assertEq(burn.mintRecipient, _accountSender(), "mint recipient");
            assertEq(burn.destinationDomain, BASE_DOMAIN, "destination domain");
            assertEq(burn.destinationCaller, bytes32(0), "destination caller");
            assertTrue(burn.minFinalityThreshold == 1000 || burn.minFinalityThreshold == 2000, "threshold");
            assertLe(burn.maxFee * 10_000, burn.amount * 20, "fee cap");
        }
    }

    /// @dev The account receives exactly the Base transfers, and the rescue recipient exactly the rescues.
    function invariant_AccountReceivesOnlyTransfers() public view {
        assertEq(usdc.balanceOf(account), handler.transferred(), "account balance does not match transfers");
        assertEq(usdc.balanceOf(handler.rescueTo()), handler.rescued(), "recipient balance does not match rescues");
    }
}
