// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MozaikLinks} from "../src/paylinks/MozaikLinks.sol";

/// @dev Token that takes a 1% fee on transfer, used to verify fee-on-transfer tokens are rejected.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);

            return;
        }

        uint256 fee = value / 100; // 1%
        super._update(from, address(0xdead), fee);
        super._update(from, to, value - fee);
    }
}

contract MozaikLinksTest is Test {
    MozaikLinks internal links;
    ERC20Mock internal usdc;

    event LinkCreated(bytes32 indexed linkId, address indexed sender, uint256 amount, uint40 expiresAt);
    event LinkClaimed(bytes32 indexed linkId, address indexed recipient, uint256 amount);
    event LinkRevoked(bytes32 indexed linkId, address indexed sender, uint256 amount);
    event LinkSwept(bytes32 indexed linkId, address indexed sender, uint256 amount);

    function setUp() public {
        usdc = new ERC20Mock();
        links = new MozaikLinks(IERC20(address(usdc)));
    }

    function _fund(address who) internal {
        usdc.mint(who, 1_000_000_000);
        vm.prank(who);
        usdc.approve(address(links), type(uint256).max);
    }

    function _domainSeparator() internal view returns (bytes32) {
        bytes32 domainTypehash =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

        return keccak256(
            abi.encode(
                domainTypehash, keccak256(bytes("MozaikLinks")), keccak256(bytes("1")), block.chainid, address(links)
            )
        );
    }

    function _claimDigest(bytes32 linkId, address claimer) internal view returns (bytes32) {
        bytes32 claimTypehash = keccak256("Claim(bytes32 linkId,address recipient)");
        bytes32 structHash = keccak256(abi.encode(claimTypehash, linkId, claimer));

        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _signClaim(uint256 privKey, bytes32 linkId, address claimer) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, _claimDigest(linkId, claimer));

        return abi.encodePacked(r, s, v);
    }

    function test_Constructor_InvalidZeroUsdc() public {
        vm.expectRevert(MozaikLinks.InvalidInput.selector);
        new MozaikLinks(IERC20(address(0)));
    }

    function test_Constructor_ValidUsdcImmutable() public view {
        assertEq(address(links.USDC()), address(usdc));
    }

    function test_CreateLink_ValidCreate() public {
        address sender = makeAddr("sender");
        address linkPubKey = makeAddr("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        uint256 senderBefore = usdc.balanceOf(sender);
        uint256 escrowBefore = usdc.balanceOf(address(links));

        vm.expectEmit(true, true, true, true);
        emit LinkCreated(linkId, sender, amount, expiry);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        assertEq(usdc.balanceOf(sender), senderBefore - amount);
        assertEq(usdc.balanceOf(address(links)), escrowBefore + amount);

        MozaikLinks.Link memory link = links.getLink(linkId);

        assertEq(link.sender, sender);
        assertEq(link.expiresAt, expiry);
        assertEq(uint256(link.status), uint256(MozaikLinks.Status.Active));
        assertEq(link.claimSigner, linkPubKey);
        assertEq(link.amount, amount);
    }

    function test_CreateLink_InvalidZeroLinkId() public {
        address sender = makeAddr("sender");
        address linkPubKey = makeAddr("linkEphemeralKey");
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        vm.expectRevert(MozaikLinks.InvalidInput.selector);
        links.create(bytes32(0), linkPubKey, 10_000_000, expiry);
    }

    function test_CreateLink_InvalidZeroPubKey() public {
        address sender = makeAddr("sender");
        bytes32 linkId = keccak256("link-1");
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        vm.expectRevert(MozaikLinks.InvalidInput.selector);
        links.create(linkId, address(0), 10_000_000, expiry);
    }

    function test_CreateLink_InvalidZeroAmount() public {
        address sender = makeAddr("sender");
        address linkPubKey = makeAddr("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        vm.expectRevert(MozaikLinks.InvalidInput.selector);
        links.create(linkId, linkPubKey, 0, expiry);
    }

    function test_CreateLink_InvalidExpiryEqualsNow() public {
        address sender = makeAddr("sender");
        address linkPubKey = makeAddr("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        _fund(sender);

        vm.prank(sender);
        vm.expectRevert(MozaikLinks.InvalidInput.selector);
        links.create(linkId, linkPubKey, 10_000_000, uint40(block.timestamp));
    }

    function test_CreateLink_InvalidExpiryInPast() public {
        address sender = makeAddr("sender");
        address linkPubKey = makeAddr("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        _fund(sender);
        vm.warp(1000);

        vm.prank(sender);
        vm.expectRevert(MozaikLinks.InvalidInput.selector);
        links.create(linkId, linkPubKey, 10_000_000, uint40(999));
    }

    function test_CreateLink_InvalidDuplicateLinkId() public {
        address sender = makeAddr("sender");
        address linkPubKey = makeAddr("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        vm.prank(sender);
        vm.expectRevert(MozaikLinks.InvalidLink.selector);
        links.create(linkId, linkPubKey, amount, expiry);
    }

    function test_CreateLink_InvalidFeeOnTransferToken() public {
        address sender = makeAddr("sender");
        address linkPubKey = makeAddr("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);

        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        MozaikLinks feeEscrow = new MozaikLinks(IERC20(address(feeToken)));

        feeToken.mint(sender, 1_000_000_000);
        vm.prank(sender);
        feeToken.approve(address(feeEscrow), type(uint256).max);

        vm.prank(sender);
        vm.expectRevert(MozaikLinks.InvalidInput.selector);
        feeEscrow.create(linkId, linkPubKey, amount, expiry);
    }

    function test_Claim_ValidClaim() public {
        address sender = makeAddr("sender");
        address recipient = makeAddr("recipient");
        (address linkPubKey, uint256 linkPrivKey) = makeAddrAndKey("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        bytes memory sig = _signClaim(linkPrivKey, linkId, recipient);
        uint256 recipientBefore = usdc.balanceOf(recipient);

        vm.expectEmit(true, true, true, true);
        emit LinkClaimed(linkId, recipient, amount);

        vm.prank(recipient);
        links.claim(linkId, sig);

        assertEq(usdc.balanceOf(recipient), recipientBefore + amount);
        assertEq(uint256(links.getLink(linkId).status), uint256(MozaikLinks.Status.Claimed));
    }

    function test_Claim_InvalidNoneStatus() public {
        address recipient = makeAddr("recipient");
        (, uint256 linkPrivKey) = makeAddrAndKey("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");

        bytes memory sig = _signClaim(linkPrivKey, linkId, recipient);

        vm.prank(recipient);
        vm.expectRevert(MozaikLinks.InvalidLink.selector);
        links.claim(linkId, sig);
    }

    function test_Claim_InvalidAlreadyClaimed() public {
        address sender = makeAddr("sender");
        address recipient = makeAddr("recipient");
        (address linkPubKey, uint256 linkPrivKey) = makeAddrAndKey("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        bytes memory sig = _signClaim(linkPrivKey, linkId, recipient);

        vm.prank(recipient);
        links.claim(linkId, sig);

        vm.prank(recipient);
        vm.expectRevert(MozaikLinks.InvalidLink.selector);
        links.claim(linkId, sig);
    }

    function test_Claim_InvalidExpired() public {
        address sender = makeAddr("sender");
        address recipient = makeAddr("recipient");
        (address linkPubKey, uint256 linkPrivKey) = makeAddrAndKey("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        vm.warp(expiry);

        bytes memory sig = _signClaim(linkPrivKey, linkId, recipient);

        vm.prank(recipient);
        vm.expectRevert(MozaikLinks.InvalidLink.selector);
        links.claim(linkId, sig);
    }

    function test_Claim_InvalidPrivkey() public {
        address sender = makeAddr("sender");
        address recipient = makeAddr("recipient");
        address linkPubKey = makeAddr("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        (, uint256 wrongKey) = makeAddrAndKey("wrongKey");
        bytes memory sig = _signClaim(wrongKey, linkId, recipient);

        vm.prank(recipient);
        vm.expectRevert(MozaikLinks.InvalidSignature.selector);
        links.claim(linkId, sig);
    }

    function test_Claim_InvalidSignatureDifferentRecipient() public {
        address sender = makeAddr("sender");
        address recipient = makeAddr("recipient");
        (address linkPubKey, uint256 linkPrivKey) = makeAddrAndKey("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        address other = makeAddr("other");
        bytes memory sig = _signClaim(linkPrivKey, linkId, other);

        vm.prank(recipient);
        vm.expectRevert(MozaikLinks.InvalidSignature.selector);
        links.claim(linkId, sig);
    }

    function test_Claim_InvalidSignatureLength() public {
        address sender = makeAddr("sender");
        address recipient = makeAddr("recipient");
        address linkPubKey = makeAddr("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        bytes memory sig = hex"1234"; // 2 bytes, not 65

        vm.prank(recipient);
        vm.expectRevert(MozaikLinks.InvalidSignature.selector);
        links.claim(linkId, sig);
    }

    function test_Claim_InvalidSignatureUpperHalfS() public {
        address sender = makeAddr("sender");
        address recipient = makeAddr("recipient");
        (address linkPubKey, uint256 linkPrivKey) = makeAddrAndKey("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        // Produce a normal sig, then flip s to upper half (n - s) and v.
        // OZ's tryRecover rejects upper-half-s with RecoverError.InvalidSignatureS;
        // the contract must surface this as InvalidSignature, not OZ's error type.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(linkPrivKey, _claimDigest(linkId, recipient));
        // secp256k1 curve order
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 sFlipped = bytes32(n - uint256(s));
        uint8 vFlipped = v ^ 1;
        bytes memory sig = abi.encodePacked(r, sFlipped, vFlipped);

        vm.prank(recipient);
        vm.expectRevert(MozaikLinks.InvalidSignature.selector);
        links.claim(linkId, sig);
    }

    function test_Claim_InvalidZeroSignature() public {
        address sender = makeAddr("sender");
        address recipient = makeAddr("recipient");
        address linkPubKey = makeAddr("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        bytes memory sig = new bytes(65); // all zeros, length 65

        vm.prank(recipient);
        vm.expectRevert(MozaikLinks.InvalidSignature.selector);
        links.claim(linkId, sig);
    }

    function test_Revoke_ValidRevoke() public {
        address sender = makeAddr("sender");
        address linkPubKey = makeAddr("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        uint256 senderBefore = usdc.balanceOf(sender);

        vm.expectEmit(true, true, true, true);
        emit LinkRevoked(linkId, sender, amount);

        vm.prank(sender);
        links.revoke(linkId);

        assertEq(usdc.balanceOf(sender), senderBefore + amount);
        assertEq(uint256(links.getLink(linkId).status), uint256(MozaikLinks.Status.Revoked));
    }

    function test_Revoke_InvalidInactive() public {
        address sender = makeAddr("sender");
        bytes32 linkId = keccak256("link-1");

        vm.prank(sender);
        vm.expectRevert(MozaikLinks.InvalidLink.selector);
        links.revoke(linkId);
    }

    function test_Revoke_InvalidCallByNonSender() public {
        address sender = makeAddr("sender");
        address linkPubKey = makeAddr("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(MozaikLinks.InvalidOwner.selector);
        links.revoke(linkId);
    }

    function test_Revoke_InvalidExpired() public {
        address sender = makeAddr("sender");
        address linkPubKey = makeAddr("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        vm.warp(expiry);

        vm.prank(sender);
        vm.expectRevert(MozaikLinks.InvalidLink.selector);
        links.revoke(linkId);
    }

    function test_SweepExpired_ValidSweep() public {
        address sender = makeAddr("sender");
        address linkPubKey = makeAddr("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        vm.warp(expiry);

        uint256 senderBefore = usdc.balanceOf(sender);

        vm.expectEmit(true, true, true, true);
        emit LinkSwept(linkId, sender, amount);

        links.sweepExpired(linkId);

        assertEq(usdc.balanceOf(sender), senderBefore + amount);
        assertEq(uint256(links.getLink(linkId).status), uint256(MozaikLinks.Status.Swept));
    }

    function test_SweepExpired_InvalidInactive() public {
        bytes32 linkId = keccak256("link-1");

        vm.expectRevert(MozaikLinks.InvalidLink.selector);
        links.sweepExpired(linkId);
    }

    function test_SweepExpired_InvalidNotExpired() public {
        address sender = makeAddr("sender");
        address linkPubKey = makeAddr("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        vm.expectRevert(MozaikLinks.InvalidLink.selector);
        links.sweepExpired(linkId);
    }

    function test_SweepExpired_ValidPermissionlessCall() public {
        address sender = makeAddr("sender");
        address linkPubKey = makeAddr("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        vm.warp(expiry);

        address randomCaller = makeAddr("randomCaller");
        uint256 senderBefore = usdc.balanceOf(sender);
        uint256 callerBefore = usdc.balanceOf(randomCaller);

        vm.prank(randomCaller);
        links.sweepExpired(linkId);

        // Funds go to the sender, not the caller.
        assertEq(usdc.balanceOf(sender), senderBefore + amount);
        assertEq(usdc.balanceOf(randomCaller), callerBefore);
    }

    function test_Claim_InvalidAtExpiresAt() public {
        address sender = makeAddr("sender");
        address recipient = makeAddr("recipient");
        (address linkPubKey, uint256 linkPrivKey) = makeAddrAndKey("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        vm.warp(expiry);
        bytes memory sig = _signClaim(linkPrivKey, linkId, recipient);

        vm.prank(recipient);
        vm.expectRevert(MozaikLinks.InvalidLink.selector);
        links.claim(linkId, sig);
    }

    function test_Revoke_InvalidAtExpiresAt() public {
        address sender = makeAddr("sender");
        address linkPubKey = makeAddr("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        vm.warp(expiry);

        vm.prank(sender);
        vm.expectRevert(MozaikLinks.InvalidLink.selector);
        links.revoke(linkId);
    }

    function test_SweepExpired_ValidAtExpiresAt() public {
        address sender = makeAddr("sender");
        address linkPubKey = makeAddr("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        vm.warp(expiry);

        links.sweepExpired(linkId);
        assertEq(uint256(links.getLink(linkId).status), uint256(MozaikLinks.Status.Swept));
    }

    function test_Claim_ValidOneSecondBeforeExpiry() public {
        address sender = makeAddr("sender");
        address recipient = makeAddr("recipient");
        (address linkPubKey, uint256 linkPrivKey) = makeAddrAndKey("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        vm.warp(expiry - 1);
        bytes memory sig = _signClaim(linkPrivKey, linkId, recipient);

        vm.prank(recipient);
        links.claim(linkId, sig);
        assertEq(uint256(links.getLink(linkId).status), uint256(MozaikLinks.Status.Claimed));
    }

    function test_Revoke_ValidOneSecondBeforeExpiry() public {
        address sender = makeAddr("sender");
        address linkPubKey = makeAddr("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        vm.warp(expiry - 1);

        vm.prank(sender);
        links.revoke(linkId);
        assertEq(uint256(links.getLink(linkId).status), uint256(MozaikLinks.Status.Revoked));
    }

    function test_SweepExpired_InvalidOneSecondBeforeExpiry() public {
        address sender = makeAddr("sender");
        address linkPubKey = makeAddr("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        vm.warp(expiry - 1);

        vm.expectRevert(MozaikLinks.InvalidLink.selector);
        links.sweepExpired(linkId);
    }

    function test_Monotonic_ClaimedRejectsOthers() public {
        address sender = makeAddr("sender");
        address recipient = makeAddr("recipient");
        (address linkPubKey, uint256 linkPrivKey) = makeAddrAndKey("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        bytes memory sig = _signClaim(linkPrivKey, linkId, recipient);
        vm.prank(recipient);
        links.claim(linkId, sig);

        vm.prank(sender);
        vm.expectRevert(MozaikLinks.InvalidLink.selector);
        links.revoke(linkId);

        vm.warp(expiry);
        vm.expectRevert(MozaikLinks.InvalidLink.selector);
        links.sweepExpired(linkId);
    }

    function test_Monotonic_RevokedRejectsOthers() public {
        address sender = makeAddr("sender");
        address recipient = makeAddr("recipient");
        (address linkPubKey, uint256 linkPrivKey) = makeAddrAndKey("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        vm.prank(sender);
        links.revoke(linkId);

        bytes memory sig = _signClaim(linkPrivKey, linkId, recipient);
        vm.prank(recipient);
        vm.expectRevert(MozaikLinks.InvalidLink.selector);
        links.claim(linkId, sig);

        vm.warp(expiry);
        vm.expectRevert(MozaikLinks.InvalidLink.selector);
        links.sweepExpired(linkId);
    }

    function test_Monotonic_SweptRejectsOthers() public {
        address sender = makeAddr("sender");
        address recipient = makeAddr("recipient");
        (address linkPubKey, uint256 linkPrivKey) = makeAddrAndKey("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        vm.warp(expiry);
        links.sweepExpired(linkId);

        bytes memory sig = _signClaim(linkPrivKey, linkId, recipient);
        vm.prank(recipient);
        vm.expectRevert(MozaikLinks.InvalidLink.selector);
        links.claim(linkId, sig);

        vm.prank(sender);
        vm.expectRevert(MozaikLinks.InvalidLink.selector);
        links.revoke(linkId);
    }

    function test_DustTransfer_NoEffectOnClaim() public {
        address sender = makeAddr("sender");
        address recipient = makeAddr("recipient");
        (address linkPubKey, uint256 linkPrivKey) = makeAddrAndKey("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        // Anyone can transfer USDC directly to the contract; that should not affect link.amount
        // and the dust should remain after claim.
        uint256 dust = 12345;
        usdc.mint(address(this), dust);
        usdc.transfer(address(links), dust);

        bytes memory sig = _signClaim(linkPrivKey, linkId, recipient);
        vm.prank(recipient);
        links.claim(linkId, sig);

        assertEq(usdc.balanceOf(recipient), amount, "claim must pay only link.amount");
        assertEq(usdc.balanceOf(address(links)), dust, "dust remains in escrow");
    }

    function test_DustTransfer_NoEffectBeforeCreate() public {
        address sender = makeAddr("sender");
        address linkPubKey = makeAddr("linkEphemeralKey");
        bytes32 linkId = keccak256("link-1");
        uint256 amount = 10_000_000;
        uint40 expiry = uint40(block.timestamp + 1 days);
        _fund(sender);

        // Transfer dust BEFORE creating a link. The exact-amount check measures delta only,
        // so pre-existing dust shouldn't cause a revert.
        usdc.mint(address(this), 999);
        usdc.transfer(address(links), 999);

        vm.prank(sender);
        links.create(linkId, linkPubKey, amount, expiry);

        MozaikLinks.Link memory link = links.getLink(linkId);
        assertEq(link.amount, amount);
        assertEq(usdc.balanceOf(address(links)), 999 + amount);
    }
}
