// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title MozaikLinks
 * @notice Non-upgradeable USDC escrow for MozaikPay payment links.
 * @dev Lifecycle:
 *      - create(): sender deposits USDC and commits to an ephemeral keypair's address
 *        (`claimSigner`) plus an expiry timestamp.
 *      - claim(): caller submits an EIP-712 signature, generated off-chain with the
 *        ephemeral private key (the "secret" embedded in the link URL), over
 *        (linkId, msg.sender). The contract recovers the signer and matches it against
 *        the committed claimSigner; on success, USDC is sent to msg.sender. Binding the
 *        signed payload to the caller's address eliminates secret-extraction front-running:
 *        a mempool watcher who copies the calldata cannot redirect the funds to themselves
 *        because the signature is over the original claimer's address.
 *      - revoke(): sender-only cancel before expiry. Funds return to sender.
 *      - sweepExpired(): permissionless reclaim at/after expiry. Funds return to sender.
 *
 */
contract MozaikLinks is ReentrancyGuardTransient, EIP712 {
    using SafeERC20 for IERC20;

    /// @dev Per-link state machine. Transitions are monotonic; never reversed.
    enum Status {
        None,
        Active,
        Claimed,
        Revoked,
        Swept
    }

    /// @dev Slot-packed: sender(20) + expiresAt(5) + status(1) fit in slot 0;
    /// claimSigner and amount each occupy their own slot. 3 slots per link.
    struct Link {
        address sender;
        uint40 expiresAt;
        Status status;
        address claimSigner;
        uint256 amount;
    }

    /// @notice The USDC token address. Set at deployment, never changes.
    IERC20 public immutable USDC;

    mapping(bytes32 linkId => Link) private _links;

    /// @dev EIP-712 typed-data hash for claim authorization.
    bytes32 private constant CLAIM_TYPEHASH = keccak256("Claim(bytes32 linkId,address recipient)");

    error InvalidInput();
    error InvalidLink();
    error InvalidOwner();
    error InvalidSignature();

    event LinkCreated(bytes32 indexed linkId, address indexed sender, uint256 amount, uint40 expiresAt);
    event LinkClaimed(bytes32 indexed linkId, address indexed recipient, uint256 amount);
    event LinkRevoked(bytes32 indexed linkId, address indexed sender, uint256 amount);
    event LinkSwept(bytes32 indexed linkId, address indexed sender, uint256 amount);

    /**
     * @param usdc The USDC token address. Set once and immutable.
     */
    constructor(IERC20 usdc) EIP712("MozaikLinks", "1") {
        if (address(usdc) == address(0)) revert InvalidInput();

        USDC = usdc;
    }

    /**
     * @notice Lock USDC into the escrow under a new link.
     * @param linkId    Caller-supplied unique identifier (must be non-zero, never reused).
     * @param claimSigner  Address of the ephemeral keypair whose private key gates claims.
     * @param amount    USDC amount in token-minor units (6 decimals).
     * @param expiresAt Unix timestamp after which claims revert and sweeping is permitted.
     */
    function create(bytes32 linkId, address claimSigner, uint256 amount, uint40 expiresAt) external nonReentrant {
        // Sanity checks
        if (linkId == bytes32(0)) revert InvalidInput();
        if (claimSigner == address(0)) revert InvalidInput();
        if (amount == 0) revert InvalidInput();
        if (expiresAt <= block.timestamp) revert InvalidInput();

        // Make sure the link ID is unique
        if (_links[linkId].status != Status.None) revert InvalidLink();

        // Sanity check
        // Enforce exact amount for the transfer (USDC)
        uint256 balanceBefore = USDC.balanceOf(address(this));
        USDC.safeTransferFrom(msg.sender, address(this), amount);

        if (USDC.balanceOf(address(this)) - balanceBefore != amount) revert InvalidInput();

        _links[linkId] = Link({
            sender: msg.sender, expiresAt: expiresAt, status: Status.Active, claimSigner: claimSigner, amount: amount
        });

        emit LinkCreated(linkId, msg.sender, amount, expiresAt);
    }

    /**
     * @notice Claim funds for an active, non-expired link. Funds are sent to the caller;
     *         the signature must be produced over (linkId, msg.sender) by the link's
     *         ephemeral private key. This binds the claim to the caller's address,
     *         eliminating mempool front-running of the secret.
     * @param linkId    The link identifier.
     * @param signature ECDSA signature by the link's ephemeral private key (`claimSigner`)
     *                  over the EIP-712 typed data Claim(linkId, recipient).
     */
    function claim(bytes32 linkId, bytes calldata signature) external nonReentrant {
        Link storage link = _links[linkId];

        if (link.status != Status.Active) revert InvalidLink();
        if (block.timestamp >= link.expiresAt) revert InvalidLink();

        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(CLAIM_TYPEHASH, linkId, msg.sender)));

        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || signer != link.claimSigner) revert InvalidSignature();

        uint256 amount = link.amount;
        link.status = Status.Claimed;

        USDC.safeTransfer(msg.sender, amount);

        emit LinkClaimed(linkId, msg.sender, amount);
    }

    /**
     * @notice Cancel an active link before expiry. Sender-only.
     * @dev    Past expiry, the only path to reclaim funds is `sweepExpired`. This split
     *         gives clean non-overlapping terminal states: Revoked vs Swept.
     */
    function revoke(bytes32 linkId) external nonReentrant {
        Link storage link = _links[linkId];

        if (link.status != Status.Active) revert InvalidLink();
        if (link.sender != msg.sender) revert InvalidOwner();
        if (block.timestamp >= link.expiresAt) revert InvalidLink();

        uint256 amount = link.amount;
        link.status = Status.Revoked;

        USDC.safeTransfer(link.sender, amount);

        emit LinkRevoked(linkId, link.sender, amount);
    }

    /**
     * @notice Reclaim funds for an expired, never-claimed link. Permissionless.
     * @dev    Funds always return to the original sender, regardless of caller. Anyone
     *         can pay the gas to recycle dust links - sender, sender's bot, or a third
     *         party.
     */
    function sweepExpired(bytes32 linkId) external nonReentrant {
        Link storage link = _links[linkId];

        if (link.status != Status.Active) revert InvalidLink();
        if (block.timestamp < link.expiresAt) revert InvalidLink();

        uint256 amount = link.amount;
        link.status = Status.Swept;

        USDC.safeTransfer(link.sender, amount);

        emit LinkSwept(linkId, link.sender, amount);
    }

    /**
     * @notice Read the full Link record. Returns a zero-initialized Link if not found
     *         (status will be Status.None).
     */
    function getLink(bytes32 linkId) external view returns (Link memory) {
        return _links[linkId];
    }
}
