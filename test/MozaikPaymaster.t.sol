// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPaymaster} from "account-abstraction/interfaces/IPaymaster.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

import {BaseTest} from "./BaseTest.t.sol";
import {MozaikAccount} from "../src/account/MozaikAccount.sol";
import {MozaikVerifyingPaymaster} from "../src/paymaster/MozaikVerifyingPaymaster.sol";

contract MozaikPaymasterTest is BaseTest {
    MozaikAccount internal account;
    uint48 internal validUntil;
    uint48 internal validAfter;

    function setUp() public override {
        super.setUp();

        account = _deployAccount();
        validUntil = uint48(block.timestamp + 1 hours);
        validAfter = 0;
    }

    function test_ValidatePaymasterUserOp_ValidSignature() public {
        PackedUserOperation memory op = _buildUserOp(address(account), "");
        op.paymasterAndData = _signPaymasterApproval(op, validUntil, validAfter, verifyingSignerKey, address(paymaster));

        vm.prank(address(localEntryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);

        // aggregator field (low 20 bytes) must be 0 (success) or SIG_VALIDATION_SUCCESS
        assertEq(validationData & type(uint160).max, 0);
    }

    function test_ValidatePaymasterUserOp_InvalidValidUntil() public {
        uint48 expired = uint48(block.timestamp - 1);
        PackedUserOperation memory op = _buildUserOp(address(account), "");
        op.paymasterAndData = _signPaymasterApproval(op, expired, 0, verifyingSignerKey, address(paymaster));

        vm.prank(address(localEntryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);

        // The signature itself is valid. The paymaster is not the time enforcer.
        // The expired validUntil is propagated so the EntryPoint can reject based on time.
        (address agg, uint48 returnedUntil,) = _unpackValidation(validationData);

        assertEq(agg, address(0));
        assertEq(returnedUntil, expired);
    }

    function test_ValidatePaymasterUserOp_InvalidValidAfter() public {
        uint48 futureAfter = uint48(block.timestamp + 1 days);

        PackedUserOperation memory op = _buildUserOp(address(account), "");
        op.paymasterAndData =
            _signPaymasterApproval(op, validUntil, futureAfter, verifyingSignerKey, address(paymaster));

        vm.prank(address(localEntryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);

        (address agg,, uint48 returnedAfter) = _unpackValidation(validationData);
        assertEq(agg, address(0));
        assertEq(returnedAfter, futureAfter);
    }

    function test_ValidatePaymasterUserOp_InvalidSigner() public {
        (, uint256 wrongKey) = makeAddrAndKey("wrong");
        PackedUserOperation memory op = _buildUserOp(address(account), "");
        op.paymasterAndData = _signPaymasterApproval(op, validUntil, validAfter, wrongKey, address(paymaster));

        vm.prank(address(localEntryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);

        (address agg,,) = _unpackValidation(validationData);
        assertEq(agg, address(1)); // SIG_VALIDATION_FAILED
    }

    function test_ValidatePaymasterUserOp_TamperedSender() public {
        PackedUserOperation memory op = _buildUserOp(address(account), "");
        op.paymasterAndData = _signPaymasterApproval(op, validUntil, validAfter, verifyingSignerKey, address(paymaster));

        // Tamper the sender after signing
        op.sender = attacker;

        vm.prank(address(localEntryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);

        (address agg,,) = _unpackValidation(validationData);
        assertEq(agg, address(1));
    }

    function test_ValidatePaymasterUserOp_TamperedCallData() public {
        PackedUserOperation memory op = _buildUserOp(address(account), "");
        op.paymasterAndData = _signPaymasterApproval(op, validUntil, validAfter, verifyingSignerKey, address(paymaster));

        op.callData = abi.encodeWithSignature("transfer(address,uint256)", attacker, 1000);

        vm.prank(address(localEntryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);

        (address agg,,) = _unpackValidation(validationData);
        assertEq(agg, address(1));
    }

    function test_ValidatePaymasterUserOp_TamperedGasLimits() public {
        PackedUserOperation memory op = _buildUserOp(address(account), "");
        op.paymasterAndData = _signPaymasterApproval(op, validUntil, validAfter, verifyingSignerKey, address(paymaster));

        op.accountGasLimits = bytes32(abi.encodePacked(uint128(2_000_000), uint128(2_000_000)));

        vm.prank(address(localEntryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);

        (address agg,,) = _unpackValidation(validationData);
        assertEq(agg, address(1));
    }

    function test_ValidatePaymasterUserOp_TamperedNonce() public {
        PackedUserOperation memory op = _buildUserOp(address(account), "");
        op.paymasterAndData = _signPaymasterApproval(op, validUntil, validAfter, verifyingSignerKey, address(paymaster));

        op.nonce = 999;

        vm.prank(address(localEntryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);

        (address agg,,) = _unpackValidation(validationData);
        assertEq(agg, address(1));
    }

    function testFuzz_ValidatePaymasterUserOp_ArbitrarySignature(bytes memory sig) public {
        // Only test with 65-byte sigs, as shorter ones produce no recovery, longer ones encode differently
        sig = _resize65(sig);

        PackedUserOperation memory op = _buildUserOp(address(account), "");
        op.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(100_000),
            uint128(0),
            validUntil,
            validAfter,
            sig,
            uint16(sig.length),
            PAYMASTER_SIG_MAGIC
        );

        vm.prank(address(localEntryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);

        // Paymaster must never revert, and an arbitrary signature must never pass
        (address agg,,) = _unpackValidation(validationData);
        assertEq(agg, address(1));
    }

    function _resize65(bytes memory b) internal pure returns (bytes memory out) {
        out = new bytes(65);

        uint256 len = b.length < 65 ? b.length : 65;

        for (uint256 i = 0; i < len; i++) {
            out[i] = b[i];
        }
    }

    function testFuzz_ValidatePaymasterUserOp_ExpiredTimestamp(uint48 vu) public {
        vu = uint48(bound(vu, 0, block.timestamp - 1));
        PackedUserOperation memory op = _buildUserOp(address(account), "");
        op.paymasterAndData = _signPaymasterApproval(op, vu, 0, verifyingSignerKey, address(paymaster));

        vm.prank(address(localEntryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);

        // The signature itself is valid. The expired validUntil is propagated for the EntryPoint to enforce
        (address agg, uint48 returnedUntil,) = _unpackValidation(validationData);
        assertEq(agg, address(0));
        assertEq(returnedUntil, vu);
    }

    function test_MozaikPaymaster_PostOpCalledDirectly() public {
        vm.prank(attacker);
        vm.expectRevert();

        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, "", 0, 0);
    }

    function test_SetVerifyingSigner_UpdatesAddress() public {
        address newSigner = makeAddr("newSigner");

        vm.prank(address(this)); // deployer
        paymaster.setSponsor(newSigner);

        assertEq(paymaster.sponsor(), newSigner);
    }

    function test_SetVerifyingSigner_InvalidOwner() public {
        vm.prank(attacker);
        vm.expectRevert();

        paymaster.setSponsor(attacker);
    }

    function test_SetVerifyingSigner_ZeroAddress() public {
        vm.expectRevert(MozaikVerifyingPaymaster.ZeroAddress.selector);

        vm.prank(address(this)); // deployer
        paymaster.setSponsor(address(0));
    }

    function test_Constructor_RejectsZeroSponsor() public {
        vm.expectRevert(MozaikVerifyingPaymaster.ZeroAddress.selector);
        new MozaikVerifyingPaymaster(address(0));
    }

    function test_Deposit_IncreasedBalance() public {
        uint256 before = localEntryPoint.balanceOf(address(paymaster));

        vm.prank(address(this));
        paymaster.deposit{value: 0.5 ether}();

        assertEq(localEntryPoint.balanceOf(address(paymaster)), before + 0.5 ether);
    }

    function test_Withdraw_DecreasedBalance() public {
        vm.prank(address(this));
        paymaster.deposit{value: 1 ether}();

        uint256 before = localEntryPoint.balanceOf(address(paymaster));

        vm.prank(address(this));
        paymaster.withdrawTo(payable(address(this)), 0.3 ether);

        assertEq(localEntryPoint.balanceOf(address(paymaster)), before - 0.3 ether);
    }

    function test_Withdraw_NonOwner() public {
        paymaster.deposit{value: 0.5 ether}();

        vm.prank(attacker);
        vm.expectRevert();
        paymaster.withdrawTo(payable(attacker), 0.1 ether);
    }

    receive() external payable {}

    function _unpackValidation(uint256 data) internal pure returns (address aggregator, uint48 vUntil, uint48 vAfter) {
        assembly {
            aggregator := and(data, 0xffffffffffffffffffffffffffffffffffffffff)
            vUntil := and(shr(160, data), 0xffffffffffff)
            vAfter := and(shr(208, data), 0xffffffffffff)
        }
    }
}
