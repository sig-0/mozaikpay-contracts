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
    bytes32 internal constant CLAIM_TYPEHASH = keccak256("Claim(address claimSigner,address recipient)");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    MozaikLinks public links;
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
    mapping(address => MozaikLinks.Status) internal _lastStatus;

    constructor(MozaikLinks _links, ERC20Mock _usdc, address _sender) {
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
                DOMAIN_TYPEHASH, keccak256(bytes("MozaikLinks")), keccak256(bytes("1")), block.chainid, address(links)
            )
        );
    }

    function _claimDigest(address claimSigner, address claimer) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(CLAIM_TYPEHASH, claimSigner, claimer));

        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _checkMonotonic(address claimSigner) internal {
        MozaikLinks.Status current = links.getLink(claimSigner).status;
        MozaikLinks.Status prev = _lastStatus[claimSigner];

        // Allowed: None -> Active -> {Claimed, Revoked, Swept}. Anything else (e.g. Claimed -> Active) is illegal.
        if (uint256(current) < uint256(prev)) statusEverWentBackwards = true;

        _lastStatus[claimSigner] = current;
    }

    function create(uint256 keySeed, uint256 amountSeed, uint256 expirySeed) external {
        // Constrain key seed away from zero to avoid InvalidPubKey trivially. (Public keys derived from
        // very small private keys are valid; the contract only forbids the zero address.)
        keySeed = bound(keySeed, 1, type(uint128).max);
        address pubKey = vm.addr(keySeed);
        if (_seen[pubKey]) return;

        uint256 amount = bound(amountSeed, 1, 1_000_000);
        uint64 exp = uint64(bound(expirySeed, block.timestamp + 1, block.timestamp + 365 days));

        usdc.mint(sender, amount);
        vm.prank(sender);
        usdc.approve(address(links), type(uint256).max);

        vm.prank(sender);
        links.create(pubKey, amount, exp);

        _signers.push(pubKey);
        _seen[pubKey] = true;
        _amount[pubKey] = amount;
        _expiresAt[pubKey] = exp;
        _privKey[pubKey] = keySeed;
        _isActive[pubKey] = true;
        _lastStatus[pubKey] = MozaikLinks.Status.Active;
    }

    function claim(uint256 idIndex, address claimer) external {
        if (_signers.length == 0) return;
        address claimSigner = _signers[bound(idIndex, 0, _signers.length - 1)];
        if (!_isActive[claimSigner]) return;
        if (block.timestamp >= _expiresAt[claimSigner]) return;

        // Constrain claimer away from common reserved/precompile addresses.
        claimer = address(uint160(bound(uint256(uint160(claimer)), 100, type(uint160).max)));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_privKey[claimSigner], _claimDigest(claimSigner, claimer));
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(claimer);
        links.claim(claimSigner, sig);

        _isActive[claimSigner] = false;
        _checkMonotonic(claimSigner);
    }

    function revoke(uint256 idIndex) external {
        if (_signers.length == 0) return;
        address claimSigner = _signers[bound(idIndex, 0, _signers.length - 1)];
        if (!_isActive[claimSigner]) return;
        if (block.timestamp >= _expiresAt[claimSigner]) return;

        vm.prank(sender);
        links.revoke(claimSigner);

        _isActive[claimSigner] = false;
        _checkMonotonic(claimSigner);
    }

    function sweepExpired(uint256 idIndex, address caller) external {
        if (_signers.length == 0) return;
        address claimSigner = _signers[bound(idIndex, 0, _signers.length - 1)];
        if (!_isActive[claimSigner]) return;
        if (block.timestamp < _expiresAt[claimSigner]) return;

        caller = address(uint160(bound(uint256(uint160(caller)), 100, type(uint160).max)));

        vm.prank(caller);
        links.sweepExpired(claimSigner);

        _isActive[claimSigner] = false;
        _checkMonotonic(claimSigner);
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
        address[] memory s = handler.signers();
        for (uint256 i = 0; i < s.length; i++) {
            MozaikLinks.Link memory link = links.getLink(s[i]);
            if (link.status != MozaikLinks.Status.None) {
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
