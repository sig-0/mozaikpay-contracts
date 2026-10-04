// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MozaikPaylinks} from "../../src/paylinks/MozaikPaylinks.sol";

/// @notice Invariant handler that drives the MozaikPaylinks state machine via random calls.
/// @dev Tracks ghost state for each created link and predicts every call's outcome, including calls on finished,
///      expired or duplicate links and reclaims by non-senders.
contract LinksHandler is Test {
    bytes32 internal constant CLAIM_TYPEHASH = keccak256("Claim(address claimSigner,address recipient)");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    MozaikPaylinks public links;
    ERC20Mock public usdc;

    address public sender;

    address[] internal _signers;
    mapping(address => uint256) internal _amount;
    mapping(address => uint64) internal _expiresAt;
    mapping(address => uint256) internal _privKey;
    mapping(address => bool) internal _isActive;
    mapping(address => bool) internal _seen;

    // Ghost: track that no observable invariant has ever broken.
    bool public statusEverWentBackwards;
    bool public outcomeMismatch;
    uint256 public dustTotal;
    mapping(address => MozaikPaylinks.Status) internal _lastStatus;

    constructor(MozaikPaylinks _links, ERC20Mock _usdc, address _sender) {
        links = _links;
        usdc = _usdc;
        sender = _sender;
    }

    function signers() external view returns (address[] memory) {
        return _signers;
    }

    function activeAmount(address claimSigner) external view returns (uint256) {
        return _isActive[claimSigner] ? _amount[claimSigner] : 0;
    }

    /// @notice The amount the handler recorded at creation time. Used by the
    /// invariant test to verify the contract never mutates link.amount post-create.
    function recordedAmount(address claimSigner) external view returns (uint256) {
        return _amount[claimSigner];
    }

    function totalActiveAmount() external view returns (uint256 total) {
        for (uint256 i = 0; i < _signers.length; i++) {
            if (_isActive[_signers[i]]) {
                total += _amount[_signers[i]];
            }
        }
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("MozaikPaylinks")),
                keccak256(bytes("1")),
                block.chainid,
                address(links)
            )
        );
    }

    function _claimDigest(address claimSigner, address claimer) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(CLAIM_TYPEHASH, claimSigner, claimer));

        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _checkMonotonic(address claimSigner) internal {
        MozaikPaylinks.Status current = links.getLink(claimSigner).status;
        MozaikPaylinks.Status prev = _lastStatus[claimSigner];

        // Allowed: None -> Active -> {Claimed, Revoked, Swept}. Anything else (e.g. Claimed -> Active) is illegal.
        if (uint256(current) < uint256(prev)) statusEverWentBackwards = true;

        _lastStatus[claimSigner] = current;
    }

    /// @dev Zero amounts and reused keys must revert.
    function create(uint256 keySeed, uint256 amountSeed, uint256 expirySeed) external {
        // Constrain key seed away from zero to avoid InvalidPubKey trivially. (Public keys derived from
        // very small private keys are valid; the contract only forbids the zero address.)
        keySeed = bound(keySeed, 1, type(uint128).max);
        address pubKey = vm.addr(keySeed);

        uint256 amount = bound(amountSeed, 0, 1_000_000);
        uint64 exp = uint64(bound(expirySeed, block.timestamp + 1, block.timestamp + 365 days));
        bytes4 expected = amount == 0
            ? MozaikPaylinks.InvalidInput.selector
            : _seen[pubKey] ? MozaikPaylinks.InvalidLink.selector : bytes4(0);

        usdc.mint(sender, amount);
        vm.prank(sender);
        usdc.approve(address(links), type(uint256).max);

        vm.prank(sender);
        try links.create(pubKey, amount, exp) {
            if (expected != bytes4(0)) {
                outcomeMismatch = true;

                return;
            }
        } catch (bytes memory err) {
            if (expected == bytes4(0) || bytes4(err) != expected) outcomeMismatch = true;

            return;
        }

        _signers.push(pubKey);
        _seen[pubKey] = true;
        _amount[pubKey] = amount;
        _expiresAt[pubKey] = exp;
        _privKey[pubKey] = keySeed;
        _isActive[pubKey] = true;
        _lastStatus[pubKey] = MozaikPaylinks.Status.Active;
    }

    /// @dev Claims any link, in any state. `wrongRecipient` signs for another address, which must be rejected.
    function claim(uint256 idIndex, address claimer, bool wrongRecipient) external {
        if (_signers.length == 0) return;

        address claimSigner = _signers[bound(idIndex, 0, _signers.length - 1)];

        // Constrain claimer away from common reserved/precompile addresses.
        claimer = address(uint160(bound(uint256(uint160(claimer)), 100, type(uint160).max - 1)));
        address signedFor = wrongRecipient ? address(uint160(claimer) + 1) : claimer;

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_privKey[claimSigner], _claimDigest(claimSigner, signedFor));
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes4 expected;
        if (!_isActive[claimSigner] || block.timestamp >= _expiresAt[claimSigner]) {
            expected = MozaikPaylinks.InvalidLink.selector;
        } else if (wrongRecipient) {
            expected = MozaikPaylinks.InvalidSignature.selector;
        }

        vm.prank(claimer);
        try links.claim(claimSigner, sig) {
            _settle(claimSigner, expected);
        } catch (bytes memory err) {
            if (expected == bytes4(0) || bytes4(err) != expected) outcomeMismatch = true;
        }
    }

    function reclaimAsSender(uint256 idIndex) external {
        if (_signers.length == 0) return;

        address claimSigner = _signers[bound(idIndex, 0, _signers.length - 1)];
        bytes4 expected = _isActive[claimSigner] ? bytes4(0) : MozaikPaylinks.InvalidLink.selector;

        vm.prank(sender);
        try links.reclaim(claimSigner) {
            _settle(claimSigner, expected);
        } catch (bytes memory err) {
            if (expected == bytes4(0) || bytes4(err) != expected) outcomeMismatch = true;
        }
    }

    /// @dev Reclaims any link from any caller. Before expiry only the sender may reclaim.
    function reclaimPermissionless(uint256 idIndex, address caller) external {
        if (_signers.length == 0) return;

        address claimSigner = _signers[bound(idIndex, 0, _signers.length - 1)];

        caller = address(uint160(bound(uint256(uint160(caller)), 100, type(uint160).max)));

        bytes4 expected;
        if (!_isActive[claimSigner]) {
            expected = MozaikPaylinks.InvalidLink.selector;
        } else if (block.timestamp < _expiresAt[claimSigner] && caller != sender) {
            expected = MozaikPaylinks.InvalidOwner.selector;
        }

        vm.prank(caller);
        try links.reclaim(claimSigner) {
            _settle(claimSigner, expected);
        } catch (bytes memory err) {
            if (expected == bytes4(0) || bytes4(err) != expected) outcomeMismatch = true;
        }
    }

    /// @dev Records a successful claim or reclaim, which must have been expected to succeed.
    function _settle(address claimSigner, bytes4 expected) internal {
        if (expected != bytes4(0)) outcomeMismatch = true;

        _isActive[claimSigner] = false;
        _checkMonotonic(claimSigner);
    }

    /// @notice Direct USDC transfer to escrow — surplus dust the contract must tolerate.
    function dustTransfer(uint256 amount) external {
        amount = bound(amount, 1, 100);
        usdc.mint(address(this), amount);
        usdc.transfer(address(links), amount);
        dustTotal += amount;
    }

    /// @notice Advance time by up to 2 days, so links can age past their expiry.
    function warpForward(uint256 secs) external {
        secs = bound(secs, 1, 2 days);
        vm.warp(block.timestamp + secs);
    }

    /// @notice Advance time to one second before, exactly at, or one second after a link's expiry.
    function warpToExpiry(uint256 idIndex, uint256 offset) external {
        if (_signers.length == 0) return;

        uint256 target = _expiresAt[_signers[bound(idIndex, 0, _signers.length - 1)]] + offset % 3 - 1;
        if (target > block.timestamp) vm.warp(target);
    }
}

