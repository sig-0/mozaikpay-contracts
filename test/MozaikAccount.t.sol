// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {SIG_VALIDATION_SUCCESS, SIG_VALIDATION_FAILED} from "account-abstraction/core/Helpers.sol";

import {BaseTest} from "./BaseTest.t.sol";
import {MozaikAccount} from "../src/account/MozaikAccount.sol";

contract MozaikAccountTest is BaseTest {
    MozaikAccount internal account;

    function setUp() public override {
        super.setUp();

        account = _deployAccount(owner);

        vm.deal(address(account), 1 ether);
    }

    function test_Initialize_SetsOwnerAsSigner() public view {
        assertTrue(account.signers(owner));
    }

    function test_RevertWhen_InitializeCalledTwice() public {
        vm.expectRevert();

        account.initialize(attacker);
    }

    function test_Execute_TransfersUSDCWhenCalledByOwner() public {
        usdc.mint(address(account), 1000e6);
        bytes memory data = abi.encodeCall(usdc.transfer, (attacker, 500e6));

        vm.prank(owner);
        account.execute(address(usdc), 0, data);

        assertEq(usdc.balanceOf(attacker), 500e6);
    }

    function test_Execute_SucceedsWhenCalledByEntryPoint() public {
        usdc.mint(address(account), 1000e6);
        bytes memory data = abi.encodeCall(usdc.transfer, (attacker, 100e6));

        vm.prank(ENTRY_POINT_V09);
        account.execute(address(usdc), 0, data);

        assertEq(usdc.balanceOf(attacker), 100e6);
    }

    function test_RevertWhen_ExecuteCalledByStranger() public {
        bytes memory data = abi.encodeCall(usdc.transfer, (attacker, 1));

        vm.expectRevert();
        vm.prank(attacker);

        account.execute(address(usdc), 0, data);
    }

    function test_Execute_RevertsOnFailedCall() public {
        // Transfer more USDC than balance -> ERC20 reverts
        bytes memory data = abi.encodeCall(usdc.transfer, (attacker, 1e18));

        vm.prank(owner);
        vm.expectRevert();
        account.execute(address(usdc), 0, data);
    }

    function testFuzz_Execute_OnlyOwnerOrEntryPointCanCall(address caller) public {
        vm.assume(caller != owner && caller != ENTRY_POINT_V09);

        bytes memory data = "";

        vm.prank(caller);
        vm.expectRevert();
        account.execute(address(0), 0, data);
    }

    function test_ExecuteBatch_ExecutesAllCallsAtomically() public {
        usdc.mint(address(account), 1000e6);

        address[] memory dest = new address[](2);
        uint256[] memory value = new uint256[](2);
        bytes[] memory data = new bytes[](2);

        dest[0] = address(usdc);
        value[0] = 0;

        data[0] = abi.encodeCall(usdc.transfer, (attacker, 200e6));
        dest[1] = address(usdc);

        value[1] = 0;
        data[1] = abi.encodeCall(usdc.transfer, (attacker, 300e6));

        vm.prank(owner);
        account.executeBatch(dest, value, data);

        assertEq(usdc.balanceOf(attacker), 500e6);
    }

    function test_RevertWhen_ExecuteBatchCalledByStranger() public {
        address[] memory dest = new address[](1);
        uint256[] memory value = new uint256[](1);
        bytes[] memory data = new bytes[](1);

        dest[0] = address(usdc);

        vm.prank(attacker);
        vm.expectRevert();
        account.executeBatch(dest, value, data);
    }

    function test_RevertWhen_ExecuteBatchArrayLengthsMismatch() public {
        address[] memory dest = new address[](2);
        uint256[] memory value = new uint256[](1); // mismatch
        bytes[] memory data = new bytes[](2);

        vm.prank(owner);
        vm.expectRevert(MozaikAccount.ArrayLengthMismatch.selector);
        account.executeBatch(dest, value, data);
    }

    function test_ValidateUserOp_SuccessForOwnerSignature() public {
        PackedUserOperation memory op = _buildUserOp(address(account), "");
        op = _signUserOp(op, ownerKey);

        vm.prank(ENTRY_POINT_V09);
        uint256 result = account.validateUserOp(op, _userOpHash(op), 0);

        assertEq(result, SIG_VALIDATION_SUCCESS);
    }

    function test_ValidateUserOp_FailedForWrongKey() public {
        (, uint256 wrongKey) = makeAddrAndKey("wrong");

        PackedUserOperation memory op = _buildUserOp(address(account), "");
        op = _signUserOp(op, wrongKey);

        vm.prank(ENTRY_POINT_V09);
        uint256 result = account.validateUserOp(op, _userOpHash(op), 0);

        assertEq(result, SIG_VALIDATION_FAILED);
    }

    function test_RevertWhen_ValidateUserOpCalledByNonEntryPoint() public {
        PackedUserOperation memory op = _buildUserOp(address(account), "");

        vm.prank(attacker);
        vm.expectRevert();
        account.validateUserOp(op, bytes32(0), 0);
    }

    function testFuzz_ValidateUserOp_RejectsArbitrarySignature(bytes memory sig) public {
        PackedUserOperation memory op = _buildUserOp(address(account), "");
        op.signature = sig;

        // validateUserOp must never revert (uses tryRecover internally).
        vm.prank(ENTRY_POINT_V09);
        uint256 result = account.validateUserOp(op, _userOpHash(op), 0);

        assertNotEq(result, SIG_VALIDATION_SUCCESS);
    }

    function test_IsValidSignature_ReturnsMagicValueForOwnerSig() public view {
        bytes32 hash = keccak256("hello");
        bytes32 digest = _erc1271Digest(address(account), hash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes4 result = account.isValidSignature(hash, sig);

        assertEq(result, IERC1271.isValidSignature.selector);
    }

    function test_IsValidSignature_ReturnsFallbackForNonOwnerSig() public {
        bytes32 hash = keccak256("hello");
        bytes32 digest = _erc1271Digest(address(account), hash);
        (, uint256 wrongKey) = makeAddrAndKey("nonowner");

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes4 result = account.isValidSignature(hash, sig);
        assertEq(result, bytes4(0xffffffff));
    }

    /**
     * Compute the EIP-712 digest that isValidSignature expects callers to sign.
     * Mirrors the contract's wrapping: \x19\x01 || domainSeparator(account) || MozaikMessage(hash).
     */
    function _erc1271Digest(address accountAddr, bytes32 hash) private view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("MozaikAccount"),
                keccak256("1"),
                block.chainid,
                accountAddr
            )
        );

        bytes32 structHash = keccak256(abi.encode(keccak256("MozaikMessage(bytes32 hash)"), hash));

        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function test_UpgradeToAndCall_SucceedsForOwner() public {
        MozaikAccount newImpl = new MozaikAccount();

        vm.prank(owner);
        account.upgradeToAndCall(address(newImpl), "");

        // Verify ERC1967 implementation slot updated
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address stored = address(uint160(uint256(vm.load(address(account), slot))));

        assertEq(stored, address(newImpl));
    }

    function test_RevertWhen_UpgradeCalledByStranger() public {
        MozaikAccount newImpl = new MozaikAccount();

        vm.prank(attacker);
        vm.expectRevert();
        account.upgradeToAndCall(address(newImpl), "");
    }

    function test_Receive_AcceptsETH() public {
        uint256 balanceBefore = address(account).balance;
        (bool ok,) = address(account).call{value: 0.1 ether}("");

        assertTrue(ok);
        assertEq(address(account).balance, balanceBefore + 0.1 ether);
    }
}
