// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
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

    bytes32 internal constant SPONSORED_OP_TYPEHASH =
        keccak256("SponsoredOp(address sender,uint256 nonce,uint48 validUntil,uint48 validAfter)");

    bytes32 internal constant EIP712_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    ERC20Mock internal usdc;
    EntryPoint internal localEntryPoint;
    MozaikAccount internal accountImpl;
    MozaikAccountFactory internal factory;
    MozaikVerifyingPaymaster internal paymaster;

    address internal owner;
    uint256 internal ownerKey;
    address internal verifyingSignerAddr;
    uint256 internal verifyingSignerKey;
    address internal attacker;

    function setUp() public virtual {
        (owner, ownerKey) = makeAddrAndKey("owner");

        (verifyingSignerAddr, verifyingSignerKey) = makeAddrAndKey("verifyingSigner");

        attacker = makeAddr("attacker");

        usdc = new ERC20Mock();

        // Deploy a real local EntryPoint so factory gets a valid senderCreator
        localEntryPoint = new EntryPoint();

        factory = new MozaikAccountFactory(IEntryPoint(address(localEntryPoint)));

        paymaster =
            new MozaikVerifyingPaymaster(IEntryPoint(address(localEntryPoint)), verifyingSignerAddr, address(this));

        accountImpl = factory.ACCOUNT_IMPLEMENTATION();

        vm.deal(owner, 10 ether);
        vm.deal(attacker, 1 ether);
    }

    function _deployAccount(address _owner) internal returns (MozaikAccount acct) {
        address senderCreator = address(localEntryPoint.senderCreator());

        vm.prank(senderCreator);
        acct = factory.createAccount(_owner);
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

    function _signUserOp(PackedUserOperation memory op, uint256 signerKey)
        internal
        view
        returns (PackedUserOperation memory)
    {
        bytes32 userOpHash = _userOpHash(op);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, userOpHash);

        op.signature = abi.encodePacked(r, s, v);

        return op;
    }

    // Compute the EntryPoint v0.9 userOpHash for a given op.
    // Assumes paymasterAndData does NOT contain the paymaster signature suffix yet
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
            abi.encode(EIP712_TYPE_HASH, keccak256("ERC4337"), keccak256("1"), block.chainid, ENTRY_POINT_V09)
        );

        return keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
    }

    // Build paymasterAndData (without signature), sign it, and return the complete
    // paymasterAndData with signature appended as suffix
    function _signPaymasterApproval(
        PackedUserOperation memory op,
        uint48 validUntil,
        uint48 validAfter,
        uint256 signerKey,
        address paymasterAddr
    ) internal view returns (bytes memory) {
        bytes32 domainSep = keccak256(
            abi.encode(EIP712_TYPE_HASH, keccak256("MozaikPaymaster"), keccak256("1"), block.chainid, paymasterAddr)
        );

        bytes32 structHash = keccak256(abi.encode(SPONSORED_OP_TYPEHASH, op.sender, op.nonce, validUntil, validAfter));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        bytes memory sig = abi.encodePacked(r, s, v);

        // Suffix: sig || uint16(sig.length) || magic
        return abi.encodePacked(
            paymasterAddr, // 20 bytes
            uint128(100_000), // validationGasLimit (16 bytes)
            uint128(0), // postOpGasLimit     (16 bytes)
            validUntil, // 6 bytes
            validAfter, // 6 bytes
            sig,
            uint16(sig.length),
            PAYMASTER_SIG_MAGIC
        );
    }
}
