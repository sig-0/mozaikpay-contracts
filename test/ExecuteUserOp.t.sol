// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SIG_VALIDATION_FAILED} from "account-abstraction/core/Helpers.sol";

import {BaseTest} from "./BaseTest.t.sol";
import {MozaikAccount} from "../src/account/MozaikAccount.sol";

contract VersionedMozaikAccount is MozaikAccount {
    function version() external pure returns (uint256) {
        return 2;
    }
}

interface IVersionedAccount {
    function version() external view returns (uint256);
}

contract ExecuteUserOpTest is BaseTest {
    MozaikAccount internal account;

    function setUp() public override {
        super.setUp();

        account = _deployAccount();
        vm.deal(address(account), 10 ether);
        usdc.mint(address(account), 1000e6);
    }

    /// @notice Submit a bundle through the real EntryPoint as an EOA bundler would.
    function _handleOps(PackedUserOperation memory op1, PackedUserOperation memory op2) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](2);
        ops[0] = op1;
        ops[1] = op2;

        address bundler = makeAddr("bundler");
        vm.prank(bundler, bundler);
        localEntryPoint.handleOps(ops, payable(bundler));
    }

    function _spendingOp(uint256 nonce, bytes memory inner, uint256 key)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op = _buildUserOp(address(account), _wrapExecuteUserOp(inner));
        op.nonce = nonce;
        op = _signSpendingUserOp(op, key);
    }

    function _recoveryOp(uint256 nonce, bytes memory inner, uint256 key)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op = _buildUserOp(address(account), _wrapExecuteUserOp(inner));
        op.nonce = nonce;
        op = _signRecoveryUserOp(op, key);
    }

    function test_Bundle_OldSpendingKeyCannotSpendAfterRotation() public {
        (address newDeviceKey,) = makeAddrAndKey("newDeviceKey");

        // op1: recovery rotates the spending signer; op2: the OLD spending key tries to spend.
        PackedUserOperation memory op1 =
            _recoveryOp(0, abi.encodeCall(account.rotateSpendingSigner, (newDeviceKey)), recoverySignerKey);
        PackedUserOperation memory op2 = _spendingOp(
            1,
            abi.encodeCall(account.execute, (address(usdc), 0, abi.encodeCall(usdc.transfer, (attacker, 500e6)))),
            spendingSignerKey
        );

        _handleOps(op1, op2);

        assertEq(account.spendingSigner(), newDeviceKey);
        // op2 reverted with StaleAuthority during execution, so no USDC moved.
        assertEq(usdc.balanceOf(attacker), 0);
    }

    function test_Bundle_OldRecoveryKeyCannotRotateAfterRotation() public {
        (address newRecoveryKey,) = makeAddrAndKey("newRecoveryKey");

        // op1: recovery rotates itself; op2: the OLD recovery key tries to rotate the spending key.
        PackedUserOperation memory op1 =
            _recoveryOp(0, abi.encodeCall(account.rotateRecoverySigner, (newRecoveryKey)), recoverySignerKey);
        PackedUserOperation memory op2 = _recoveryOp(
            1, abi.encodeCall(account.rotateSpendingSigner, (makeAddr("attackerDevice"))), recoverySignerKey
        );

        _handleOps(op1, op2);

        assertEq(account.recoverySigner(), newRecoveryKey);
        // op2 reverted with StaleAuthority, so the spending signer is unchanged.
        assertEq(account.spendingSigner(), spendingSigner);
    }

    function test_Bundle_StaleRecoveryUpgradeRejected() public {
        (address newRecoveryKey,) = makeAddrAndKey("newRecoveryKey");
        VersionedMozaikAccount newImpl = new VersionedMozaikAccount();

        // op1: recovery rotates itself; op2: the OLD recovery key tries to upgrade.
        PackedUserOperation memory op1 =
            _recoveryOp(0, abi.encodeCall(account.rotateRecoverySigner, (newRecoveryKey)), recoverySignerKey);
        PackedUserOperation memory op2 =
            _recoveryOp(1, abi.encodeCall(account.upgradeToAndCall, (address(newImpl), "")), recoverySignerKey);

        _handleOps(op1, op2);

        assertEq(account.recoverySigner(), newRecoveryKey);
        // op2 reverted with StaleAuthority, so the implementation was not upgraded.
        vm.expectRevert();
        IVersionedAccount(address(account)).version();
    }

    function test_ExecuteUserOp_OnlyEntryPoint() public {
        PackedUserOperation memory op =
            _spendingOp(0, abi.encodeCall(account.execute, (address(usdc), 0, "")), spendingSignerKey);

        vm.prank(attacker);
        vm.expectRevert();
        account.executeUserOp(op, _userOpHash(op));
    }

    function test_ExecuteUserOp_StaleSpendingReverts() public {
        (address newDeviceKey,) = makeAddrAndKey("newDeviceKey");

        // Build and sign with the current spending key, then rotate it away before execution.
        PackedUserOperation memory op = _spendingOp(
            0,
            abi.encodeCall(account.execute, (address(usdc), 0, abi.encodeCall(usdc.transfer, (attacker, 100e6)))),
            spendingSignerKey
        );

        vm.prank(recoverySigner);
        account.rotateSpendingSigner(newDeviceKey);

        vm.prank(ENTRY_POINT_V09);
        vm.expectRevert(MozaikAccount.StaleAuthority.selector);
        account.executeUserOp(op, _userOpHash(op));
    }

    function test_ExecuteUserOp_StaleRecoveryReverts() public {
        (address newRecoveryKey,) = makeAddrAndKey("newRecoveryKey");

        PackedUserOperation memory op =
            _recoveryOp(0, abi.encodeCall(account.rotateSpendingSigner, (makeAddr("x"))), recoverySignerKey);

        vm.prank(recoverySigner);
        account.rotateRecoverySigner(newRecoveryKey);

        vm.prank(ENTRY_POINT_V09);
        vm.expectRevert(MozaikAccount.StaleAuthority.selector);
        account.executeUserOp(op, _userOpHash(op));
    }

    function test_ExecuteUserOp_UnrecoverableSigSkipsFreshness() public {
        // Mirrors the bundler's gas-estimation path: a dummy (unrecoverable) signature must not trip
        // the freshness check, so the bundler can simulate execution to estimate gas.
        bytes memory inner =
            abi.encodeCall(account.execute, (address(usdc), 0, abi.encodeCall(usdc.transfer, (attacker, 100e6))));
        PackedUserOperation memory op = _buildUserOp(address(account), _wrapExecuteUserOp(inner));
        op.signature = abi.encodePacked(uint8(0x00), new bytes(65));

        vm.prank(ENTRY_POINT_V09);
        account.executeUserOp(op, _userOpHash(op));

        assertEq(usdc.balanceOf(attacker), 100e6);
    }

    function test_ValidationRejectsUnrecoverableSig() public {
        // executeUserOp skips the freshness check exactly when ECDSA recovery fails. That branch must
        // stay unreachable in a real bundle: validation must reject the same signature class so
        // handleOps aborts before execution. If the two layers ever diverge, this test fails.
        bytes memory ecdsaSig = new bytes(65); // a dummy signature used for gas estimation: 65 zero bytes

        bytes memory inner = abi.encodeCall(account.execute, (address(usdc), 0, ""));
        PackedUserOperation memory op = _buildUserOp(address(account), _wrapExecuteUserOp(inner));
        op.signature = abi.encodePacked(uint8(0x00), ecdsaSig);
        bytes32 hash = _userOpHash(op);

        // The estimation dummy is genuinely unrecoverable; this is what confines the skip to estimation.
        (, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, ecdsaSig);
        assertTrue(err != ECDSA.RecoverError.NoError, "estimation dummy must be unrecoverable");

        // Validation rejects exactly that class.
        vm.prank(ENTRY_POINT_V09);
        assertEq(account.validateUserOp(op, hash, 0), SIG_VALIDATION_FAILED);
    }

    function test_ExecuteUserOp_RejectsMismatchedInnerSelector() public {
        // A fresh spending signature, but the inner selector is a recovery-only action. executeUserOp
        // must reject it on its own, independent of validation.
        PackedUserOperation memory op =
            _spendingOp(0, abi.encodeCall(account.rotateSpendingSigner, (makeAddr("x"))), spendingSignerKey);

        vm.prank(ENTRY_POINT_V09);
        vm.expectRevert(MozaikAccount.UnsupportedExecution.selector);
        account.executeUserOp(op, _userOpHash(op));
    }

    function test_ExecuteUserOp_RotateRejectsDuplicateSigner() public {
        // The DuplicateSigners invariant must hold on the executeUserOp path: rotating the spending
        // signer to the current recovery signer is rejected.
        PackedUserOperation memory op =
            _recoveryOp(0, abi.encodeCall(account.rotateSpendingSigner, (recoverySigner)), recoverySignerKey);

        vm.prank(ENTRY_POINT_V09);
        vm.expectRevert(MozaikAccount.DuplicateSigners.selector);
        account.executeUserOp(op, _userOpHash(op));
    }

    function test_ExecuteUserOp_RotateRejectsUnchangedSigner() public {
        // The SignerUnchanged invariant must hold on the executeUserOp path: rotating the spending
        // signer to its current value is rejected.
        PackedUserOperation memory op =
            _recoveryOp(0, abi.encodeCall(account.rotateSpendingSigner, (spendingSigner)), recoverySignerKey);

        vm.prank(ENTRY_POINT_V09);
        vm.expectRevert(MozaikAccount.SignerUnchanged.selector);
        account.executeUserOp(op, _userOpHash(op));
    }

    function test_ExecuteUserOp_ExecuteBatch() public {
        BaseAccount.Call[] memory calls = new BaseAccount.Call[](1);
        calls[0] =
            BaseAccount.Call({target: address(usdc), value: 0, data: abi.encodeCall(usdc.transfer, (attacker, 250e6))});

        PackedUserOperation memory op = _spendingOp(0, abi.encodeCall(account.executeBatch, (calls)), spendingSignerKey);
        _execUserOp(account, op);

        assertEq(usdc.balanceOf(attacker), 250e6);
    }

    function test_ExecuteUserOp_BatchRevertsWithIndexOnFailure() public {
        // Multi-call batch: a failing call reverts the whole op, wrapped with its index (ExecuteError).
        BaseAccount.Call[] memory calls = new BaseAccount.Call[](2);
        calls[0] =
            BaseAccount.Call({target: address(usdc), value: 0, data: abi.encodeCall(usdc.transfer, (attacker, 100e6))});
        calls[1] = BaseAccount.Call({
            target: address(usdc), value: 0, data: abi.encodeCall(usdc.transfer, (attacker, 5_000e6))
        });

        PackedUserOperation memory op = _spendingOp(0, abi.encodeCall(account.executeBatch, (calls)), spendingSignerKey);

        vm.prank(ENTRY_POINT_V09);
        vm.expectPartialRevert(BaseAccount.ExecuteError.selector);
        account.executeUserOp(op, _userOpHash(op));

        // The whole op reverted, so the first (successful) transfer was rolled back too.
        assertEq(usdc.balanceOf(attacker), 0);
    }

    function test_ExecuteUserOp_SingleCallBatchBubblesRawRevert() public {
        // A single-call batch bubbles the underlying revert unwrapped (not ExecuteError), like execute.
        BaseAccount.Call[] memory calls = new BaseAccount.Call[](1);
        calls[0] = BaseAccount.Call({
            target: address(usdc), value: 0, data: abi.encodeCall(usdc.transfer, (attacker, 5_000e6))
        });

        PackedUserOperation memory op = _spendingOp(0, abi.encodeCall(account.executeBatch, (calls)), spendingSignerKey);

        vm.prank(ENTRY_POINT_V09);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        account.executeUserOp(op, _userOpHash(op));
    }

    function test_ExecuteUserOp_Upgrade() public {
        VersionedMozaikAccount newImpl = new VersionedMozaikAccount();

        PackedUserOperation memory op =
            _recoveryOp(0, abi.encodeCall(account.upgradeToAndCall, (address(newImpl), "")), recoverySignerKey);
        _execUserOp(account, op);

        assertEq(IVersionedAccount(address(account)).version(), 2);
    }
}
