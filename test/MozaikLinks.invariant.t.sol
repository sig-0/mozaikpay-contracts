// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MozaikLinks} from "../src/paylinks/MozaikLinks.sol";

/// @notice Invariant handler that drives the MozaikLinks state machine via random calls.
/// @dev Tracks ghost state for each created link so the invariant test can sum active
/// amounts and verify they don't exceed the escrow's USDC balance.
contract LinksHandler is Test {
    bytes32 internal constant CLAIM_TYPEHASH = keccak256("Claim(bytes32 linkId,address recipient)");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    MozaikLinks public links;
    ERC20Mock public usdc;

    address public sender;

    bytes32[] internal _ids;
    mapping(bytes32 => uint256) internal _amount;
    mapping(bytes32 => uint40) internal _expiresAt;
    mapping(bytes32 => uint256) internal _privKey;
    mapping(bytes32 => bool) internal _isActive;
    mapping(bytes32 => bool) internal _seen;

    // Ghost: track that no observable invariant has ever broken.
    bool public statusEverWentBackwards;
    mapping(bytes32 => MozaikLinks.Status) internal _lastStatus;

    constructor(MozaikLinks _links, ERC20Mock _usdc, address _sender) {
        links = _links;
        usdc = _usdc;
        sender = _sender;
    }

    function ids() external view returns (bytes32[] memory) {
        return _ids;
    }

    function activeAmount(bytes32 id) external view returns (uint256) {
        return _isActive[id] ? _amount[id] : 0;
    }

    /// @notice The amount the handler recorded at creation time. Used by the
    /// invariant test to verify the contract never mutates link.amount post-create.
    function recordedAmount(bytes32 id) external view returns (uint256) {
        return _amount[id];
    }

    function totalActiveAmount() external view returns (uint256 total) {
        for (uint256 i = 0; i < _ids.length; i++) {
            if (_isActive[_ids[i]]) {
                total += _amount[_ids[i]];
            }
        }
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256(bytes("MozaikLinks")), keccak256(bytes("1")), block.chainid, address(links)
            )
        );
    }

    function _claimDigest(bytes32 linkId, address claimer) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(CLAIM_TYPEHASH, linkId, claimer));

        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _checkMonotonic(bytes32 linkId) internal {
        MozaikLinks.Status current = links.getLink(linkId).status;
        MozaikLinks.Status prev = _lastStatus[linkId];

        // Allowed: None -> Active -> {Claimed, Revoked, Swept}. Anything else (e.g. Claimed -> Active) is illegal.
        if (uint256(current) < uint256(prev)) statusEverWentBackwards = true;

        _lastStatus[linkId] = current;
    }

    // -------------------------------------------------------------------------
    // Bounded actions exposed to the invariant fuzzer
    // -------------------------------------------------------------------------

    function create(uint256 idSeed, uint256 keySeed, uint256 amountSeed, uint256 expirySeed) external {
        bytes32 id = keccak256(abi.encode(idSeed));
        if (_seen[id]) return;

        // Constrain key seed away from zero to avoid InvalidPubKey trivially. (Public keys derived from
        // very small private keys are valid; the contract only forbids the zero address.)
        keySeed = bound(keySeed, 1, type(uint128).max);
        address pubKey = vm.addr(keySeed);

        uint256 amount = bound(amountSeed, 1, 1_000_000);
        uint40 exp = uint40(bound(expirySeed, block.timestamp + 1, block.timestamp + 365 days));

        usdc.mint(sender, amount);
        vm.prank(sender);
        usdc.approve(address(links), type(uint256).max);

        vm.prank(sender);
        links.create(id, pubKey, amount, exp);

        _ids.push(id);
        _seen[id] = true;
        _amount[id] = amount;
        _expiresAt[id] = exp;
        _privKey[id] = keySeed;
        _isActive[id] = true;
        _lastStatus[id] = MozaikLinks.Status.Active;
    }

    function claim(uint256 idIndex, address claimer) external {
        if (_ids.length == 0) return;
        bytes32 id = _ids[bound(idIndex, 0, _ids.length - 1)];
        if (!_isActive[id]) return;
        if (block.timestamp >= _expiresAt[id]) return;

        // Constrain claimer away from common reserved/precompile addresses.
        claimer = address(uint160(bound(uint256(uint160(claimer)), 100, type(uint160).max)));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_privKey[id], _claimDigest(id, claimer));
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(claimer);
        links.claim(id, sig);

        _isActive[id] = false;
        _checkMonotonic(id);
    }

    function revoke(uint256 idIndex) external {
        if (_ids.length == 0) return;
        bytes32 id = _ids[bound(idIndex, 0, _ids.length - 1)];
        if (!_isActive[id]) return;
        if (block.timestamp >= _expiresAt[id]) return;

        vm.prank(sender);
        links.revoke(id);

        _isActive[id] = false;
        _checkMonotonic(id);
    }

    function sweepExpired(uint256 idIndex, address caller) external {
        if (_ids.length == 0) return;
        bytes32 id = _ids[bound(idIndex, 0, _ids.length - 1)];
        if (!_isActive[id]) return;
        if (block.timestamp < _expiresAt[id]) return;

        caller = address(uint160(bound(uint256(uint160(caller)), 100, type(uint160).max)));

        vm.prank(caller);
        links.sweepExpired(id);

        _isActive[id] = false;
        _checkMonotonic(id);
    }

    /// @notice Direct USDC transfer to escrow — surplus dust the contract must tolerate.
    function dustTransfer(uint256 amount) external {
        amount = bound(amount, 1, 100);
        usdc.mint(address(this), amount);
        usdc.transfer(address(links), amount);
    }

    /// @notice Advance time by up to 2 days, so links can age past their expiry.
    function warpForward(uint256 secs) external {
        secs = bound(secs, 1, 2 days);
        vm.warp(block.timestamp + secs);
    }
}

