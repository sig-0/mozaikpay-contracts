// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MozaikLinks} from "../src/paylinks/MozaikLinks.sol";

/// @notice Fork test against Base Sepolia. Deploys MozaikLinks against the real
///         Circle USDC proxy and runs the full create/claim/revoke/sweep flow.
/// @dev    Skipped automatically when BASE_SEPOLIA_RPC is not set in the env.
///         Run with `make test-fork`.
contract MozaikLinksForkTest is Test {
    /// @dev Circle's USDC on Base Sepolia.
    /// https://developers.circle.com/stablecoins/usdc-contract-addresses
    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    bytes32 internal constant CLAIM_TYPEHASH = keccak256("Claim(bytes32 linkId,address recipient)");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    MozaikLinks internal links;
    IERC20 internal usdc;

    address internal sender;
    address internal recipient;
    uint256 internal recipientKey;

    address internal linkPubKey;
    uint256 internal linkPrivKey;

    bytes32 internal constant LINK_ID = keccak256("fork-link-1");
    uint256 internal constant AMOUNT = 5_000_000; // 5 USDC

    modifier onlyFork() {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC", string(""));
        if (bytes(rpc).length == 0) return;

        vm.createSelectFork(rpc);
        _;
    }

    function _setupFork() internal {
        usdc = IERC20(BASE_SEPOLIA_USDC);
        links = new MozaikLinks(usdc);

        sender = makeAddr("forkSender");
        (recipient, recipientKey) = makeAddrAndKey("forkRecipient");
        (linkPubKey, linkPrivKey) = makeAddrAndKey("forkLinkKey");

        // Forge's deal cheatcode writes balance directly via StdStorage. For Circle USDC
        // (FiatTokenV2_2 proxy) the storage slot for balances is auto-detected. If a future
        // USDC implementation upgrade breaks slot detection, this assertion catches it.
        deal(address(usdc), sender, AMOUNT * 10, true);
        require(usdc.balanceOf(sender) >= AMOUNT, "deal: USDC balance setup failed");

        vm.prank(sender);
        // Approve via low-level call so we don't need an interface that includes approve.
        (bool ok,) =
            address(usdc).call(abi.encodeWithSignature("approve(address,uint256)", address(links), type(uint256).max));

        require(ok, "USDC approve failed");
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256(bytes("MozaikLinks")), keccak256(bytes("1")), block.chainid, address(links)
            )
        );
    }

    function _signClaim(uint256 privKey, bytes32 linkId, address claimer) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(CLAIM_TYPEHASH, linkId, claimer));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);

        return abi.encodePacked(r, s, v);
    }

    function test_Fork_FullCreateClaimFlow() public onlyFork {
        _setupFork();

        uint256 senderBefore = usdc.balanceOf(sender);
        uint256 recipientBefore = usdc.balanceOf(recipient);

        vm.prank(sender);
        links.create(LINK_ID, linkPubKey, AMOUNT, uint40(block.timestamp + 1 hours));

        assertEq(usdc.balanceOf(sender), senderBefore - AMOUNT, "sender USDC not deducted");
        assertEq(usdc.balanceOf(address(links)), AMOUNT, "escrow USDC not received");

        bytes memory sig = _signClaim(linkPrivKey, LINK_ID, recipient);
        vm.prank(recipient);
        links.claim(LINK_ID, sig);

        assertEq(usdc.balanceOf(recipient), recipientBefore + AMOUNT, "recipient not paid");
        assertEq(usdc.balanceOf(address(links)), 0, "escrow not drained");

        MozaikLinks.Link memory link = links.getLink(LINK_ID);
        assertEq(uint256(link.status), uint256(MozaikLinks.Status.Claimed));
    }

    function test_Fork_RevokeReturnsFunds() public onlyFork {
        _setupFork();

        uint256 senderBefore = usdc.balanceOf(sender);

        vm.prank(sender);
        links.create(LINK_ID, linkPubKey, AMOUNT, uint40(block.timestamp + 1 hours));

        vm.prank(sender);
        links.revoke(LINK_ID);

        assertEq(usdc.balanceOf(sender), senderBefore, "sender not refunded after revoke");
        assertEq(uint256(links.getLink(LINK_ID).status), uint256(MozaikLinks.Status.Revoked));
    }

    function test_Fork_SweepExpiredAfterTTL() public onlyFork {
        _setupFork();

        uint256 senderBefore = usdc.balanceOf(sender);
        uint40 expiresAt = uint40(block.timestamp + 60);

        vm.prank(sender);
        links.create(LINK_ID, linkPubKey, AMOUNT, expiresAt);

        vm.warp(expiresAt + 1);

        // Permissionless: a third party can call sweep; funds still go to the sender.
        address sweeper = makeAddr("sweeper");
        vm.prank(sweeper);
        links.sweepExpired(LINK_ID);

        assertEq(usdc.balanceOf(sender), senderBefore, "sender not refunded after sweep");
        assertEq(uint256(links.getLink(LINK_ID).status), uint256(MozaikLinks.Status.Swept));
    }
}
