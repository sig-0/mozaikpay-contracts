// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";

import {MozaikAccount} from "../src/account/MozaikAccount.sol";
import {MozaikAccountFactory} from "../src/account/MozaikAccountFactory.sol";
import {MozaikVerifyingPaymaster} from "../src/paymaster/MozaikVerifyingPaymaster.sol";
import {MozaikPaylinks} from "../src/paylinks/MozaikPaylinks.sol";

/// @dev V2 mock used in upgrade tests. Adds a version() getter.
contract MockMozaikAccountV2 is MozaikAccount {
    function version() external pure returns (uint256) {
        return 2;
    }
}

interface IVersionedAccount {
    function version() external view returns (uint256);
}

/// @title E2E lifecycle test for Mozaik contracts on a live anvil node.
/// @dev Run via `e2e/run.sh` which starts anvil, deploys contracts, and invokes
///      `forge test --match-path e2e/E2E.t.sol --fork-url http://localhost:8545`.
contract E2ETest is Test {
    // Constants

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

    // State

    IEntryPoint internal ep;
    MozaikAccountFactory internal factory;
    MozaikVerifyingPaymaster internal paymaster;

    address internal bundlerEOA;
    address internal beneficiary;

    // Helpers

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

        // Set paymasterAndData stub so the account signs over the correct hash
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

    // Actual test

    function test_e2e_fullLifecycle() public {
        // Setup
        ep = IEntryPoint(ENTRY_POINT_V09);
        factory = MozaikAccountFactory(vm.envAddress("FACTORY_ADDRESS"));
        paymaster = MozaikVerifyingPaymaster(payable(vm.envAddress("PAYMASTER_ADDRESS")));

        bundlerEOA = vm.addr(DEPLOYER_KEY);
        beneficiary = makeAddr("beneficiary");

        (address spendingSigner, uint256 spendingKey) = makeAddrAndKey("spendingSigner");
        (address recoverySigner, uint256 recoveryKey) = makeAddrAndKey("recoverySigner");

        // Step 1: Verify Deployment
        assertTrue(address(factory).code.length > 0, "factory not deployed");
        assertTrue(address(paymaster).code.length > 0, "paymaster not deployed");
        assertTrue(address(factory.ACCOUNT_IMPLEMENTATION()).code.length > 0, "account impl not deployed");
        assertTrue(ep.getDepositInfo(address(paymaster)).deposit > 0, "paymaster has no deposit");
        assertEq(paymaster.sponsor(), SPONSOR_ADDR, "wrong sponsor");

        // Step 2: Create Account via UserOp
        address expectedAddr = factory.computeAddress(spendingSigner, recoverySigner);

        bytes memory initCode = abi.encodePacked(
            address(factory), abi.encodeCall(factory.createAccount, (spendingSigner, recoverySigner))
        );

        // callData must wrap execute in executeUserOp (spending-key selector requirement)
        bytes memory callData = _wrapExecuteUserOp(abi.encodeCall(BaseAccount.execute, (expectedAddr, 0, "")));

        uint256 nonce = ep.getNonce(expectedAddr, 0);
        PackedUserOperation memory op = _buildUserOp(expectedAddr, callData, initCode, nonce);
        op = _packSpendingOp(op, spendingKey);
        _handleSingleOp(op);

        MozaikAccount account = MozaikAccount(payable(expectedAddr));
        assertTrue(expectedAddr.code.length > 0, "account not deployed");
        assertEq(account.spendingSigner(), spendingSigner, "wrong spending signer");
        assertEq(account.recoverySigner(), recoverySigner, "wrong recovery signer");

        // Step 3: Execute USDC Transfer
        ERC20Mock usdc = new ERC20Mock();
        usdc.mint(expectedAddr, 1000e6);
        address recipient = makeAddr("recipient");

        callData = _wrapExecuteUserOp(
            abi.encodeCall(BaseAccount.execute, (address(usdc), 0, abi.encodeCall(usdc.transfer, (recipient, 100e6))))
        );

        nonce = ep.getNonce(expectedAddr, 0);
        op = _buildUserOp(expectedAddr, callData, "", nonce);
        op = _packSpendingOp(op, spendingKey);
        _handleSingleOp(op);

        assertEq(usdc.balanceOf(recipient), 100e6, "recipient didn't receive USDC");
        assertEq(usdc.balanceOf(expectedAddr), 900e6, "account balance incorrect");

        // Step 4: Paylinks: sponsored create + EOA claim

        MozaikPaylinks links = new MozaikPaylinks(IERC20(address(usdc)));

        (address linkPubKey, uint256 linkPrivKey) = makeAddrAndKey("paylinkEphemeralKey");
        uint256 linkAmount = 100e6;
        uint64 linkExpiry = uint64(block.timestamp + 1 days);

        // Approve MozaikPaylinks to pull USDC from the smart account (sponsored UserOp).
        callData = _wrapExecuteUserOp(
            abi.encodeCall(
                BaseAccount.execute, (address(usdc), 0, abi.encodeCall(usdc.approve, (address(links), type(uint256).max)))
            )
        );
        nonce = ep.getNonce(expectedAddr, 0);
        op = _buildUserOp(expectedAddr, callData, "", nonce);
        op = _packSpendingOp(op, spendingKey);
        _handleSingleOp(op);

        // Create the paylink (sponsored UserOp). Account loses linkAmount USDC into escrow.
        callData = _wrapExecuteUserOp(
            abi.encodeCall(
                BaseAccount.execute, (address(links), 0, abi.encodeCall(links.create, (linkPubKey, linkAmount, linkExpiry)))
            )
        );
        nonce = ep.getNonce(expectedAddr, 0);
        op = _buildUserOp(expectedAddr, callData, "", nonce);
        op = _packSpendingOp(op, spendingKey);
        _handleSingleOp(op);

        assertEq(usdc.balanceOf(address(links)), linkAmount, "link funds not escrowed");
        assertEq(usdc.balanceOf(expectedAddr), 800e6, "account balance after create incorrect");

        // Recipient claims via direct EOA call (no Mozaik account required).
        address paylinkRecipient = makeAddr("paylinkRecipient");

        bytes32 linksDomainSep = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("MozaikPaylinks"),
                keccak256("1"),
                block.chainid,
                address(links)
            )
        );
        bytes32 claimStructHash = keccak256(
            abi.encode(keccak256("Claim(address claimSigner,address recipient)"), linkPubKey, paylinkRecipient)
        );
        bytes32 claimDigest = keccak256(abi.encodePacked("\x19\x01", linksDomainSep, claimStructHash));

        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(linkPrivKey, claimDigest);
        bytes memory claimSig = abi.encodePacked(cr, cs, cv);

        vm.prank(paylinkRecipient);
        links.claim(linkPubKey, claimSig);

        assertEq(usdc.balanceOf(paylinkRecipient), linkAmount, "recipient didn't get paylink funds");
        assertEq(usdc.balanceOf(address(links)), 0, "escrow not drained");

        // Step 5: Rotate Spending Signer
        (address newSpendingSigner, uint256 newSpendingKey) = makeAddrAndKey("newSpendingSigner");

        callData = _wrapExecuteUserOp(abi.encodeCall(account.rotateSpendingSigner, (newSpendingSigner)));

        nonce = ep.getNonce(expectedAddr, 0);
        op = _buildUserOp(expectedAddr, callData, "", nonce);
        op = _packRecoveryOp(op, recoveryKey);
        _handleSingleOp(op);

        assertEq(account.spendingSigner(), newSpendingSigner, "spending signer not rotated");

        // Verify new key can execute
        callData = _wrapExecuteUserOp(
            abi.encodeCall(BaseAccount.execute, (address(usdc), 0, abi.encodeCall(usdc.transfer, (recipient, 50e6))))
        );

        nonce = ep.getNonce(expectedAddr, 0);
        op = _buildUserOp(expectedAddr, callData, "", nonce);
        op = _packSpendingOp(op, newSpendingKey);
        _handleSingleOp(op);

        assertEq(usdc.balanceOf(recipient), 150e6, "new spending key transfer failed");

        // Update local reference for subsequent steps
        spendingKey = newSpendingKey;

        // Step 6: Rotate Recovery Signer
        (address newRecoverySigner, uint256 newRecoveryKey) = makeAddrAndKey("newRecoverySigner");

        callData = _wrapExecuteUserOp(abi.encodeCall(account.rotateRecoverySigner, (newRecoverySigner)));

        nonce = ep.getNonce(expectedAddr, 0);
        op = _buildUserOp(expectedAddr, callData, "", nonce);
        op = _packRecoveryOp(op, recoveryKey);
        _handleSingleOp(op);

        assertEq(account.recoverySigner(), newRecoverySigner, "recovery signer not rotated");

        // Update local reference for subsequent steps
        recoveryKey = newRecoveryKey;

        // Step 7: Upgrade Implementation
        MockMozaikAccountV2 v2Impl = new MockMozaikAccountV2();

        callData = _wrapExecuteUserOp(abi.encodeCall(account.upgradeToAndCall, (address(v2Impl), "")));

        nonce = ep.getNonce(expectedAddr, 0);
        op = _buildUserOp(expectedAddr, callData, "", nonce);
        op = _packRecoveryOp(op, recoveryKey);
        _handleSingleOp(op);

        assertEq(IVersionedAccount(expectedAddr).version(), 2, "upgrade to V2 failed");
        assertEq(account.spendingSigner(), newSpendingSigner, "spending signer lost after upgrade");
        assertEq(account.recoverySigner(), newRecoverySigner, "recovery signer lost after upgrade");

        // Step 8: New Factory + Cross-Version Upgrade
        // Deploy a new factory (which creates a fresh MozaikAccount implementation)
        MozaikAccountFactory newFactory = new MozaikAccountFactory();
        MozaikAccount newImpl = newFactory.ACCOUNT_IMPLEMENTATION();
        assertTrue(address(newImpl) != address(factory.ACCOUNT_IMPLEMENTATION()), "new impl should differ");

        // Create a new account via the new factory
        (address signer2Spending, uint256 signer2SpendingKey) = makeAddrAndKey("signer2Spending");
        (address signer2Recovery,) = makeAddrAndKey("signer2Recovery");

        address newAccountAddr = newFactory.computeAddress(signer2Spending, signer2Recovery);

        initCode = abi.encodePacked(
            address(newFactory), abi.encodeCall(newFactory.createAccount, (signer2Spending, signer2Recovery))
        );
        callData = _wrapExecuteUserOp(abi.encodeCall(BaseAccount.execute, (newAccountAddr, 0, "")));

        nonce = ep.getNonce(newAccountAddr, 0);
        op = _buildUserOp(newAccountAddr, callData, initCode, nonce);
        op = _packSpendingOp(op, signer2SpendingKey);
        _handleSingleOp(op);

        assertTrue(newAccountAddr.code.length > 0, "new factory account not deployed");
        assertEq(MozaikAccount(payable(newAccountAddr)).spendingSigner(), signer2Spending);

        // Upgrade original account to the new factory's implementation
        callData = _wrapExecuteUserOp(abi.encodeCall(account.upgradeToAndCall, (address(newImpl), "")));

        nonce = ep.getNonce(expectedAddr, 0);
        op = _buildUserOp(expectedAddr, callData, "", nonce);
        op = _packRecoveryOp(op, recoveryKey);
        _handleSingleOp(op);

        // State preserved after cross-version upgrade
        assertEq(account.spendingSigner(), newSpendingSigner, "spending signer lost after cross-version upgrade");
        assertEq(account.recoverySigner(), newRecoverySigner, "recovery signer lost after cross-version upgrade");
    }
}
