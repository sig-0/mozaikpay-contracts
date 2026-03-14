// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

import {BaseTest} from "./BaseTest.t.sol";
import {MozaikAccount} from "../src/account/MozaikAccount.sol";

contract MockMozaikAccountV2 is MozaikAccount {
    function version() external pure returns (uint256) {
        return 2;
    }
}

interface IVersionedAccount {
    function version() external view returns (uint256);
}

contract RecoveryFlowTest is BaseTest {
    MozaikAccount internal account;

    function setUp() public override {
        super.setUp();

        account = _deployAccount();
    }

    function test_RotateSpendingSigner_DirectCall() public {
        (address newDeviceKey,) = makeAddrAndKey("newDeviceKey");

        vm.prank(recoverySigner);
        account.rotateSpendingSigner(newDeviceKey);

        usdc.mint(address(account), 100e6);

        vm.prank(newDeviceKey);
        account.execute(address(usdc), 0, abi.encodeCall(usdc.transfer, (attacker, 25e6)));

        assertEq(account.spendingSigner(), newDeviceKey);
        assertEq(usdc.balanceOf(attacker), 25e6);
    }

    function test_RotateSpendingSigner_RecoveryUserOp() public {
        (address newDeviceKey,) = makeAddrAndKey("newDeviceKey");

        bytes memory callData = abi.encodeCall(account.rotateSpendingSigner, (newDeviceKey));
        PackedUserOperation memory op = _buildUserOp(address(account), callData);

        op = _signRecoveryUserOp(op, recoverySignerKey);

        vm.prank(ENTRY_POINT_V09);
        account.validateUserOp(op, _userOpHash(op), 0);

        vm.prank(ENTRY_POINT_V09);
        account.rotateSpendingSigner(newDeviceKey);

        usdc.mint(address(account), 100e6);

        vm.prank(newDeviceKey);
        account.execute(address(usdc), 0, abi.encodeCall(usdc.transfer, (attacker, 25e6)));

        assertEq(account.spendingSigner(), newDeviceKey);
        assertEq(usdc.balanceOf(attacker), 25e6);
    }

    function test_RotateRecoveryKey_InvalidOldKey() public {
        (address nextRecoveryKey,) = makeAddrAndKey("nextRecoveryKey");

        vm.prank(recoverySigner);
        account.rotateRecoverySigner(nextRecoveryKey);

        // Old recovery key is rejected
        vm.prank(recoverySigner);
        vm.expectRevert(abi.encodeWithSelector(MozaikAccount.UnauthorizedCaller.selector, recoverySigner));
        account.rotateSpendingSigner(makeAddr("badDevice"));

        // New recovery key works
        address recoveredDeviceKey = makeAddr("recoveredDeviceKey");
        vm.prank(nextRecoveryKey);
        account.rotateSpendingSigner(recoveredDeviceKey);

        assertEq(account.recoverySigner(), nextRecoveryKey);
        assertEq(account.spendingSigner(), recoveredDeviceKey);
    }

    function test_UpgradeAccount_ValidCall() public {
        MockMozaikAccountV2 newImpl = new MockMozaikAccountV2();

        vm.prank(recoverySigner);
        account.upgradeToAndCall(address(newImpl), "");

        assertEq(IVersionedAccount(address(account)).version(), 2);
    }

    function test_UpgradeAccount_InvalidCall() public {
        MockMozaikAccountV2 newImpl = new MockMozaikAccountV2();

        vm.prank(spendingSigner);
        vm.expectRevert(abi.encodeWithSelector(MozaikAccount.UnauthorizedCaller.selector, spendingSigner));
        account.upgradeToAndCall(address(newImpl), "");
    }

    function test_RotateSpendingSigner_InvalidRotate() public {
        address newDeviceKey = makeAddr("newDeviceKey");
        bytes memory callData = abi.encodeCall(account.rotateSpendingSigner, (newDeviceKey));
        PackedUserOperation memory op = _buildUserOp(address(account), callData);
        op = _signSpendingUserOp(op, spendingSignerKey);

        vm.prank(ENTRY_POINT_V09);
        account.validateUserOp(op, _userOpHash(op), 0);

        // EntryPoint calls rotateSpendingSigner but tstore slot = 1 (spending) -> rejected
        vm.prank(ENTRY_POINT_V09);
        vm.expectRevert(abi.encodeWithSelector(MozaikAccount.UnauthorizedCaller.selector, ENTRY_POINT_V09));
        account.rotateSpendingSigner(newDeviceKey);
    }

    function test_Execute_RecoveryCannotExecute() public {
        usdc.mint(address(account), 100e6);
        bytes memory innerCall = abi.encodeCall(usdc.transfer, (attacker, 100e6));
        PackedUserOperation memory op =
            _buildUserOp(address(account), abi.encodeCall(account.execute, (address(usdc), 0, innerCall)));
        op = _signRecoveryUserOp(op, recoverySignerKey);

        vm.prank(ENTRY_POINT_V09);
        account.validateUserOp(op, _userOpHash(op), 0);

        // EntryPoint calls execute but tstore slot = 2 (recovery) -> rejected
        vm.prank(ENTRY_POINT_V09);
        vm.expectRevert(abi.encodeWithSelector(MozaikAccount.UnauthorizedCaller.selector, ENTRY_POINT_V09));
        account.execute(address(usdc), 0, innerCall);

        assertEq(usdc.balanceOf(attacker), 0);
    }
}
