// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {MozaikPaylinks} from "../../src/paylinks/MozaikPaylinks.sol";

/// @notice Minimal ERC20 with a public mint.
contract MintableERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Echidna fuzz target for MozaikPaylinks.
/// @dev Several actors create, claim and reclaim links, including invalid calls and calls at the expiry
///      boundary. A model built only from harness inputs predicts each outcome, down to the revert error.
///      The contract's links and balances must equal the model's.
contract PaylinksEchidna {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 internal constant CLAIM_TYPEHASH = keccak256("Claim(address claimSigner,address recipient)");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    /// @dev Predicted outcome "call succeeds".
    bytes4 internal constant OK = bytes4(0);

    /// @dev 1M USDC.
    uint256 internal constant MAX_AMOUNT = 1e12;

    /// @dev Keep equal to maxTimeDelay in the config.
    uint256 internal constant MAX_EXPIRY_OFFSET = 7 days;

    /// @dev The first NUM_SENDERS actors create links. The rest never do.
    uint256 internal constant NUM_SENDERS = 3;
    uint256 internal constant NUM_ACTORS = 5;

    struct ModelLink {
        address sender;
        uint64 expiresAt;
        MozaikPaylinks.Status status;
        uint256 amount;
        uint256 key;
    }

    MozaikPaylinks internal links;
    MintableERC20 internal usdc;

    address[NUM_ACTORS] internal _actors;
    address[] internal _signers;
    mapping(address claimSigner => ModelLink) internal _model;
    mapping(address account => uint256) internal _expectedBalance;
    uint256 internal _openTotal;
    uint256 internal _dustTotal;

    bool internal _createMismatch;
    bool internal _claimMismatch;
    bool internal _reclaimMismatch;

    constructor() {
        usdc = new MintableERC20();
        links = new MozaikPaylinks(IERC20(address(usdc)));

        _actors = [
            address(uint160(0xA11CE)),
            address(uint160(0xB0B)),
            address(uint160(0xCA201)),
            address(uint160(0x5757)),
            address(uint160(0x4EC1))
        ];

        for (uint256 i = 0; i < NUM_SENDERS; i++) {
            vm.prank(_actors[i]);
            usdc.approve(address(links), type(uint256).max);
        }
    }

    /// @notice A sender creates a link with a fresh key.
    function create(uint8 senderSel, uint256 keySeed, uint256 amountSeed, uint256 expirySeed) external {
        uint256 key = _freshKey(keySeed);

        _create(_sender(senderSel), vm.addr(key), key, amountSeed, expirySeed);
    }

    /// @notice A sender creates a link with the zero address as its claim signer.
    function createZeroSigner(uint8 senderSel, uint256 amountSeed, uint256 expirySeed) external {
        _create(_sender(senderSel), address(0), 0, amountSeed, expirySeed);
    }

    /// @notice A sender creates a link under a claim signer that is already used, open or not.
    function createDuplicate(uint8 senderSel, uint256 linkSel, uint256 amountSeed, uint256 expirySeed) external {
        if (_signers.length == 0) return;

        address claimSigner = _createdLink(linkSel);

        _create(_sender(senderSel), claimSigner, _model[claimSigner].key, amountSeed, expirySeed);
    }

    /// @notice An actor claims a link with the link key's signature for itself.
    function claim(uint256 linkSel, uint8 claimerSel) external {
        if (_signers.length == 0) return;

        address claimSigner = _createdLink(linkSel);

        _claimSigned(claimSigner, _model[claimSigner].key, _actor(claimerSel));
    }

    /// @notice As `claim`, one second before, at or one second after the link's expiry.
    function claimNearExpiry(uint256 linkSel, uint8 claimerSel, uint8 offsetSel) external {
        if (_signers.length == 0) return;

        address claimSigner = _createdLink(linkSel);
        _warpNearExpiry(claimSigner, offsetSel);

        _claimSigned(claimSigner, _model[claimSigner].key, _actor(claimerSel));
    }

    /// @notice An actor claims with a fresh key's signature for itself. That key usually has no link.
    function claimUnknownLink(uint256 keySeed, uint8 claimerSel) external {
        uint256 key = _freshKey(keySeed);

        _claimSigned(vm.addr(key), key, _actor(claimerSel));
    }

    /// @notice An actor claims with the link key's signature for another recipient.
    function claimForOtherRecipient(uint256 linkSel, uint8 callerSel, uint8 recipientSel) external {
        address caller = _actor(callerSel);
        address recipient = _actor(recipientSel);
        if (_signers.length == 0 || caller == recipient) return;

        address claimSigner = _createdLink(linkSel);

        _claim(claimSigner, caller, _sign(_model[claimSigner].key, claimSigner, recipient), false);
    }

    /// @notice An actor claims with a signature for itself by a key other than the link's.
    function claimWithWrongKey(uint256 linkSel, uint8 callerSel, uint256 keySeed) external {
        if (_signers.length == 0) return;

        address claimSigner = _createdLink(linkSel);
        uint256 wrongKey = _freshKey(keySeed);
        if (wrongKey == _model[claimSigner].key) return;

        address caller = _actor(callerSel);

        _claim(claimSigner, caller, _sign(wrongKey, claimSigner, caller), false);
    }

    /// @notice An actor claims with the high-s twin of its own valid signature.
    function claimHighS(uint256 linkSel, uint8 callerSel) external {
        if (_signers.length == 0) return;

        address claimSigner = _createdLink(linkSel);
        address caller = _actor(callerSel);

        _claim(claimSigner, caller, _highS(_model[claimSigner].key, claimSigner, caller), false);
    }

    /// @notice An actor claims with fuzzed signature bytes, which are never a valid signature.
    function claimRawSignature(uint256 linkSel, uint8 callerSel, bytes calldata signature) external {
        if (_signers.length == 0) return;

        _claim(_createdLink(linkSel), _actor(callerSel), signature, false);
    }

    /// @notice An actor reclaims a link.
    function reclaim(uint256 linkSel, uint8 callerSel) external {
        if (_signers.length == 0) return;

        _reclaim(_createdLink(linkSel), _actor(callerSel));
    }

    /// @notice As `reclaim`, one second before, at or one second after the link's expiry.
    function reclaimNearExpiry(uint256 linkSel, uint8 callerSel, uint8 offsetSel) external {
        if (_signers.length == 0) return;

        address claimSigner = _createdLink(linkSel);
        _warpNearExpiry(claimSigner, offsetSel);

        _reclaim(claimSigner, _actor(callerSel));
    }

    /// @notice An actor reclaims under a fresh key, which usually has no link.
    function reclaimUnknownLink(uint256 keySeed, uint8 callerSel) external {
        _reclaim(vm.addr(_freshKey(keySeed)), _actor(callerSel));
    }

    /// @notice Anyone sends USDC straight to the escrow, which must not affect any link.
    function dust(uint256 amountSeed) external {
        uint256 amount = _amount(amountSeed);
        usdc.mint(address(links), amount);
        _dustTotal += amount;
    }

    /// @notice Every create succeeded or reverted exactly as the model predicted, with the predicted error.
    function echidna_create_matches_model() external view returns (bool) {
        return !_createMismatch;
    }

    /// @notice Every claim succeeded or reverted exactly as the model predicted, with the predicted error.
    function echidna_claim_matches_model() external view returns (bool) {
        return !_claimMismatch;
    }

    /// @notice Every reclaim succeeded or reverted exactly as the model predicted, with the predicted error.
    function echidna_reclaim_matches_model() external view returns (bool) {
        return !_reclaimMismatch;
    }

    /// @notice Each created link's on-chain sender, expiresAt, status and amount equal the model's.
    function echidna_links_match_model() external view returns (bool) {
        for (uint256 i = 0; i < _signers.length; i++) {
            MozaikPaylinks.Link memory actual = links.getLink(_signers[i]);
            ModelLink storage modelled = _model[_signers[i]];

            if (actual.sender != modelled.sender || actual.expiresAt != modelled.expiresAt) return false;
            if (actual.status != modelled.status || actual.amount != modelled.amount) return false;
        }

        return true;
    }

    /// @notice The escrow holds exactly the open links plus dust, and each actor holds exactly its modelled balance.
    function echidna_balances_match_model() external view returns (bool) {
        if (usdc.balanceOf(address(links)) != _openTotal + _dustTotal) return false;

        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            if (usdc.balanceOf(_actors[i]) != _expectedBalance[_actors[i]]) return false;
        }

        return true;
    }

    /// @notice The links the contract itself reports as Active never add up to more than the escrow holds.
    function echidna_escrow_covers_active_links() external view returns (bool) {
        uint256 active;
        for (uint256 i = 0; i < _signers.length; i++) {
            MozaikPaylinks.Link memory link = links.getLink(_signers[i]);
            if (link.status == MozaikPaylinks.Status.Active) active += link.amount;
        }

        return active <= usdc.balanceOf(address(links));
    }

    /// @dev The sender is funded first, so only the model's checks can make create revert.
    function _create(address sender, address claimSigner, uint256 key, uint256 amountSeed, uint256 expirySeed)
        internal
    {
        uint256 amount = _amount(amountSeed);
        uint64 expiresAt = _expiry(expirySeed);
        bytes4 expected = _expectCreate(claimSigner, amount, expiresAt);
        bytes memory data = abi.encodeCall(MozaikPaylinks.create, (claimSigner, amount, expiresAt));

        usdc.mint(sender, amount);
        _expectedBalance[sender] += amount;

        vm.prank(sender);
        (bool ok, bytes memory returnData) = address(links).call(data);

        if (_mismatch(ok, returnData, expected)) _createMismatch = true;
        else if (ok) _commitCreate(sender, claimSigner, key, amount, expiresAt);
    }

    /// @dev Claims with the only valid signature: the link key's, over (claimSigner, claimer).
    function _claimSigned(address claimSigner, uint256 key, address claimer) internal {
        _claim(claimSigner, claimer, _sign(key, claimSigner, claimer), true);
    }

    /// @dev `validSignature` is true only when the link key signed (claimSigner, caller).
    function _claim(address claimSigner, address caller, bytes memory signature, bool validSignature) internal {
        bytes4 expected = _expectClaim(_model[claimSigner], validSignature);
        bytes memory data = abi.encodeCall(MozaikPaylinks.claim, (claimSigner, signature));

        vm.prank(caller);
        (bool ok, bytes memory returnData) = address(links).call(data);

        if (_mismatch(ok, returnData, expected)) _claimMismatch = true;
        else if (ok) _commitClaim(claimSigner, caller);
    }

    function _reclaim(address claimSigner, address caller) internal {
        bytes4 expected = _expectReclaim(_model[claimSigner], caller);
        bytes memory data = abi.encodeCall(MozaikPaylinks.reclaim, (claimSigner));

        vm.prank(caller);
        (bool ok, bytes memory returnData) = address(links).call(data);

        if (_mismatch(ok, returnData, expected)) _reclaimMismatch = true;
        else if (ok) _commitReclaim(claimSigner);
    }

    /// @dev create's checks, in the contract's order.
    function _expectCreate(address claimSigner, uint256 amount, uint64 expiresAt) internal view returns (bytes4) {
        if (claimSigner == address(0)) return MozaikPaylinks.InvalidInput.selector;
        if (amount == 0) return MozaikPaylinks.InvalidInput.selector;
        if (expiresAt <= block.timestamp) return MozaikPaylinks.InvalidInput.selector;
        if (_model[claimSigner].status != MozaikPaylinks.Status.None) return MozaikPaylinks.InvalidLink.selector;

        return OK;
    }

    /// @dev claim's checks, in the contract's order. A claim at exactly expiresAt is too late.
    function _expectClaim(ModelLink memory link, bool validSignature) internal view returns (bytes4) {
        if (link.status != MozaikPaylinks.Status.Active) return MozaikPaylinks.InvalidLink.selector;
        if (block.timestamp >= link.expiresAt) return MozaikPaylinks.InvalidLink.selector;
        if (!validSignature) return MozaikPaylinks.InvalidSignature.selector;

        return OK;
    }

    /// @dev reclaim's checks, in the contract's order. From exactly expiresAt anyone may reclaim.
    function _expectReclaim(ModelLink memory link, address caller) internal view returns (bytes4) {
        if (link.status != MozaikPaylinks.Status.Active) return MozaikPaylinks.InvalidLink.selector;
        if (block.timestamp < link.expiresAt && caller != link.sender) return MozaikPaylinks.InvalidOwner.selector;

        return OK;
    }

    /// @dev True when the call succeeded against the prediction, or reverted against it or with another error.
    function _mismatch(bool ok, bytes memory returnData, bytes4 expected) internal pure returns (bool) {
        if (ok) return expected != OK;

        return expected == OK || bytes4(returnData) != expected;
    }

    function _commitCreate(address sender, address claimSigner, uint256 key, uint256 amount, uint64 expiresAt)
        internal
    {
        _model[claimSigner] = ModelLink({
            sender: sender, expiresAt: expiresAt, status: MozaikPaylinks.Status.Active, amount: amount, key: key
        });
        _signers.push(claimSigner);
        _expectedBalance[sender] -= amount;
        _openTotal += amount;
    }

    /// @dev The claimer is paid.
    function _commitClaim(address claimSigner, address claimer) internal {
        ModelLink storage link = _model[claimSigner];
        link.status = MozaikPaylinks.Status.Claimed;
        _openTotal -= link.amount;
        _expectedBalance[claimer] += link.amount;
    }

    /// @dev The link's sender is paid, whoever calls.
    function _commitReclaim(address claimSigner) internal {
        ModelLink storage link = _model[claimSigner];
        link.status = MozaikPaylinks.Status.Reclaimed;
        _openTotal -= link.amount;
        _expectedBalance[link.sender] += link.amount;
    }

    function _sender(uint8 senderSel) internal view returns (address) {
        return _actors[senderSel % NUM_SENDERS];
    }

    function _actor(uint8 actorSel) internal view returns (address) {
        return _actors[actorSel % NUM_ACTORS];
    }

    /// @dev Callers check that at least one link exists.
    function _createdLink(uint256 linkSel) internal view returns (address) {
        return _signers[linkSel % _signers.length];
    }

    /// @dev Zero is reachable, and create must reject it.
    function _amount(uint256 amountSeed) internal pure returns (uint256) {
        return amountSeed % (MAX_AMOUNT + 1);
    }

    /// @dev The current time is reachable, and create must reject it.
    function _expiry(uint256 expirySeed) internal view returns (uint64) {
        return uint64(block.timestamp + expirySeed % (MAX_EXPIRY_OFFSET + 1));
    }

    function _freshKey(uint256 keySeed) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode("paylinks.key", keySeed))) % (SECP256K1_N - 1) + 1;
    }

    /// @dev Time never moves back, so a target in the past is skipped.
    function _warpNearExpiry(address claimSigner, uint8 offsetSel) internal {
        uint256 target = _model[claimSigner].expiresAt - 1 + offsetSel % 3;
        if (target >= block.timestamp) vm.warp(target);
    }

    /// @dev EIP-712 digest computed independently of the contract.
    function _digest(address claimSigner, address recipient) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("MozaikPaylinks")),
                keccak256(bytes("1")),
                block.chainid,
                address(links)
            )
        );
        bytes32 structHash = keccak256(abi.encode(CLAIM_TYPEHASH, claimSigner, recipient));

        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _sign(uint256 key, address claimSigner, address recipient) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(claimSigner, recipient));

        return abi.encodePacked(r, s, v);
    }

    /// @dev Same signer and digest as `_sign`, with s moved to the upper half of the curve order.
    function _highS(uint256 key, address claimSigner, address recipient) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(claimSigner, recipient));

        return abi.encodePacked(r, bytes32(SECP256K1_N - uint256(s)), v == 27 ? uint8(28) : uint8(27));
    }
}
