// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

import {MozaikAccount} from "../src/account/MozaikAccount.sol";
import {MozaikAccountFactory} from "../src/account/MozaikAccountFactory.sol";
import {MozaikVerifyingPaymaster} from "../src/paymaster/MozaikVerifyingPaymaster.sol";

abstract contract BaseTest is Test {
    address internal constant ENTRY_POINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;
    bytes8 internal constant PAYMASTER_SIG_MAGIC = 0x22e325a297439656;

    bytes32 internal constant PACKED_USEROP_TYPEHASH = keccak256(
        "PackedUserOperation(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData)"
    );

    ERC20Mock internal usdc;
    EntryPoint internal localEntryPoint;
    MozaikAccount internal accountImpl;
    MozaikAccountFactory internal factory;
    MozaikVerifyingPaymaster internal paymaster;

    // spending signer (secp256k1 device key)
    address internal spendingSigner;
    uint256 internal spendingSignerKey;

    address internal recoverySigner;
    uint256 internal recoverySignerKey;

    address internal owner;
    uint256 internal ownerKey;

    address internal verifyingSignerAddr;
    uint256 internal verifyingSignerKey;
    address internal attacker;

    function setUp() public virtual {
        (spendingSigner, spendingSignerKey) = makeAddrAndKey("spendingSigner");
        (recoverySigner, recoverySignerKey) = makeAddrAndKey("recoverySigner");

        (owner, ownerKey) = (spendingSigner, spendingSignerKey);
        (verifyingSignerAddr, verifyingSignerKey) = makeAddrAndKey("verifyingSigner");
        attacker = makeAddr("attacker");

        usdc = new ERC20Mock();
        deployCodeTo("EntryPoint.sol:EntryPoint", ENTRY_POINT_V09);
        localEntryPoint = EntryPoint(payable(ENTRY_POINT_V09));
        factory = new MozaikAccountFactory();
        paymaster = new MozaikVerifyingPaymaster(verifyingSignerAddr);
        accountImpl = factory.ACCOUNT_IMPLEMENTATION();

        vm.deal(owner, 10 ether);
        vm.deal(attacker, 1 ether);
    }

    function _deployAccount(address _spendingSigner, address _recoverySigner) internal returns (MozaikAccount acct) {
        address senderCreator = address(localEntryPoint.senderCreator());

        vm.prank(senderCreator);
        acct = factory.createAccount(_spendingSigner, _recoverySigner);
    }

    function _deployAccount() internal returns (MozaikAccount acct) {
        return _deployAccount(spendingSigner, recoverySigner);
    }

    function _buildUserOp(address sender, bytes memory callData) internal pure returns (PackedUserOperation memory op) {
        op.sender = sender;
        op.nonce = 0;
        op.initCode = "";
        op.callData = callData;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(200_000), uint128(200_000)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(2 gwei)));
        op.paymasterAndData = "";
        op.signature = "";
    }

    /// @notice Sign a UserOp with the spending key (0x00 prefix + 65-byte ECDSA).
    function _signSpendingUserOp(PackedUserOperation memory op, uint256 signerKey)
        internal
        view
        returns (PackedUserOperation memory)
    {
        bytes32 userOpHash = _userOpHash(op);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, userOpHash);
        op.signature = abi.encodePacked(uint8(0x00), r, s, v);

        return op;
    }

    /// @notice Sign a UserOp with the recovery key (0x01 prefix + 65-byte ECDSA).
    function _signRecoveryUserOp(PackedUserOperation memory op, uint256 signerKey)
        internal
        view
        returns (PackedUserOperation memory)
    {
        bytes32 userOpHash = _userOpHash(op);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, userOpHash);
        op.signature = abi.encodePacked(uint8(0x01), r, s, v);

        return op;
    }

    /// @notice Wrap inner account callData in the executeUserOp selector (the form the account requires).
    function _wrapExecuteUserOp(bytes memory inner) internal pure returns (bytes memory) {
        return bytes.concat(MozaikAccount.executeUserOp.selector, inner);
    }

    /// @notice Run a UserOp through executeUserOp as the EntryPoint does after validation.
    function _execUserOp(MozaikAccount acct, PackedUserOperation memory op) internal {
        vm.prank(ENTRY_POINT_V09);
        acct.executeUserOp(op, _userOpHash(op));
    }

    function _userOpHash(PackedUserOperation memory op) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                PACKED_USEROP_TYPEHASH,
                op.sender,
                op.nonce,
                keccak256(op.initCode),
                keccak256(op.callData),
                op.accountGasLimits,
                op.preVerificationGas,
                op.gasFees,
                keccak256(op.paymasterAndData)
            )
        );

        bytes32 domainSep = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("ERC4337"),
                keccak256("1"),
                block.chainid,
                ENTRY_POINT_V09
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
    }

    function _recoverSigner(bytes32 digest, bytes memory sig) internal pure returns (address) {
        if (sig.length != 65) return address(0);

        return ECDSA.recover(digest, sig);
    }

    function _signPaymasterApproval(
        PackedUserOperation memory op,
        uint48 validUntil,
        uint48 validAfter,
        uint256 signerKey,
        address paymasterAddr
    ) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encode(
                paymasterAddr,
                block.chainid,
                op.sender,
                op.nonce,
                keccak256(op.initCode),
                keccak256(op.callData),
                op.accountGasLimits,
                op.preVerificationGas,
                op.gasFees,
                validUntil,
                validAfter
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        return abi.encodePacked(
            paymasterAddr,
            uint128(100_000),
            uint128(0),
            validUntil,
            validAfter,
            sig,
            uint16(sig.length),
            PAYMASTER_SIG_MAGIC
        );
    }
}
