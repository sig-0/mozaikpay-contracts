// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";

import {MozaikAccountFactory} from "../src/account/MozaikAccountFactory.sol";
import {MozaikVerifyingPaymaster} from "../src/paymaster/MozaikVerifyingPaymaster.sol";

contract PaymasterHandler is Test {
    bytes8 internal constant PAYMASTER_SIG_MAGIC = 0x22e325a297439656;
    address internal constant ENTRY_POINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;

    EntryPoint public entryPoint;
    MozaikVerifyingPaymaster public paymaster;
    MozaikAccountFactory public factory;

    address internal verifyingSignerAddr;
    uint256 internal verifyingSignerKey;

    uint256 public totalDeposited;
    uint256 public totalWithdrawn;

    // Ghost variables for invariant tracking
    bool public unsignedOpEverSponsored;
    bool public expiredSigEverRejected;

    constructor() {
        (, verifyingSignerKey) = makeAddrAndKey("verifyingSigner");
        verifyingSignerAddr = vm.addr(verifyingSignerKey);

        deployCodeTo("EntryPoint.sol:EntryPoint", ENTRY_POINT_V09);
        entryPoint = EntryPoint(payable(ENTRY_POINT_V09));
        factory = new MozaikAccountFactory();
        paymaster = new MozaikVerifyingPaymaster(verifyingSignerAddr);

        vm.deal(address(this), 100 ether);
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 0, 10 ether);

        vm.deal(address(this), address(this).balance + amount);

        paymaster.deposit{value: amount}();
        totalDeposited += amount;
    }

    function withdraw(uint256 amount) external {
        uint256 balance = entryPoint.balanceOf(address(paymaster));

        if (balance == 0) return;

        amount = bound(amount, 0, balance);

        paymaster.withdrawTo(payable(address(this)), amount);
        totalWithdrawn += amount;
    }

    function sponsorOp(address owner, uint48 validUntil) external {
        validUntil = uint48(bound(validUntil, block.timestamp + 1, type(uint48).max));

        owner = address(uint160(bound(uint256(uint160(owner)), 1, type(uint160).max)));
        address sender = factory.computeAddress(owner, owner);

        PackedUserOperation memory op;
        op.sender = sender;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(200_000), uint128(200_000)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(2 gwei)));

        bytes32 digest = keccak256(
            abi.encode(
                address(paymaster),
                block.chainid,
                op.sender,
                op.nonce,
                keccak256(op.initCode),
                keccak256(op.callData),
                op.accountGasLimits,
                op.preVerificationGas,
                op.gasFees,
                validUntil,
                uint48(0)
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(verifyingSignerKey, digest);

        bytes memory sig = abi.encodePacked(r, s, v);

        op.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(100_000),
            uint128(0),
            validUntil,
            uint48(0),
            sig,
            uint16(sig.length),
            PAYMASTER_SIG_MAGIC
        );

        vm.prank(address(entryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);

        assertEq(validationData & type(uint160).max, 0, "valid op must pass sig validation");
    }

    function submitExpiredOp(address owner) external {
        uint48 expired = 0; // validUntil = 0 is always in the past

        owner = address(uint160(bound(uint256(uint160(owner)), 1, type(uint160).max)));
        address sender = factory.computeAddress(owner, owner);

        PackedUserOperation memory op;
        op.sender = sender;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(200_000), uint128(200_000)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(2 gwei)));

        bytes32 digest = keccak256(
            abi.encode(
                address(paymaster),
                block.chainid,
                op.sender,
                op.nonce,
                keccak256(op.initCode),
                keccak256(op.callData),
                op.accountGasLimits,
                op.preVerificationGas,
                op.gasFees,
                expired,
                uint48(0)
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(verifyingSignerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        op.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(100_000),
            uint128(0),
            expired,
            uint48(0),
            sig,
            uint16(sig.length),
            PAYMASTER_SIG_MAGIC
        );

        vm.prank(address(entryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);

        // The expired validUntil must be propagated so the EntryPoint can enforce it.
        assertEq((validationData >> 160) & type(uint48).max, 0, "expired validUntil must propagate");

        // A validly-signed op must pass sig validation regardless of time expiry.
        // Sig failure and time expiry are separate concerns, and the paymaster must not confuse them.
        if ((validationData & type(uint160).max) != 0) {
            expiredSigEverRejected = true;
        }
    }

    function submitUnsignedOp(address owner) external {
        owner = address(uint160(bound(uint256(uint160(owner)), 1, type(uint160).max)));
        address sender = factory.computeAddress(owner, owner);

        PackedUserOperation memory op;
        op.sender = sender;
        // paymasterAndData with NO signature suffix
        op.paymasterAndData =
            abi.encodePacked(address(paymaster), uint128(100_000), uint128(0), uint48(type(uint48).max), uint48(0));

        vm.prank(address(entryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);

        if ((validationData & type(uint160).max) == 0) {
            // This should never happen: unsigned op passed sig validation
            unsignedOpEverSponsored = true;
        }
    }

    receive() external payable {}
}

contract MozaikPaymasterInvariantTest is Test {
    PaymasterHandler internal handler;

    function setUp() public {
        handler = new PaymasterHandler();

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _selectors()}));
    }

    function invariant_DepositBalanceConsistent() public view {
        uint256 onChain = handler.entryPoint().balanceOf(address(handler.paymaster()));

        assertEq(onChain, handler.totalDeposited() - handler.totalWithdrawn(), "deposit balance inconsistent");
    }

    function invariant_UnsignedOpNeverSponsored() public view {
        assertFalse(handler.unsignedOpEverSponsored(), "unsigned op must never pass paymaster validation");
    }

    function invariant_ExpiredSigNeverRejected() public view {
        assertFalse(handler.expiredSigEverRejected(), "valid sig on expired op must not be marked as sig-failed");
    }

    function _selectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);

        s[0] = PaymasterHandler.deposit.selector;
        s[1] = PaymasterHandler.withdraw.selector;
        s[2] = PaymasterHandler.sponsorOp.selector;
        s[3] = PaymasterHandler.submitExpiredOp.selector;
        s[4] = PaymasterHandler.submitUnsignedOp.selector;
    }
}