contract MozaikLinksInvariantTest is Test {
    LinksHandler internal handler;
    MozaikLinks internal links;
    ERC20Mock internal usdc;
    address internal sender;

    function setUp() public {
        usdc = new ERC20Mock();
        links = new MozaikLinks(IERC20(address(usdc)));
        sender = makeAddr("invariantSender");

        handler = new LinksHandler(links, usdc, sender);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = LinksHandler.create.selector;
        selectors[1] = LinksHandler.claim.selector;
        selectors[2] = LinksHandler.revoke.selector;
        selectors[3] = LinksHandler.sweepExpired.selector;
        selectors[4] = LinksHandler.dustTransfer.selector;
        selectors[5] = LinksHandler.warpForward.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Sum of active link amounts must never exceed the contract's USDC balance.
    /// Inequality (not equality) — anyone can transfer dust directly to the contract.
    function invariant_ActiveAmountsCoveredByBalance() public view {
        uint256 active = handler.totalActiveAmount();
        uint256 escrowBal = usdc.balanceOf(address(links));

        assertLe(active, escrowBal, "active obligations exceed escrow balance");
    }

    /// @dev Status must never go backwards (None -> Active -> terminal; never reversed).
    function invariant_StatusMonotonic() public view {
        assertFalse(handler.statusEverWentBackwards(), "status went backwards");
    }

    /// @dev For any link the contract has ever recorded, expiresAt must be > 0.
    /// (None implies never created; any non-None status was created with a valid expiry.)
    function invariant_NonZeroExpiryForCreated() public view {
        bytes32[] memory ids = handler.ids();
        for (uint256 i = 0; i < ids.length; i++) {
            MozaikLinks.Link memory link = links.getLink(ids[i]);
            if (link.status != MozaikLinks.Status.None) {
                assertGt(link.expiresAt, 0, "expiresAt must be non-zero for created links");
            }
        }
    }

    /// @dev Per-link `amount` is set at creation and never modified by any external function.
    /// Compared against the handler's ghost record of the value passed at createLink time.
    function invariant_AmountStable() public view {
        bytes32[] memory ids = handler.ids();
        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(links.getLink(ids[i]).amount, handler.recordedAmount(ids[i]), "link.amount mutated after creation");
        }
    }
}
