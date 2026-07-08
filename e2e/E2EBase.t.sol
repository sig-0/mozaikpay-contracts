// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";

import {MozaikAccount} from "../src/account/MozaikAccount.sol";
import {MozaikAccountFactory} from "../src/account/MozaikAccountFactory.sol";
import {MozaikVerifyingPaymaster} from "../src/paymaster/MozaikVerifyingPaymaster.sol";

/// @title Shared harness for the Mozaik E2E lifecycle tests on a live anvil node.
/// @dev Reads the deployed factory/paymaster from the environment (populated by
///      `e2e/setup.sh`) and drives real EntryPoint `handleOps` with real ECDSA
///      signature validation. Concrete suites extend this and exercise one
///      lifecycle concern each. Run via `e2e/run.sh`.
abstract contract E2EBase is Test {
    address internal constant ENTRY_POINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;
    bytes8 internal constant PAYMASTER_SIG_MAGIC = 0x22e325a297439656;

    bytes32 internal constant PACKED_USEROP_TYPEHASH = keccak256(
        "PackedUserOperation(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData)"
    );

    // Anvil default account #0 (deployer / bundler EOA).
    uint256 internal constant DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // Anvil default account #2 (paymaster sponsor signer).
    uint256 internal constant SPONSOR_KEY = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    address internal constant SPONSOR_ADDR = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    /// @dev A deployed account bundled with both keypairs, so a test can drive
    ///      later spending and recovery ops without re-deriving keys.
    struct AccountFixture {
        MozaikAccount account;
        address addr;
        address spendingSigner;
        uint256 spendingKey;
        address recoverySigner;
        uint256 recoveryKey;
    }

    IEntryPoint internal ep;
    MozaikAccountFactory internal factory;
    MozaikVerifyingPaymaster internal paymaster;

    address internal bundlerEOA;
    address internal beneficiary;

    function setUp() public virtual {
        ep = IEntryPoint(ENTRY_POINT_V09);
        factory = MozaikAccountFactory(vm.envAddress("FACTORY_ADDRESS"));
        paymaster = MozaikVerifyingPaymaster(payable(vm.envAddress("PAYMASTER_ADDRESS")));

        bundlerEOA = vm.addr(DEPLOYER_KEY);
        beneficiary = makeAddr("beneficiary");
    }

    /// @dev Deploy an account through a sponsored UserOp using the given factory.
    ///      Derives distinct signers from `label` so a single test can create
    ///      more than one account without collision.
    function _createAccount(MozaikAccountFactory f, string memory label) internal returns (AccountFixture memory a) {
        (a.spendingSigner, a.spendingKey) = makeAddrAndKey(string.concat(label, ":spending"));
        (a.recoverySigner, a.recoveryKey) = makeAddrAndKey(string.concat(label, ":recovery"));
        a.addr = f.computeAddress(a.spendingSigner, a.recoverySigner);

        bytes memory initCode =
            abi.encodePacked(address(f), abi.encodeCall(f.createAccount, (a.spendingSigner, a.recoverySigner)));

        // callData must wrap execute in executeUserOp (spending-key selector requirement).
        // A no-op self-call is enough to deploy via initCode.
        bytes memory callData = _wrapExecuteUserOp(abi.encodeCall(BaseAccount.execute, (a.addr, 0, "")));

        PackedUserOperation memory op = _buildUserOp(a.addr, callData, initCode, ep.getNonce(a.addr, 0));
        op = _packSpendingOp(op, a.spendingKey);
        _handleSingleOp(op);

        a.account = MozaikAccount(payable(a.addr));
    }

    /// @dev Deploy an account via the canonical deployed factory.
    function _createAccount(string memory label) internal returns (AccountFixture memory) {
        return _createAccount(factory, label);
    }

    /// @dev Send a sponsored spending-signed op wrapping `inner` account callData.
    function _sendSpendingOp(address addr, uint256 spendingKey, bytes memory inner) internal {
        PackedUserOperation memory op = _buildUserOp(addr, _wrapExecuteUserOp(inner), "", ep.getNonce(addr, 0));
        op = _packSpendingOp(op, spendingKey);
        _handleSingleOp(op);
    }

    /// @dev Send a sponsored recovery-signed op wrapping `inner` account callData.
    function _sendRecoveryOp(address addr, uint256 recoveryKey, bytes memory inner) internal {
        PackedUserOperation memory op = _buildUserOp(addr, _wrapExecuteUserOp(inner), "", ep.getNonce(addr, 0));
        op = _packRecoveryOp(op, recoveryKey);
        _handleSingleOp(op);
    }

    /// @dev Wrap inner account callData in the executeUserOp selector (the form the account requires).
    function _wrapExecuteUserOp(bytes memory inner) internal pure returns (bytes memory) {
        return bytes.concat(MozaikAccount.executeUserOp.selector, inner);
    }

    function _buildUserOp(address sender, bytes memory callData, bytes memory initCode, uint256 nonce)
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

    function _signSpendingUserOp(PackedUserOperation memory op, uint256 signerKey)
        internal
        view
        returns (PackedUserOperation memory)
    {
        bytes32 hash = _userOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, hash);
        op.signature = abi.encodePacked(uint8(0x00), r, s, v);
        return op;
    }

    function _signRecoveryUserOp(PackedUserOperation memory op, uint256 signerKey)
        internal
        view
        returns (PackedUserOperation memory)
    {
        bytes32 hash = _userOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, hash);
        op.signature = abi.encodePacked(uint8(0x01), r, s, v);
        return op;
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

    /// @dev Packs a UserOp with spending-key signature + paymaster approval.
    function _packSpendingOp(PackedUserOperation memory op, uint256 spendingKey)
        internal
        view
        returns (PackedUserOperation memory)
    {
        uint48 validUntil = uint48(block.timestamp + 1 hours);

        // Set paymasterAndData stub so the account signs over the correct hash.
        op.paymasterAndData = abi.encodePacked(
            address(paymaster), uint128(100_000), uint128(0), validUntil, uint48(0), PAYMASTER_SIG_MAGIC
        );

        op = _signSpendingUserOp(op, spendingKey);
        op.paymasterAndData = _signPaymasterApproval(op, validUntil, 0, SPONSOR_KEY, address(paymaster));

        return op;
    }

    /// @dev Packs a UserOp with recovery-key signature + paymaster approval.
    function _packRecoveryOp(PackedUserOperation memory op, uint256 recoveryKey)
        internal
        view
        returns (PackedUserOperation memory)
    {
        uint48 validUntil = uint48(block.timestamp + 1 hours);

        op.paymasterAndData = abi.encodePacked(
            address(paymaster), uint128(100_000), uint128(0), validUntil, uint48(0), PAYMASTER_SIG_MAGIC
        );

        op = _signRecoveryUserOp(op, recoveryKey);
        op.paymasterAndData = _signPaymasterApproval(op, validUntil, 0, SPONSOR_KEY, address(paymaster));

        return op;
    }

    /// @dev Calls handleOps via vm.prank(bundlerEOA, bundlerEOA) to satisfy the
    ///      EntryPoint's tx.origin == msg.sender EOA-only check.
    function _handleOps(PackedUserOperation[] memory ops) internal {
        vm.prank(bundlerEOA, bundlerEOA);
        ep.handleOps(ops, payable(beneficiary));
    }

    function _handleSingleOp(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        _handleOps(ops);
    }
}
