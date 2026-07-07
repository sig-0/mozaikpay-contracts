// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {SIG_VALIDATION_SUCCESS, SIG_VALIDATION_FAILED} from "account-abstraction/core/Helpers.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";

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

        bytes memory callData = _wrapExecuteUserOp(
            abi.encodeCall(account.execute, (address(usdc), 0, abi.encodeCall(usdc.transfer, (attacker, 100e6))))
        );

        PackedUserOperation memory op = _buildUserOp(address(account), callData);
        op = _signSpendingUserOp(op, spendingSignerKey);

        vm.prank(ENTRY_POINT_V09);
        assertEq(account.validateUserOp(op, _userOpHash(op), 0), SIG_VALIDATION_SUCCESS);

        _execUserOp(account, op);

        assertEq(usdc.balanceOf(attacker), 100e6);
    }

    function test_Account_EntryPointCanCallExecute() public {
        usdc.mint(address(account), 1000e6);

        // The execute() guard still trusts the EntryPoint for compatibility. Validated UserOps now
        // run through executeUserOp; this exercises the retained direct path.
        vm.prank(ENTRY_POINT_V09);
        account.execute(address(usdc), 0, abi.encodeCall(usdc.transfer, (attacker, 100e6)));

        assertEq(usdc.balanceOf(attacker), 100e6);
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
        bytes memory callData = _wrapExecuteUserOp(abi.encodeCall(account.execute, (address(usdc), 0, "")));
        PackedUserOperation memory op = _buildUserOp(address(account), callData);
        op = _signSpendingUserOp(op, spendingSignerKey);

        vm.prank(ENTRY_POINT_V09);
        uint256 result = account.validateUserOp(op, _userOpHash(op), 0);

        assertEq(result, SIG_VALIDATION_SUCCESS);
    }

    function test_ValidateUserOp_ValidRecoveryKey() public {
        bytes memory callData = _wrapExecuteUserOp(abi.encodeCall(account.rotateSpendingSigner, (makeAddr("newKey"))));
        PackedUserOperation memory op = _buildUserOp(address(account), callData);
        op = _signRecoveryUserOp(op, recoverySignerKey);

        vm.prank(ENTRY_POINT_V09);
        uint256 result = account.validateUserOp(op, _userOpHash(op), 0);

        assertEq(result, SIG_VALIDATION_SUCCESS);
    }

    function test_ValidateUserOp_InvalidKey() public {
        (, uint256 wrongKey) = makeAddrAndKey("wrong");
        bytes memory callData = _wrapExecuteUserOp(abi.encodeCall(account.execute, (address(usdc), 0, "")));
        PackedUserOperation memory op = _buildUserOp(address(account), callData);
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
        bytes memory callData = _wrapExecuteUserOp(abi.encodeCall(account.rotateSpendingSigner, (newSpendingSigner)));
        PackedUserOperation memory op = _buildUserOp(address(account), callData);
        op = _signRecoveryUserOp(op, recoverySignerKey);

        vm.prank(ENTRY_POINT_V09);
        account.validateUserOp(op, _userOpHash(op), 0);

        _execUserOp(account, op);

        assertEq(account.spendingSigner(), newSpendingSigner);
    }

    function test_ValidateUserOp_SpendingKeyCannotSignRotate() public {
        address newSpendingSigner = makeAddr("newSpendingSigner");
        bytes memory callData = _wrapExecuteUserOp(abi.encodeCall(account.rotateSpendingSigner, (newSpendingSigner)));
        PackedUserOperation memory op = _buildUserOp(address(account), callData);
        op = _signSpendingUserOp(op, spendingSignerKey);

        vm.prank(ENTRY_POINT_V09);
        uint256 result = account.validateUserOp(op, _userOpHash(op), 0);

        // Spending key targeting a rotation function is rejected at the validation stage itself
        assertEq(result, SIG_VALIDATION_FAILED);
    }

    function test_ValidateUserOp_RecoveryKeyCannotSignExecute() public {
        bytes memory callData = _wrapExecuteUserOp(abi.encodeCall(account.execute, (address(usdc), 0, "")));
        PackedUserOperation memory op = _buildUserOp(address(account), callData);
        op = _signRecoveryUserOp(op, recoverySignerKey);

        vm.prank(ENTRY_POINT_V09);
        uint256 result = account.validateUserOp(op, _userOpHash(op), 0);

        // Recovery key targeting execute is rejected at the validation stage itself
        assertEq(result, SIG_VALIDATION_FAILED);
    }

    function test_ValidateUserOp_SpendingKeyExecuteBatch() public {
        PackedUserOperation memory op = _buildUserOp(
            address(account), _wrapExecuteUserOp(abi.encodeCall(account.executeBatch, (new BaseAccount.Call[](0))))
        );
        op = _signSpendingUserOp(op, spendingSignerKey);

        vm.prank(ENTRY_POINT_V09);
        uint256 result = account.validateUserOp(op, _userOpHash(op), 0);

        assertEq(result, SIG_VALIDATION_SUCCESS);
    }

    function test_ValidateUserOp_RecoveryKeyRotateRecovery() public {
        bytes memory callData =
            _wrapExecuteUserOp(abi.encodeCall(account.rotateRecoverySigner, (makeAddr("newRecovery"))));
        PackedUserOperation memory op = _buildUserOp(address(account), callData);
        op = _signRecoveryUserOp(op, recoverySignerKey);

        vm.prank(ENTRY_POINT_V09);
        uint256 result = account.validateUserOp(op, _userOpHash(op), 0);

        assertEq(result, SIG_VALIDATION_SUCCESS);
    }

    function test_ValidateUserOp_RecoveryKeyUpgrade() public {
        bytes memory callData = _wrapExecuteUserOp(abi.encodeCall(account.upgradeToAndCall, (address(0), "")));
        PackedUserOperation memory op = _buildUserOp(address(account), callData);
        op = _signRecoveryUserOp(op, recoverySignerKey);

        vm.prank(ENTRY_POINT_V09);
        uint256 result = account.validateUserOp(op, _userOpHash(op), 0);

        assertEq(result, SIG_VALIDATION_SUCCESS);
    }

    function test_ValidateUserOp_EmptyCallDataRejected() public {
        PackedUserOperation memory op = _buildUserOp(address(account), "");
        op = _signSpendingUserOp(op, spendingSignerKey);

        vm.prank(ENTRY_POINT_V09);
        uint256 result = account.validateUserOp(op, _userOpHash(op), 0);

        assertEq(result, SIG_VALIDATION_FAILED);
    }

    function test_ValidateUserOp_UnwrappedCallDataRejected() public {
        // A correctly-signed spending op whose top-level selector is execute (not executeUserOp) is
        // rejected: every UserOp must be wrapped so execution routes through executeUserOp.
        bytes memory callData = abi.encodeCall(account.execute, (address(usdc), 0, ""));
        PackedUserOperation memory op = _buildUserOp(address(account), callData);
        op = _signSpendingUserOp(op, spendingSignerKey);

        vm.prank(ENTRY_POINT_V09);
        uint256 result = account.validateUserOp(op, _userOpHash(op), 0);

        assertEq(result, SIG_VALIDATION_FAILED);
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

    function test_RotateSpendingSigner_RejectsRecoveryAddress() public {
        vm.prank(recoverySigner);
        vm.expectRevert(MozaikAccount.DuplicateSigners.selector);
        account.rotateSpendingSigner(recoverySigner);
    }

    function test_RotateRecoverySigner_RejectsSpendingAddress() public {
        vm.prank(recoverySigner);
        vm.expectRevert(MozaikAccount.DuplicateSigners.selector);
        account.rotateRecoverySigner(spendingSigner);
    }

    function test_RotateSpendingSigner_RejectsUnchanged() public {
        vm.prank(recoverySigner);
        vm.expectRevert(MozaikAccount.SignerUnchanged.selector);
        account.rotateSpendingSigner(spendingSigner);
    }

    function test_RotateRecoverySigner_RejectsUnchanged() public {
        vm.prank(recoverySigner);
        vm.expectRevert(MozaikAccount.SignerUnchanged.selector);
        account.rotateRecoverySigner(recoverySigner);
    }

    function test_StorageLayout_ERC7201() public view {
        bytes32 slot = keccak256(abi.encode(uint256(keccak256("mozaik.MozaikAccount")) - 1)) & ~bytes32(uint256(0xff));

        address storedSpending = address(uint160(uint256(vm.load(address(account), slot))));
        address storedRecovery = address(uint160(uint256(vm.load(address(account), bytes32(uint256(slot) + 1)))));

        assertEq(storedSpending, spendingSigner);
        assertEq(storedRecovery, recoverySigner);
    }

    function test_Initialize_RejectsZeroSigner() public {
        // The factory pre-checks its inputs, so initialize's own guard is reached only by
        // constructing a fresh proxy directly with bad init data.
        vm.expectRevert(MozaikAccount.ZeroAddress.selector);
        new ERC1967Proxy(address(accountImpl), abi.encodeCall(MozaikAccount.initialize, (address(0), recoverySigner)));
    }

    function test_Initialize_RejectsDuplicateSigners() public {
        vm.expectRevert(MozaikAccount.DuplicateSigners.selector);
        new ERC1967Proxy(
            address(accountImpl), abi.encodeCall(MozaikAccount.initialize, (spendingSigner, spendingSigner))
        );
    }

    function test_RotateSpendingSigner_RejectsZeroAddress() public {
        vm.prank(recoverySigner);
        vm.expectRevert(MozaikAccount.ZeroAddress.selector);
        account.rotateSpendingSigner(address(0));
    }

    function test_RotateRecoverySigner_RejectsZeroAddress() public {
        vm.prank(recoverySigner);
        vm.expectRevert(MozaikAccount.ZeroAddress.selector);
        account.rotateRecoverySigner(address(0));
    }

    function test_ValidateUserOp_RecoveryKeyInvalidSignature() public {
        (, uint256 wrongKey) = makeAddrAndKey("wrongRecovery");
        bytes memory callData = _wrapExecuteUserOp(abi.encodeCall(account.rotateSpendingSigner, (makeAddr("newKey"))));
        PackedUserOperation memory op = _buildUserOp(address(account), callData);
        op = _signRecoveryUserOp(op, wrongKey);

        vm.prank(ENTRY_POINT_V09);
        uint256 result = account.validateUserOp(op, _userOpHash(op), 0);

        // A recovery-type op with a valid rotation selector but a signature that does not recover
        // the recovery signer is rejected during validation.
        assertEq(result, SIG_VALIDATION_FAILED);
    }

    function test_ExecuteUserOp_InnerCallRevertBubbles() public {
        // The account holds no USDC, so the inner transfer reverts inside the spending path and bubbles up.
        bytes memory callData = _wrapExecuteUserOp(
            abi.encodeCall(account.execute, (address(usdc), 0, abi.encodeCall(usdc.transfer, (attacker, 1))))
        );
        PackedUserOperation memory op = _buildUserOp(address(account), callData);
        op = _signSpendingUserOp(op, spendingSignerKey);

        vm.prank(ENTRY_POINT_V09);
        vm.expectRevert();
        account.executeUserOp(op, _userOpHash(op));
    }

    function test_ExecuteUserOp_RecoveryKeyUnsupportedSelectorReverts() public {
        // A recovery-signed op whose inner selector is not a rotation or upgrade reaches executeUserOp
        // only via a direct call (validation would otherwise reject it); it must revert.
        bytes memory callData = _wrapExecuteUserOp(abi.encodeCall(account.execute, (address(usdc), 0, "")));
        PackedUserOperation memory op = _buildUserOp(address(account), callData);
        op = _signRecoveryUserOp(op, recoverySignerKey);

        vm.prank(ENTRY_POINT_V09);
        vm.expectRevert(MozaikAccount.UnsupportedExecution.selector);
        account.executeUserOp(op, _userOpHash(op));
    }

    function test_ExecuteUserOp_UnknownSigTypeReverts() public {
        // A signature type that is neither spending (0x00) nor recovery (0x01) hits the fallthrough revert.
        bytes memory callData = _wrapExecuteUserOp(abi.encodeCall(account.execute, (address(usdc), 0, "")));
        PackedUserOperation memory op = _buildUserOp(address(account), callData);
        op.signature = abi.encodePacked(uint8(0x02), bytes32(0), bytes32(0), uint8(27));

        vm.prank(ENTRY_POINT_V09);
        vm.expectRevert(MozaikAccount.UnsupportedExecution.selector);
        account.executeUserOp(op, _userOpHash(op));
    }
}
