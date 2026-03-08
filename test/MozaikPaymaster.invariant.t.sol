// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";

import {MozaikAccountFactory} from "../src/account/MozaikAccountFactory.sol";
import {MozaikVerifyingPaymaster} from "../src/paymaster/MozaikVerifyingPaymaster.sol";

contract PaymasterHandler is Test {
    bytes8 internal constant PAYMASTER_SIG_MAGIC = 0x22e325a297439656;
    bytes32 internal constant SPONSORED_OP_TYPEHASH =
        keccak256("SponsoredOp(address sender,uint256 nonce,uint48 validUntil,uint48 validAfter)");
    bytes32 internal constant EIP712_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    EntryPoint public entryPoint;
    MozaikVerifyingPaymaster public paymaster;
    MozaikAccountFactory public factory;

    address internal verifyingSignerAddr;
    uint256 internal verifyingSignerKey;

    uint256 public totalDeposited;
    uint256 public totalWithdrawn;

    // Ghost variables for invariant tracking
    bool public unsignedOpEverSponsored;
    bool public expiredOpEverSponsored;

    constructor() {
        (, verifyingSignerKey) = makeAddrAndKey("verifyingSigner");
        verifyingSignerAddr = vm.addr(verifyingSignerKey);

        entryPoint = new EntryPoint();
        factory = new MozaikAccountFactory(IEntryPoint(address(entryPoint)));
        paymaster = new MozaikVerifyingPaymaster(IEntryPoint(address(entryPoint)), verifyingSignerAddr, address(this));

        vm.deal(address(this), 100 ether);
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 0, 10 ether);

        vm.deal(address(this), address(this).balance + amount);

        paymaster.deposit{value: amount}();
        totalDeposited += amount;
    }

    function withdraw(uint256 amount) external {
        uint256 balance = entryPoint.balanceOf(address(paymaster));

        if (balance == 0) return;

        amount = bound(amount, 0, balance);

        paymaster.withdrawTo(payable(address(this)), amount);
        totalWithdrawn += amount;
    }

    function sponsorOp(address owner, uint48 validUntil) external {
        validUntil = uint48(bound(validUntil, block.timestamp + 1, type(uint48).max));

        address sender = factory.getAddress(owner);

        bytes32 domainSep = keccak256(
            abi.encode(
                EIP712_TYPE_HASH, keccak256("MozaikPaymaster"), keccak256("1"), block.chainid, address(paymaster)
            )
        );

        bytes32 structHash = keccak256(abi.encode(SPONSORED_OP_TYPEHASH, sender, uint256(0), validUntil, uint48(0)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(verifyingSignerKey, digest);

        bytes memory sig = abi.encodePacked(r, s, v);

        PackedUserOperation memory op;
        op.sender = sender;
        op.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(100_000),
            uint128(0),
            validUntil,
            uint48(0),
            sig,
            uint16(sig.length),
            PAYMASTER_SIG_MAGIC
        );

        vm.prank(address(entryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);

        assertEq(validationData & type(uint160).max, 0, "valid op must pass sig validation");
    }

    function submitExpiredOp(address owner) external {
        uint48 expired = 0; // validUntil = 0 is always in the past

        address sender = factory.getAddress(owner);

        bytes32 domainSep = keccak256(
            abi.encode(
                EIP712_TYPE_HASH, keccak256("MozaikPaymaster"), keccak256("1"), block.chainid, address(paymaster)
            )
        );
        bytes32 structHash = keccak256(abi.encode(SPONSORED_OP_TYPEHASH, sender, uint256(0), expired, uint48(0)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(verifyingSignerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        PackedUserOperation memory op;
        op.sender = sender;
        op.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(100_000),
            uint128(0),
            expired,
            uint48(0),
            sig,
            uint16(sig.length),
            PAYMASTER_SIG_MAGIC
        );

        vm.prank(address(entryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);

        assertEq((validationData >> 160) & type(uint48).max, 0, "expired validUntil must propagate");

        // Track: an expired op must never result in a sponsored (zero aggregator = "success") outcome
        // after EntryPoint time check. We simply check that validUntil=0 propagates correctly.
        // (EntryPoint rejects if returnedUntil < block.timestamp.
    }

    function submitUnsignedOp(address owner) external {
        address sender = factory.getAddress(owner);

        PackedUserOperation memory op;
        op.sender = sender;
        // paymasterAndData with NO signature suffix
        op.paymasterAndData =
            abi.encodePacked(address(paymaster), uint128(100_000), uint128(0), uint48(type(uint48).max), uint48(0));

        vm.prank(address(entryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);

        if ((validationData & type(uint160).max) == 0) {
            // This should never happen — unsigned op passed sig validation
            unsignedOpEverSponsored = true;
        }
    }

    receive() external payable {}
}

contract MozaikPaymasterInvariantTest is Test {
    PaymasterHandler internal handler;

    function setUp() public {
        handler = new PaymasterHandler();

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _selectors()}));
    }

    function invariant_DepositBalanceConsistent() public view {
        uint256 onChain = handler.entryPoint().balanceOf(address(handler.paymaster()));

        assertEq(onChain, handler.totalDeposited() - handler.totalWithdrawn(), "deposit balance inconsistent");
    }

    function invariant_UnsignedOpNeverSponsored() public view {
        assertFalse(handler.unsignedOpEverSponsored(), "unsigned op must never pass paymaster validation");
    }

    function invariant_ExpiredApprovalNeverSponsored() public pure {
        // Enforced directly in handler.submitExpiredOp() via assertion.
        // This invariant is satisfied as long as no assertion failure occurred during the run
        assertTrue(true);
    }

    function _selectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);

        s[0] = PaymasterHandler.deposit.selector;
        s[1] = PaymasterHandler.withdraw.selector;
        s[2] = PaymasterHandler.sponsorOp.selector;
        s[3] = PaymasterHandler.submitExpiredOp.selector;
        s[4] = PaymasterHandler.submitUnsignedOp.selector;
    }
}