contract MozaikPaylinksInvariantTest is Test {
    LinksHandler internal handler;
    MozaikPaylinks internal links;
    ERC20Mock internal usdc;
    address internal sender;

    function setUp() public {
        usdc = new ERC20Mock();
        links = new MozaikPaylinks(IERC20(address(usdc)));
        sender = makeAddr("invariantSender");

        handler = new LinksHandler(links, usdc, sender);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = LinksHandler.create.selector;
        selectors[1] = LinksHandler.claim.selector;
        selectors[2] = LinksHandler.reclaimAsSender.selector;
        selectors[3] = LinksHandler.reclaimPermissionless.selector;
        selectors[4] = LinksHandler.dustTransfer.selector;
        selectors[5] = LinksHandler.warpForward.selector;
        selectors[6] = LinksHandler.warpToExpiry.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Sum of active link amounts must never exceed the contract's USDC balance.
    /// Inequality (not equality) — anyone can transfer dust directly to the contract.
    function invariant_ActiveAmountsCoveredByBalance() public view {
        uint256 active = handler.totalActiveAmount();
        uint256 escrowBal = usdc.balanceOf(address(links));

        assertLe(active, escrowBal, "active obligations exceed escrow balance");
    }

    /// @dev Every create, claim and reclaim succeeds or reverts as predicted, with the predicted error.
    function invariant_OutcomesMatchModel() public view {
        assertFalse(handler.outcomeMismatch(), "a call's outcome did not match the model");
    }

    /// @dev The escrow holds exactly the active links plus dust.
    function invariant_EscrowEqualsActivePlusDust() public view {
        assertEq(usdc.balanceOf(address(links)), handler.totalActiveAmount() + handler.dustTotal(), "escrow balance");
    }

    /// @dev Status must never go backwards (None -> Active -> terminal; never reversed).
    function invariant_StatusMonotonic() public view {
        assertFalse(handler.statusEverWentBackwards(), "status went backwards");
    }

    /// @dev For any link the contract has ever recorded, expiresAt must be > 0.
    /// (None implies never created; any non-None status was created with a valid expiry.)
    function invariant_NonZeroExpiryForCreated() public view {
        address[] memory s = handler.signers();
        for (uint256 i = 0; i < s.length; i++) {
            MozaikPaylinks.Link memory link = links.getLink(s[i]);
            if (link.status != MozaikPaylinks.Status.None) {
                assertGt(link.expiresAt, 0, "expiresAt must be non-zero for created links");
            }
        }
    }

    /// @dev Per-link `amount` is set at creation and never modified by any external function.
    /// Compared against the handler's ghost record of the value passed at createLink time.
    function invariant_AmountStable() public view {
        address[] memory s = handler.signers();
        for (uint256 i = 0; i < s.length; i++) {
            assertEq(links.getLink(s[i]).amount, handler.recordedAmount(s[i]), "link.amount mutated after creation");
        }
    }
}
