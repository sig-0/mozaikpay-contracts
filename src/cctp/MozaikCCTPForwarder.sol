// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IMessageHandlerV2} from "./IMessageHandlerV2.sol";
import {ITokenMessengerV2} from "./ITokenMessengerV2.sol";

/**
 * @title MozaikCCTPForwarder
 * @notice Deposit address that moves USDC only to its account on Base.
 * @dev Each account gets an ERC-1167 clone whose only immutable argument is the account address. The clone has
 *      the same address on every EVM chain where this implementation and its factory have the same addresses.
 *      Value leaves a forwarder in three ways only:
 *      - forward() on a chain other than Base burns USDC through CCTP V2 with the account as mint recipient.
 *      - forward() on Base transfers USDC to the account.
 *      - The account authorizes a rescue, with a finalized CCTP message from Base or a direct call on Base.
 *      The contract has no owner, no storage and no upgrade path.
 */
contract MozaikCCTPForwarder is IMessageHandlerV2 {
    using SafeERC20 for IERC20;

    /**
     * @notice Upper bound on `maxFee` in forward(), in basis points of the amount.
     */
    uint256 public constant MAX_FEE_BPS = 20;

    /**
     * @dev CCTP finality thresholds. A message attested at 2000 or more is finalized.
     */
    uint32 internal constant FINALITY_FAST = 1000;
    uint32 internal constant FINALITY_STANDARD = 2000;

    /**
     * @notice Circle's CCTP V2 TokenMessengerV2.
     */
    ITokenMessengerV2 public immutable TOKEN_MESSENGER;

    /**
     * @dev CCTP domain of Base.
     */
    uint32 internal constant BASE_DOMAIN = 6;

    /**
     * @notice Circle's USDC on Base.
     */
    address public immutable BASE_USDC;

    /**
     * @notice Chain id of Base.
     */
    uint256 public immutable BASE_CHAIN_ID;

    /**
     * @dev Address of this implementation. Calls that reach it directly, not through a clone, revert.
     */
    address private immutable SELF;

    /**
     * @notice Emitted when forward() burns USDC for the account or, on Base, transfers it to the account.
     * @param amount               The USDC amount, in token-minor units.
     * @param maxFee               The maximum CCTP fee the burn allows. Always zero on Base.
     * @param minFinalityThreshold The CCTP finality threshold the caller passed.
     */
    event Forwarded(uint256 amount, uint256 maxFee, uint32 minFinalityThreshold);

    /**
     * @notice Emitted when the account moves a token out of the forwarder.
     * @param token  The token that was sent, or the zero address for the native coin.
     * @param to     The recipient.
     * @param amount The amount that was sent.
     */
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Thrown when an argument is not valid.
     */
    error InvalidInput();

    /**
     * @notice Thrown when the implementation is called directly.
     */
    error NotClone();

    /**
     * @notice Thrown when the call is not supported on this chain.
     */
    error UnsupportedChain();

    /**
     * @notice Thrown when a caller is not authorized to invoke a function.
     * @param caller The address that attempted the call.
     */
    error UnauthorizedCaller(address caller);

    /**
     * @notice Thrown when a CCTP message does not authorize a rescue.
     */
    error InvalidMessage();

    /**
     * @param tokenMessenger Circle's TokenMessengerV2, the same address on every chain of one environment.
     * @param baseUsdc       Circle's USDC on Base.
     * @param baseChainId    Chain id of Base.
     */
    constructor(ITokenMessengerV2 tokenMessenger, address baseUsdc, uint256 baseChainId) {
        if (address(tokenMessenger) == address(0) || baseUsdc == address(0) || baseChainId == 0) {
            revert InvalidInput();
        }

        TOKEN_MESSENGER = tokenMessenger;
        BASE_USDC = baseUsdc;
        BASE_CHAIN_ID = baseChainId;
        SELF = address(this);
    }

    /**
     * @notice The account on Base that this forwarder serves.
     */
    function account() external view returns (address) {
        return _account();
    }

    /**
     * @notice Moves up to `amount` of USDC toward the account. Callable by anyone.
     * @dev Moves the lesser of `amount` and the balance, so an earlier forward cannot make this one revert. On
     *      Base, transfers the USDC to the account and requires `maxFee` to be zero. On any other chain, burns it
     *      through CCTP V2 with the account as mint recipient on Base, no destination caller and no hook. The
     *      threshold must be 1000 (Fast) or 2000 (Standard), and `maxFee` is lowered to MAX_FEE_BPS of the moved
     *      amount when above it.
     * @param amount               Most USDC to move, in token-minor units.
     * @param maxFee               Maximum CCTP fee, deducted from the mint on Base.
     * @param minFinalityThreshold CCTP finality threshold. Ignored on Base.
     */
    function forward(uint256 amount, uint256 maxFee, uint32 minFinalityThreshold) external {
        address acct = _account();

        if (block.chainid == BASE_CHAIN_ID) {
            if (maxFee != 0) revert InvalidInput();

            amount = _available(BASE_USDC, amount);
            IERC20(BASE_USDC).safeTransfer(acct, amount);
        } else {
            if (minFinalityThreshold != FINALITY_FAST && minFinalityThreshold != FINALITY_STANDARD) {
                revert InvalidInput();
            }

            address usdc = TOKEN_MESSENGER.localMinter().getLocalToken(BASE_DOMAIN, _toBytes32(BASE_USDC));
            if (usdc == address(0)) revert UnsupportedChain();

            amount = _available(usdc, amount);
            uint256 feeCap = amount * MAX_FEE_BPS / 10_000;
            if (maxFee > feeCap) maxFee = feeCap;

            IERC20(usdc).forceApprove(address(TOKEN_MESSENGER), amount);
            TOKEN_MESSENGER.depositForBurn(
                amount, BASE_DOMAIN, _toBytes32(acct), usdc, bytes32(0), maxFee, minFinalityThreshold
            );
        }

        emit Forwarded(amount, maxFee, minFinalityThreshold);
    }

    /**
     * @notice Sends `amount` of `token` (the zero address for the native coin) to `to`.
     * @dev Callable only by the account, and only on Base. On other chains, the account authorizes a rescue with
     *      a finalized CCTP message instead.
     * @param token  The token to send, or the zero address for the native coin.
     * @param to     The recipient.
     * @param amount The amount to send.
     */
    function rescue(address token, address to, uint256 amount) external {
        address acct = _account();
        if (msg.sender != acct) revert UnauthorizedCaller(msg.sender);
        if (block.chainid != BASE_CHAIN_ID) revert UnsupportedChain();

        _send(token, to, amount);
    }

    /**
     * @notice Executes a rescue that the account sent from Base as a finalized CCTP message.
     * @dev Callable only by the local MessageTransmitterV2. The message must come from the account on domain 6
     *      (Base), be attested at the finalized threshold or above, and carry abi.encode(address token, address to,
     *      uint256 amount, uint256 deadline). It reverts after `deadline`, a timestamp in seconds, so a message
     *      whose delivery failed cannot be replayed later. Until then, anyone can relay it again. Sends the native
     *      coin when `token` is the zero address.
     * @param sourceDomain              CCTP domain of the chain that sent the message.
     * @param sender                    Sender of the message on the source chain, left-padded to 32 bytes.
     * @param finalityThresholdExecuted The finality threshold at which the message was attested.
     * @param messageBody               The encoded rescue, abi.encode(address token, address to, uint256 amount,
     *                                  uint256 deadline).
     * @return Always true. Every failed check reverts.
     */
    function handleReceiveFinalizedMessage(
        uint32 sourceDomain,
        bytes32 sender,
        uint32 finalityThresholdExecuted,
        bytes calldata messageBody
    ) external override returns (bool) {
        if (msg.sender != TOKEN_MESSENGER.localMessageTransmitter()) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (sourceDomain != BASE_DOMAIN || sender != _toBytes32(_account())) revert InvalidMessage();
        if (finalityThresholdExecuted < FINALITY_STANDARD) revert InvalidMessage();

        (address token, address to, uint256 amount, uint256 deadline) =
            abi.decode(messageBody, (address, address, uint256, uint256));
        if (block.timestamp > deadline) revert InvalidMessage();

        _send(token, to, amount);

        return true;
    }

    /**
     * @notice Always reverts. Messages attested below the finalized threshold never authorize a rescue.
     */
    function handleReceiveUnfinalizedMessage(uint32, bytes32, uint32, bytes calldata)
        external
        pure
        override
        returns (bool)
    {
        revert InvalidMessage();
    }

    /**
     * @dev Reverts on the implementation, where the clone argument does not exist.
     */
    function _account() private view returns (address) {
        if (address(this) == SELF) revert NotClone();

        return address(bytes20(Clones.fetchCloneArgs(address(this))));
    }

    /**
     * @dev The lesser of `amount` and this forwarder's balance of `token`. Reverts when that is zero.
     */
    function _available(address token, uint256 amount) private view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (amount > balance) amount = balance;
        if (amount == 0) revert InvalidInput();

        return amount;
    }

    /**
     * @dev An address left-padded to 32 bytes, the form CCTP uses for addresses.
     */
    function _toBytes32(address addr) private pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    /**
     * @dev Sends a rescue. Shared by rescue and handleReceiveFinalizedMessage, which check the authority first.
     */
    function _send(address token, address to, uint256 amount) private {
        if (token == address(0)) {
            Address.sendValue(payable(to), amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }

        emit Rescued(token, to, amount);
    }
}
