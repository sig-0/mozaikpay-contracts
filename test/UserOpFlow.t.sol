// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {BaseTest} from "./BaseTest.t.sol";
import {MozaikAccount} from "../src/account/MozaikAccount.sol";
import {MozaikAccountFactory} from "../src/account/MozaikAccountFactory.sol";
import {MozaikVerifyingPaymaster} from "../src/paymaster/MozaikVerifyingPaymaster.sol";

contract MockMozaikAccountV2 is MozaikAccount {
    function version() external pure returns (uint256) {
        return 2;
    }
}

interface IVersionedAccount {
    function version() external view returns (uint256);
}

contract UserOpFlowTest is BaseTest {
    IEntryPoint internal forkEp;
    MozaikAccountFactory internal forkFactory;
    MozaikVerifyingPaymaster internal forkPaymaster;

    address internal beneficiary;

    modifier onlyFork() {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC", string(""));

        if (bytes(rpc).length == 0) return;

        vm.createSelectFork(rpc);
        _;
    }

    function _setupFork() internal {
        usdc = new ERC20Mock();

        forkEp = IEntryPoint(ENTRY_POINT_V09);
        forkPaymaster = new MozaikVerifyingPaymaster(forkEp, verifyingSignerAddr);
        forkFactory = new MozaikAccountFactory(forkEp);

        forkPaymaster.deposit{value: 1 ether}();

        beneficiary = makeAddr("beneficiary");
        vm.deal(beneficiary, 0);
    }

    function _buildForkOp(address sender, bytes memory callData, bytes memory initCode, uint256 nonce)
        internal
        pure
        returns (PackedUserOperation memory op)
    {
        op.sender = sender;
        op.nonce = nonce;
        op.initCode = initCode;
        op.callData = callData;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(500_000), uint128(500_000)));
        op.preVerificationGas = 100_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(2 gwei)));
        op.paymasterAndData = "";
        op.signature = "";
    }

    // handleOps requires tx.origin == msg.sender and msg.sender.code.length == 0 (EOA only).
    // vm.prank(eoa, eoa) sets both msg.sender and tx.origin to satisfy both conditions.
    function _handleOps(PackedUserOperation[] memory ops) internal {
        address eoa = makeAddr("bundler");

        vm.prank(eoa, eoa);
        forkEp.handleOps(ops, payable(beneficiary));
    }

    function _packForkRecoveryOp(PackedUserOperation memory op, uint48 validUntil, uint48 validAfter)
        internal
        view
        returns (PackedUserOperation memory)
    {
        op.paymasterAndData = abi.encodePacked(
            address(forkPaymaster), uint128(100_000), uint128(0), validUntil, validAfter, PAYMASTER_SIG_MAGIC
        );

        op = _signRecoveryUserOp(op, recoverySignerKey);

        op.paymasterAndData =
            _signPaymasterApproval(op, validUntil, validAfter, verifyingSignerKey, address(forkPaymaster));

        return op;
    }

    function _packForkOp(PackedUserOperation memory op, uint48 validUntil, uint48 validAfter)
        internal
        view
        returns (PackedUserOperation memory)
    {
        // Include PAYMASTER_SIG_MAGIC so the account signs the same paymasterAndData
        // that paymasterDataKeccak produces (it strips the sig but keeps the magic suffix)
        op.paymasterAndData = abi.encodePacked(
            address(forkPaymaster), uint128(100_000), uint128(0), validUntil, validAfter, PAYMASTER_SIG_MAGIC
        );

        op = _signSpendingUserOp(op, ownerKey);

        op.paymasterAndData =
            _signPaymasterApproval(op, validUntil, validAfter, verifyingSignerKey, address(forkPaymaster));

        return op;
    }

    function test_HandleOps_DeploysAccountAndExecutes() public onlyFork {
        _setupFork();

        address expectedAddr = forkFactory.computeAddress(spendingSigner, recoverySigner);
        usdc.mint(expectedAddr, 1000e6);

        bytes memory initCode = abi.encodePacked(
            address(forkFactory), abi.encodeCall(forkFactory.createAccount, (spendingSigner, recoverySigner))
        );

        bytes memory callData = abi.encodeCall(
            BaseAccount.execute, (address(usdc), 0, abi.encodeCall(usdc.transfer, (beneficiary, 100e6)))
        );

        uint256 nonce = forkEp.getNonce(expectedAddr, 0);
        PackedUserOperation memory op = _buildForkOp(expectedAddr, callData, initCode, nonce);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        op = _packForkOp(op, validUntil, 0);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        uint256 depositBefore = forkEp.balanceOf(address(forkPaymaster));
        _handleOps(ops);

        assertTrue(expectedAddr.code.length > 0, "account not deployed");
        assertEq(usdc.balanceOf(beneficiary), 100e6);
        assertTrue(forkEp.balanceOf(address(forkPaymaster)) < depositBefore, "deposit not reduced");
    }

    function test_HandleOps_ExistingAccountExecutes() public onlyFork {
        _setupFork();

        address senderCreator = address(forkEp.senderCreator());
        vm.prank(senderCreator);

        MozaikAccount acct = forkFactory.createAccount(spendingSigner, recoverySigner);
        vm.deal(address(acct), 1 ether);
        usdc.mint(address(acct), 500e6);

        bytes memory callData =
            abi.encodeCall(BaseAccount.execute, (address(usdc), 0, abi.encodeCall(usdc.transfer, (beneficiary, 50e6))));

        uint256 nonce = forkEp.getNonce(address(acct), 0);
        PackedUserOperation memory op = _buildForkOp(address(acct), callData, "", nonce);
        op = _packForkOp(op, uint48(block.timestamp + 1 hours), 0);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        _handleOps(ops);

        assertEq(usdc.balanceOf(beneficiary), 50e6);
        assertEq(forkEp.getNonce(address(acct), 0), nonce + 1);
    }

    function test_CounterfactualAddress_BalancePreservedOnDeploy() public onlyFork {
        _setupFork();

        address expectedAddr = forkFactory.computeAddress(spendingSigner, recoverySigner);
        usdc.mint(expectedAddr, 777e6);
        assertEq(usdc.balanceOf(expectedAddr), 777e6);

        address senderCreator = address(forkEp.senderCreator());
        vm.prank(senderCreator);
        forkFactory.createAccount(spendingSigner, recoverySigner);

        assertEq(usdc.balanceOf(expectedAddr), 777e6);
        assertTrue(expectedAddr.code.length > 0);
    }

    function test_HandleOps_InvalidSignatureRejected() public onlyFork {
        _setupFork();

        address expectedAddr = forkFactory.computeAddress(spendingSigner, recoverySigner);
        vm.deal(expectedAddr, 1 ether);

        PackedUserOperation memory op = _buildForkOp(expectedAddr, "", "", 0);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        op.paymasterAndData = _signPaymasterApproval(op, validUntil, 0, verifyingSignerKey, address(forkPaymaster));
        op.signature = hex"deadbeef";

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        address eoa = makeAddr("bundler");

        vm.prank(eoa, eoa);
        vm.expectRevert();
        forkEp.handleOps(ops, payable(beneficiary));
    }

    function test_HandleOps_ExpiredApprovalRejected() public onlyFork {
        _setupFork();

        address expectedAddr = forkFactory.computeAddress(spendingSigner, recoverySigner);
        uint256 nonce = forkEp.getNonce(expectedAddr, 0);
        PackedUserOperation memory op = _buildForkOp(expectedAddr, "", "", nonce);

        uint48 expired = uint48(block.timestamp - 1);
        op = _packForkOp(op, expired, 0);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        address eoa = makeAddr("bundler");

        vm.prank(eoa, eoa);
        vm.expectRevert();
        forkEp.handleOps(ops, payable(beneficiary));
    }

    function test_HandleOps_PartialDepositStillExecutes() public onlyFork {
        _setupFork();

        address senderCreator = address(forkEp.senderCreator());
        vm.prank(senderCreator);
        MozaikAccount acct = forkFactory.createAccount(spendingSigner, recoverySigner);
        vm.deal(address(acct), 1 ether);
        usdc.mint(address(acct), 1000e6);

        for (uint256 i = 0; i < 2; i++) {
            bytes memory callData = abi.encodeCall(
                BaseAccount.execute, (address(usdc), 0, abi.encodeCall(usdc.transfer, (beneficiary, 10e6)))
            );

            uint256 nonce = forkEp.getNonce(address(acct), 0);
            PackedUserOperation memory op = _buildForkOp(address(acct), callData, "", nonce);
            op = _packForkOp(op, uint48(block.timestamp + 1 hours), 0);

            PackedUserOperation[] memory ops = new PackedUserOperation[](1);
            ops[0] = op;

            _handleOps(ops);
        }

        assertEq(usdc.balanceOf(beneficiary), 20e6);
    }

    function test_HandleOps_RotateSpendingSignerViaRecoveryUserOp() public onlyFork {
        _setupFork();

        address senderCreator = address(forkEp.senderCreator());
        vm.prank(senderCreator);
        MozaikAccount acct = forkFactory.createAccount(spendingSigner, recoverySigner);

        (address newSpendingKey,) = makeAddrAndKey("newSpendingKey");
        bytes memory callData = abi.encodeCall(acct.rotateSpendingSigner, (newSpendingKey));

        uint256 nonce = forkEp.getNonce(address(acct), 0);
        PackedUserOperation memory op = _buildForkOp(address(acct), callData, "", nonce);
        op = _packForkRecoveryOp(op, uint48(block.timestamp + 1 hours), 0);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        _handleOps(ops);

        assertEq(acct.spendingSigner(), newSpendingKey);
    }

    function test_RotateSpendingSigner_DirectCall() public onlyFork {
        _setupFork();

        address senderCreator = address(forkEp.senderCreator());
        vm.prank(senderCreator);
        MozaikAccount acct = forkFactory.createAccount(spendingSigner, recoverySigner);

        (address newSpendingKey,) = makeAddrAndKey("newSpendingKey");

        vm.prank(recoverySigner);
        acct.rotateSpendingSigner(newSpendingKey);

        assertEq(acct.spendingSigner(), newSpendingKey);
    }

    function test_HandleOps_UpgradeViaRecoveryUserOp() public onlyFork {
        _setupFork();

        address senderCreator = address(forkEp.senderCreator());
        vm.prank(senderCreator);
        MozaikAccount acct = forkFactory.createAccount(spendingSigner, recoverySigner);

        MockMozaikAccountV2 newImpl = new MockMozaikAccountV2();
        bytes memory callData = abi.encodeCall(acct.upgradeToAndCall, (address(newImpl), ""));

        uint256 nonce = forkEp.getNonce(address(acct), 0);
        PackedUserOperation memory op = _buildForkOp(address(acct), callData, "", nonce);
        op = _packForkRecoveryOp(op, uint48(block.timestamp + 1 hours), 0);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        _handleOps(ops);

        assertEq(IVersionedAccount(address(acct)).version(), 2);
    }
}
