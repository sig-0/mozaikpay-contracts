// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {SIG_VALIDATION_SUCCESS, SIG_VALIDATION_FAILED} from "account-abstraction/core/Helpers.sol";

import {BaseTest} from "./BaseTest.t.sol";
import {MozaikAccount} from "../src/account/MozaikAccount.sol";

contract MozaikAccountTest is BaseTest {
    MozaikAccount internal account;

    function setUp() public override {
        super.setUp();

        account = _deployAccount();

        vm.deal(address(account), 1 ether);
    }

    function test_Account_ValidSpendingAndRecovery() public view {
        assertEq(account.spendingSigner(), spendingSigner);
        assertEq(account.recoverySigner(), recoverySigner);
    }

    function test_Account_InvalidInitialize() public {
        vm.expectRevert();
        account.initialize(attacker, attacker);
    }

    function test_Account_ValidUSDCTransfer() public {
        usdc.mint(address(account), 1000e6);

        vm.prank(spendingSigner);
        account.execute(address(usdc), 0, abi.encodeCall(usdc.transfer, (attacker, 500e6)));

        assertEq(usdc.balanceOf(attacker), 500e6);
    }

    function test_Account_ValidUserOpExecute() public {
        usdc.mint(address(account), 1000e6);

        bytes memory callData =
            abi.encodeCall(account.execute, (address(usdc), 0, abi.encodeCall(usdc.transfer, (attacker, 100e6))));

        PackedUserOperation memory op = _buildUserOp(address(account), callData);
        op = _signSpendingUserOp(op, spendingSignerKey);

        vm.prank(ENTRY_POINT_V09);
        account.validateUserOp(op, _userOpHash(op), 0);

        vm.prank(ENTRY_POINT_V09);
        account.execute(address(usdc), 0, abi.encodeCall(usdc.transfer, (attacker, 100e6)));

        assertEq(usdc.balanceOf(attacker), 100e6);
    }

    function test_Account_InvalidUserOpExecute() public {
        vm.prank(ENTRY_POINT_V09);
        vm.expectRevert(abi.encodeWithSelector(MozaikAccount.UnauthorizedCaller.selector, ENTRY_POINT_V09));
        account.execute(address(usdc), 0, "");
    }

    function test_Account_UnauthorizedUserOp() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(MozaikAccount.UnauthorizedCaller.selector, attacker));
        account.execute(address(usdc), 0, "");
    }

    function test_Account_InvalidRecoveryUserOp() public {
        vm.prank(recoverySigner);
        vm.expectRevert(abi.encodeWithSelector(MozaikAccount.UnauthorizedCaller.selector, recoverySigner));
        account.execute(address(usdc), 0, "");
    }

    function test_Account_ExecuteFails() public {
        vm.prank(spendingSigner);
        vm.expectRevert();
        account.execute(address(usdc), 0, abi.encodeCall(usdc.transfer, (attacker, 1)));
    }

    function test_ValidateUserOp_ValidSpendingKey() public {
        PackedUserOperation memory op = _buildUserOp(address(account), "");
        op = _signSpendingUserOp(op, spendingSignerKey);

        vm.prank(ENTRY_POINT_V09);
        uint256 result = account.validateUserOp(op, _userOpHash(op), 0);

        assertEq(result, SIG_VALIDATION_SUCCESS);
    }

    function test_ValidateUserOp_ValidRecoveryKey() public {
        PackedUserOperation memory op = _buildUserOp(address(account), "");
        op = _signRecoveryUserOp(op, recoverySignerKey);

        vm.prank(ENTRY_POINT_V09);
        uint256 result = account.validateUserOp(op, _userOpHash(op), 0);

        assertEq(result, SIG_VALIDATION_SUCCESS);
    }

    function test_ValidateUserOp_InvalidKey() public {
        (, uint256 wrongKey) = makeAddrAndKey("wrong");
        PackedUserOperation memory op = _buildUserOp(address(account), "");
        op = _signSpendingUserOp(op, wrongKey);

        vm.prank(ENTRY_POINT_V09);
        uint256 result = account.validateUserOp(op, _userOpHash(op), 0);

        assertEq(result, SIG_VALIDATION_FAILED);
    }

    function test_ValidateUserOp_InvalidSigType() public {
        PackedUserOperation memory op = _buildUserOp(address(account), "");
        op.signature = abi.encodePacked(uint8(0xFF), bytes32(0), bytes32(0), uint8(27));

        vm.prank(ENTRY_POINT_V09);
        uint256 result = account.validateUserOp(op, _userOpHash(op), 0);

        assertEq(result, SIG_VALIDATION_FAILED);
    }

    function test_ValidateUserOp_InvalidSigLength() public {
        PackedUserOperation memory op = _buildUserOp(address(account), "");
        op.signature = abi.encodePacked(uint8(0x00), bytes32(0), bytes32(0)); // 65 bytes, not 66

        vm.prank(ENTRY_POINT_V09);
        uint256 result = account.validateUserOp(op, _userOpHash(op), 0);

        assertEq(result, SIG_VALIDATION_FAILED);
    }

    function test_ValidateUserOp_CallByNonEntryPoint() public {
        PackedUserOperation memory op = _buildUserOp(address(account), "");

        vm.prank(attacker);
        vm.expectRevert();
        account.validateUserOp(op, bytes32(0), 0);
    }

    function test_RotateSpendingSigner_ValidCall() public {
        address newSpendingSigner = makeAddr("newSpendingSigner");

        vm.prank(recoverySigner);
        account.rotateSpendingSigner(newSpendingSigner);

        assertEq(account.spendingSigner(), newSpendingSigner);
    }

    function test_RotateSpendingSigner_InvalidCallBySpending() public {
        vm.prank(spendingSigner);
        vm.expectRevert(abi.encodeWithSelector(MozaikAccount.UnauthorizedCaller.selector, spendingSigner));
        account.rotateSpendingSigner(makeAddr("new"));
    }

    function test_RotateSpendingSigner_InvalidCallByRandom() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(MozaikAccount.UnauthorizedCaller.selector, attacker));
        account.rotateSpendingSigner(attacker);
    }

    function test_RotateSpendingSigner_ValidRotation() public {
        address newSpendingSigner = makeAddr("newSpendingSigner");
        bytes memory callData = abi.encodeCall(account.rotateSpendingSigner, (newSpendingSigner));
        PackedUserOperation memory op = _buildUserOp(address(account), callData);
        op = _signRecoveryUserOp(op, recoverySignerKey);

        vm.prank(ENTRY_POINT_V09);
        account.validateUserOp(op, _userOpHash(op), 0);

        vm.prank(ENTRY_POINT_V09);
        account.rotateSpendingSigner(newSpendingSigner);

        assertEq(account.spendingSigner(), newSpendingSigner);
    }

    function test_RotateSpendingSigner_InvalidSpendingRotate() public {
        address newSpendingSigner = makeAddr("newSpendingSigner");
        bytes memory callData = abi.encodeCall(account.rotateSpendingSigner, (newSpendingSigner));
        PackedUserOperation memory op = _buildUserOp(address(account), callData);
        op = _signSpendingUserOp(op, spendingSignerKey);

        vm.prank(ENTRY_POINT_V09);
        account.validateUserOp(op, _userOpHash(op), 0);

        vm.prank(ENTRY_POINT_V09);
        vm.expectRevert(abi.encodeWithSelector(MozaikAccount.UnauthorizedCaller.selector, ENTRY_POINT_V09));
        account.rotateSpendingSigner(newSpendingSigner);
    }

    function test_RotateRecoverySigner_ValidCall() public {
        address newRecoverySigner = makeAddr("newRecoverySigner");

        vm.prank(recoverySigner);
        account.rotateRecoverySigner(newRecoverySigner);

        assertEq(account.recoverySigner(), newRecoverySigner);
    }

    function test_RotateRecoverySigner_InvalidCallBySpending() public {
        vm.prank(spendingSigner);
        vm.expectRevert(abi.encodeWithSelector(MozaikAccount.UnauthorizedCaller.selector, spendingSigner));
        account.rotateRecoverySigner(makeAddr("new"));
    }

    function test_StorageLayout_ERC7201() public view {
        bytes32 slot = keccak256(abi.encode(uint256(keccak256("mozaik.MozaikAccount")) - 1)) & ~bytes32(uint256(0xff));

        address storedSpending = address(uint160(uint256(vm.load(address(account), slot))));
        address storedRecovery = address(uint160(uint256(vm.load(address(account), bytes32(uint256(slot) + 1)))));

        assertEq(storedSpending, spendingSigner);
        assertEq(storedRecovery, recoverySigner);
    }
}
