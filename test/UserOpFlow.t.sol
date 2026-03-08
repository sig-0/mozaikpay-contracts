// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

import {BaseTest} from "./BaseTest.t.sol";
import {MozaikAccount} from "../src/account/MozaikAccount.sol";
import {MozaikAccountFactory} from "../src/account/MozaikAccountFactory.sol";
import {MozaikVerifyingPaymaster} from "../src/paymaster/MozaikVerifyingPaymaster.sol";

contract UserOpFlowTest is BaseTest {
    IEntryPoint internal forkEp;
    MozaikAccountFactory internal forkFactory;
    MozaikVerifyingPaymaster internal forkPaymaster;

    address internal beneficiary;

    // Fork-based tests are skipped when BASE_SEPOLIA_RPC is not configured
    modifier onlyFork() {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC", string(""));

        if (bytes(rpc).length == 0) return;

        vm.createSelectFork(rpc);
        _;
    }

    function _setupFork() internal {
        forkEp = IEntryPoint(ENTRY_POINT_V09);

        forkPaymaster = new MozaikVerifyingPaymaster(forkEp, verifyingSignerAddr, address(this));
        forkFactory = new MozaikAccountFactory(forkEp);

        // Fund paymaster deposit
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

    function _packForkOp(PackedUserOperation memory op, uint48 validUntil, uint48 validAfter)
        internal
        view
        returns (PackedUserOperation memory)
    {
        // Build paymasterAndData without signature
        bytes memory pmData =
            abi.encodePacked(address(forkPaymaster), uint128(100_000), uint128(0), validUntil, validAfter);
        op.paymasterAndData = pmData;

        // Sign userOp (paymasterAndData without sig suffix -> stable hash)
        op = _signUserOp(op, ownerKey);

        // Get and append paymaster signature
        op.paymasterAndData =
            _signPaymasterApproval(op, validUntil, validAfter, verifyingSignerKey, address(forkPaymaster));
        return op;
    }

    function test_FirstUserOp_DeploysAccountAndTransfersUSDC() public onlyFork {
        _setupFork();

        address expectedAddr = forkFactory.getAddress(owner);

        // Here we use ERC20Mock for self-contained test
        usdc.mint(expectedAddr, 1000e6);

        // Build initCode: factory address + createAccount calldata
        bytes memory initCode =
            abi.encodePacked(address(forkFactory), abi.encodeCall(forkFactory.createAccount, (owner)));

        bytes memory callData = abi.encodeCall(
            MozaikAccount.execute, (address(usdc), 0, abi.encodeCall(usdc.transfer, (beneficiary, 100e6)))
        );

        uint256 nonce = forkEp.getNonce(expectedAddr, 0);
        PackedUserOperation memory op = _buildForkOp(expectedAddr, callData, initCode, nonce);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        op = _packForkOp(op, validUntil, 0);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        uint256 depositBefore = forkEp.balanceOf(address(forkPaymaster));
        forkEp.handleOps(ops, payable(beneficiary));

        assertTrue(expectedAddr.code.length > 0, "account not deployed");
        assertEq(usdc.balanceOf(beneficiary), 100e6);
        assertTrue(forkEp.balanceOf(address(forkPaymaster)) < depositBefore, "deposit not reduced");
    }

    function test_SubsequentUserOp_UsesExistingAccount() public onlyFork {
        _setupFork();

        // Deploy account first
        address senderCreator = address(forkEp.senderCreator());
        vm.prank(senderCreator);
        MozaikAccount acct = forkFactory.createAccount(owner);
        vm.deal(address(acct), 1 ether);

        usdc.mint(address(acct), 500e6);

        bytes memory callData = abi.encodeCall(
            MozaikAccount.execute, (address(usdc), 0, abi.encodeCall(usdc.transfer, (beneficiary, 50e6)))
        );

        uint256 nonce = forkEp.getNonce(address(acct), 0);
        PackedUserOperation memory op = _buildForkOp(address(acct), callData, "", nonce);
        op = _packForkOp(op, uint48(block.timestamp + 1 hours), 0);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        forkEp.handleOps(ops, payable(beneficiary));

        assertEq(usdc.balanceOf(beneficiary), 50e6);
        assertEq(forkEp.getNonce(address(acct), 0), nonce + 1);
    }

    function test_CounterfactualUSDCDeposit_BalancePreservedAfterDeployment() public onlyFork {
        _setupFork();

        address expectedAddr = forkFactory.getAddress(owner);

        // Send USDC to counterfactual address before deployment
        usdc.mint(expectedAddr, 777e6);
        assertEq(usdc.balanceOf(expectedAddr), 777e6);

        // Deploy account
        address senderCreator = address(forkEp.senderCreator());
        vm.prank(senderCreator);
        forkFactory.createAccount(owner);

        // Balance is preserved
        assertEq(usdc.balanceOf(expectedAddr), 777e6);
        assertTrue(expectedAddr.code.length > 0);
    }

    function test_InvalidSignature_UserOpRejectedByEntryPoint() public onlyFork {
        _setupFork();

        address expectedAddr = forkFactory.getAddress(owner);
        vm.deal(expectedAddr, 1 ether);

        PackedUserOperation memory op = _buildForkOp(expectedAddr, "", "", 0);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        op.paymasterAndData = _signPaymasterApproval(op, validUntil, 0, verifyingSignerKey, address(forkPaymaster));
        // Bad user signature
        op.signature = hex"deadbeef";

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        vm.expectRevert();
        forkEp.handleOps(ops, payable(beneficiary));
    }

    function test_ExpiredPaymasterApproval_UserOpRejected() public onlyFork {
        _setupFork();

        address expectedAddr = forkFactory.getAddress(owner);
        uint256 nonce = forkEp.getNonce(expectedAddr, 0);
        PackedUserOperation memory op = _buildForkOp(expectedAddr, "", "", nonce);

        uint48 expired = uint48(block.timestamp - 1);
        op = _packForkOp(op, expired, 0);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        vm.expectRevert();
        forkEp.handleOps(ops, payable(beneficiary));
    }

    function test_PaymasterDepositPartiallyDrained_SubsequentOpsStillWork() public onlyFork {
        _setupFork();

        address senderCreator = address(forkEp.senderCreator());
        vm.prank(senderCreator);
        MozaikAccount acct = forkFactory.createAccount(owner);
        vm.deal(address(acct), 1 ether);
        usdc.mint(address(acct), 1000e6);

        // Run two sequential UserOps
        for (uint256 i = 0; i < 2; i++) {
            bytes memory callData = abi.encodeCall(
                MozaikAccount.execute, (address(usdc), 0, abi.encodeCall(usdc.transfer, (beneficiary, 10e6)))
            );

            uint256 nonce = forkEp.getNonce(address(acct), 0);
            PackedUserOperation memory op = _buildForkOp(address(acct), callData, "", nonce);
            op = _packForkOp(op, uint48(block.timestamp + 1 hours), 0);

            PackedUserOperation[] memory ops = new PackedUserOperation[](1);
            ops[0] = op;

            forkEp.handleOps(ops, payable(beneficiary));
        }

        assertEq(usdc.balanceOf(beneficiary), 20e6);
    }
}
