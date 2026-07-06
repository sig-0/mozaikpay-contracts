// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title MozaikPaylinks
 * @notice Non-upgradeable USDC escrow for MozaikPay payment links.
 * @dev Lifecycle:
 *      - create(): sender deposits USDC and commits to an ephemeral keypair's address
 *        (`claimSigner`) plus an expiry timestamp. The claimSigner doubles as the
 *        link's unique identifier.
 *      - claim(): caller submits an EIP-712 signature, generated off-chain with the
 *        ephemeral private key (the "secret" embedded in the link URL), over
 *        (claimSigner, msg.sender). The contract recovers the signer and matches it
 *        against the mapping key; on success, USDC is sent to msg.sender. Binding the
 *        signed payload to the caller's address eliminates secret-extraction
 *        front-running: a mempool watcher who copies the calldata cannot redirect
 *        the funds to themselves because the signature is over the original
 *        claimer's address.
 *      - reclaim(): unified recovery path. Pre-expiry the sender alone can call to
 *        cancel an active link; at or after expiry anyone may call to recycle the
 *        escrow. Funds always return to the original sender.
 *
 */
contract MozaikPaylinks is ReentrancyGuardTransient, EIP712 {
    using SafeERC20 for IERC20;

    /// @dev Per-link state machine. Transitions are monotonic; never reversed.
    enum Status {
        None,
        Active,
        Claimed,
        Reclaimed
    }

    /// @dev Slot-packed: sender(20) + expiresAt(8) + status(1) fit in slot 0;
    /// amount occupies its own slot. 2 slots per link.
    struct Link {
        address sender;
        uint64 expiresAt;
        Status status;
        uint256 amount;
    }

    /// @notice The USDC token address. Set at deployment, never changes.
    IERC20 public immutable USDC;

    mapping(address claimSigner => Link) private _links;

    /// @dev EIP-712 typed-data hash for claim authorization.
    bytes32 private constant CLAIM_TYPEHASH = keccak256("Claim(address claimSigner,address recipient)");

    error InvalidInput();
    error InvalidLink();
    error InvalidOwner();
    error InvalidSignature();

    event LinkCreated(address indexed claimSigner, address indexed sender, uint256 amount, uint64 expiresAt);
    event LinkClaimed(address indexed claimSigner, address indexed recipient, uint256 amount);
    event LinkReclaimed(address indexed claimSigner, address indexed sender, uint256 amount);

    /**
     * @param usdc The USDC token address. Set once and immutable.
     */
    constructor(IERC20 usdc) EIP712("MozaikPaylinks", "1") {
        if (address(usdc) == address(0)) revert InvalidInput();

        USDC = usdc;
    }

    /**
     * @notice Lock USDC into the escrow under a new link.
     * @param claimSigner Address of the ephemeral keypair whose private key gates claims.
     *                    Doubles as the link's unique identifier.
     * @param amount      USDC amount in token-minor units (6 decimals).
     * @param expiresAt   Unix timestamp after which claims revert and sweeping is permitted.
     */
    function create(address claimSigner, uint256 amount, uint64 expiresAt) external nonReentrant {
        // Sanity checks
        if (claimSigner == address(0)) revert InvalidInput();
        if (amount == 0) revert InvalidInput();
        if (expiresAt <= block.timestamp) revert InvalidInput();

        // Make sure the claim signer is unique
        if (_links[claimSigner].status != Status.None) revert InvalidLink();

        // Reject fee-on-transfer or rebasing tokens by requiring the balance delta to match `amount` exactly.
        uint256 balanceBefore = USDC.balanceOf(address(this));
        USDC.safeTransferFrom(msg.sender, address(this), amount);

        if (USDC.balanceOf(address(this)) - balanceBefore != amount) revert InvalidInput();

        _links[claimSigner] = Link({sender: msg.sender, expiresAt: expiresAt, status: Status.Active, amount: amount});

        emit LinkCreated(claimSigner, msg.sender, amount, expiresAt);
    }

    /**
     * @notice Claim funds for an active, non-expired link. Funds are sent to the caller;
     *         the signature must be produced over (claimSigner, msg.sender) by the link's
     *         ephemeral private key. This binds the claim to the caller's address,
     *         eliminating mempool front-running of the secret.
     * @param claimSigner The link identifier (ephemeral keypair address).
     * @param signature   ECDSA signature by the link's ephemeral private key over the
     *                    EIP-712 typed data Claim(claimSigner, recipient).
     */
    function claim(address claimSigner, bytes calldata signature) external nonReentrant {
        Link storage link = _links[claimSigner];

        if (link.status != Status.Active) revert InvalidLink();
        if (block.timestamp >= link.expiresAt) revert InvalidLink();

        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(CLAIM_TYPEHASH, claimSigner, msg.sender)));

        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || signer != claimSigner) revert InvalidSignature();

        uint256 amount = link.amount;
        link.status = Status.Claimed;

        USDC.safeTransfer(msg.sender, amount);

        emit LinkClaimed(claimSigner, msg.sender, amount);
    }

    /**
     * @notice Return an active link's escrow to the original sender.
     * @dev    Pre-expiry the caller must be the link's sender (cancel). At or after
     *         expiry the call is permissionless so anyone (sender, sender's bot, or
     *         a third party) can pay the gas to recycle dust. Funds always return to
     *         the original sender, regardless of caller.
     */
    function reclaim(address claimSigner) external nonReentrant {
        Link storage link = _links[claimSigner];

        if (link.status != Status.Active) revert InvalidLink();

        if (block.timestamp < link.expiresAt && link.sender != msg.sender) {
            revert InvalidOwner();
        }

        uint256 amount = link.amount;
        link.status = Status.Reclaimed;

        USDC.safeTransfer(link.sender, amount);

        emit LinkReclaimed(claimSigner, link.sender, amount);
    }

    /**
     * @notice Read the full Link record. Returns a zero-initialized Link if not found
     *         (status will be Status.None).
     */
    function getLink(address claimSigner) external view returns (Link memory) {
        return _links[claimSigner];
    }
}
