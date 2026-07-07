// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {MozaikVerifyingPaymaster} from "../../src/paymaster/MozaikVerifyingPaymaster.sol";

/// @notice Test subclass that reaches the sponsor-signature validation without the EntryPoint
///         caller gate. BasePaymaster.validatePaymasterUserOp requires msg.sender to be the
///         EntryPoint before delegating to _validatePaymasterUserOp; the harness is not the
///         EntryPoint, so it calls the inner logic directly. Only that inherited gate is
///         skipped. The signature verification under test runs unchanged.
contract HarnessPaymaster is MozaikVerifyingPaymaster {
    constructor(address sponsor_) MozaikVerifyingPaymaster(sponsor_) {}

    function exposedValidate(PackedUserOperation calldata op) external view returns (uint256 validationData) {
        (, validationData) = _validatePaymasterUserOp(op, bytes32(0), 0);
    }
}

/// @notice Echidna fuzz target for MozaikVerifyingPaymaster.
/// @dev Echidna cannot sign, but the sponsor digest binds only to the paymaster address, the
///      chain id, and the operation fields, all of which can be pinned. So a single fixed,
///      canonical secp256k1 signature is chosen up front; the address it recovers to (over the
///      pinned operation's digest) is installed as the sponsor at deploy time. That makes the
///      signature a genuine sponsor approval for the pinned operation, letting the harness
///      exercise both the accept and reject paths of validation with a real ECDSA signer.
contract PaymasterEchidna {
    address internal constant ENTRY_POINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;

    /// @dev keccak256("PaymasterSignature")[:8]; marks the signature suffix in paymasterAndData.
    bytes8 internal constant PAYMASTER_SIG_MAGIC = 0x22e325a297439656;

    /// @dev A fixed canonical signature (low-s, v in {27, 28}). r and v describe an on-curve
    ///      point, so ecrecover yields a valid address for any digest; that recovered address
    ///      becomes the sponsor, so this is a real approval over the pinned operation below.
    bytes32 internal constant SIG_R = 0xe7c93726a865578504442b1a6827f676e0ed74bdff2be3960d1e253bbcfc4462;
    bytes32 internal constant SIG_S = 0x6aa772b878bc912bdbb33a0014ec507c4b3896ea85aa914b74dee9b7ac3e56da;
    uint8 internal constant SIG_V = 0x1c;

    /// @dev Every field the sponsor digest binds to is pinned so the deploy-time digest (used
    ///      to derive the sponsor) matches the digest the paymaster recomputes at validation.
    ///      SPONSORED_SENDER is an arbitrary fixed account identifier, not a signer.
    address internal constant SPONSORED_SENDER = 0x000000000000000000000000000000000000c0DE;
    uint48 internal constant VALID_UNTIL = type(uint48).max;
    uint48 internal constant VALID_AFTER = 0;

    EntryPoint internal entryPoint;
    HarnessPaymaster internal paymaster;

    uint256 internal totalDeposited;
    uint256 internal totalWithdrawn;

    constructor() payable {
        entryPoint = EntryPoint(payable(ENTRY_POINT_V09));

        // Deploy with a throwaway sponsor first: the digest binds to the paymaster address,
        // which is only known after deployment. Recover the intended sponsor from the fixed
        // signature over that digest, then install it.
        paymaster = new HarnessPaymaster(address(0xdead));

        address recovered = ecrecover(_pinnedDigest(), SIG_V, SIG_R, SIG_S);
        require(recovered != address(0), "sig vector must recover");

        paymaster.setSponsor(recovered);
    }

    receive() external payable {}

    /// @notice A genuine sponsor approval for the pinned operation validates (sigFailed == false).
    function echidna_valid_signed_op_is_sponsored() external view returns (bool) {
        uint256 validationData = paymaster.exposedValidate(_signedOp());
        return (validationData & type(uint160).max) == 0;
    }

    /// @notice A valid approval carries its time window through into validationData, so the
    ///         EntryPoint can enforce expiry on it.
    function echidna_signed_window_propagated() external view returns (bool) {
        uint256 validationData = paymaster.exposedValidate(_signedOp());
        return ((validationData >> 160) & type(uint48).max) == VALID_UNTIL
            && ((validationData >> 208) & type(uint48).max) == VALID_AFTER;
    }

    /// @notice The same operation with the signature suffix stripped is never sponsored.
    function echidna_unsigned_op_never_sponsored() external view returns (bool) {
        uint256 validationData = paymaster.exposedValidate(_unsignedOp());
        return (validationData & type(uint160).max) != 0;
    }

    /// @notice Flipping a single bit of the approval signature breaks sponsorship.
    function echidna_tampered_signature_never_sponsored() external view returns (bool) {
        uint256 validationData = paymaster.exposedValidate(_tamperedOp());
        return (validationData & type(uint160).max) != 0;
    }

    /// @notice The EntryPoint deposit never drops below net deposits minus withdrawals.
    function echidna_deposit_never_negative() external view returns (bool) {
        return entryPoint.balanceOf(address(paymaster)) + totalWithdrawn >= totalDeposited;
    }

    function deposit(uint96 amount) external {
        if (amount == 0) return;

        paymaster.deposit{value: uint256(amount)}();
        totalDeposited += uint256(amount);
    }

    function withdraw(uint96 amount) external {
        uint256 balance = entryPoint.balanceOf(address(paymaster));

        if (amount == 0 || balance == 0) return;

        uint256 a = uint256(amount) > balance ? balance : uint256(amount);

        paymaster.withdrawTo(payable(address(this)), a);
        totalWithdrawn += a;
    }

    /// @dev Mirror of the paymaster's approval digest over the pinned operation.
    function _pinnedDigest() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(paymaster),
                block.chainid,
                SPONSORED_SENDER,
                uint256(0), // nonce
                keccak256(""), // initCode hash
                keccak256(""), // callData hash
                bytes32(0), // accountGasLimits
                uint256(0), // preVerificationGas
                bytes32(0), // gasFees
                VALID_UNTIL,
                VALID_AFTER
            )
        );
    }

    function _signedOp() internal view returns (PackedUserOperation memory op) {
        op.sender = SPONSORED_SENDER;
        op.paymasterAndData = _paymasterAndData(abi.encodePacked(SIG_R, SIG_S, SIG_V));
    }

    function _tamperedOp() internal view returns (PackedUserOperation memory op) {
        op.sender = SPONSORED_SENDER;
        // Flip the low bit of s: still well-formed and low-s, but recovers a different signer.
        op.paymasterAndData = _paymasterAndData(abi.encodePacked(SIG_R, bytes32(uint256(SIG_S) ^ 1), SIG_V));
    }

    function _unsignedOp() internal view returns (PackedUserOperation memory op) {
        op.sender = SPONSORED_SENDER;
        // Header and time window only, no signature suffix, so the recovered signature is empty.
        op.paymasterAndData =
            abi.encodePacked(address(paymaster), uint128(100_000), uint128(0), VALID_UNTIL, VALID_AFTER);
    }

    function _paymasterAndData(bytes memory sig) internal view returns (bytes memory) {
        return abi.encodePacked(
            address(paymaster),
            uint128(100_000), // paymasterVerificationGasLimit
            uint128(0), // paymasterPostOpGasLimit
            VALID_UNTIL,
            VALID_AFTER,
            sig,
            uint16(sig.length),
            PAYMASTER_SIG_MAGIC
        );
    }
}
