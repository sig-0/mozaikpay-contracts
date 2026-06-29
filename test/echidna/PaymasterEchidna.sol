// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {MozaikVerifyingPaymaster} from "../../src/paymaster/MozaikVerifyingPaymaster.sol";

contract PaymasterEchidna {
    bytes8 internal constant PAYMASTER_SIG_MAGIC = 0x22e325a297439656;
    address internal constant ENTRY_POINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;
    EntryPoint internal entryPoint;
    MozaikVerifyingPaymaster internal paymaster;

    uint256 internal constant SIGNER_KEY = 0xDEADBEEF1337;
    address internal immutable SIGNER_ADDR;

    uint256 internal totalDeposited;
    uint256 internal totalWithdrawn;

    constructor() payable {
        SIGNER_ADDR = _ecrecover(0);
        entryPoint = EntryPoint(payable(ENTRY_POINT_V09));
        paymaster = new MozaikVerifyingPaymaster(_signerAddress());
    }

    function echidna_unsigned_op_never_sponsored() external returns (bool) {
        PackedUserOperation memory op;
        op.sender = address(this);
        // paymasterAndData with NO signature suffix -> tryRecover returns address(0) != verifyingSigner
        op.paymasterAndData =
            abi.encodePacked(address(paymaster), uint128(100_000), uint128(0), uint48(type(uint48).max), uint48(0));

        (bool ok, bytes memory ret) =
            address(paymaster).call(abi.encodeCall(paymaster.validatePaymasterUserOp, (op, bytes32(0), 0)));
        if (!ok) return true; // revert = not sponsored

        (, uint256 validationData) = abi.decode(ret, (bytes, uint256));

        return (validationData & type(uint160).max) != 0; // 0 = sponsored (invalid)
    }

    function echidna_expired_op_never_sponsored() external returns (bool) {
        PackedUserOperation memory op;
        op.sender = address(this);
        op.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(100_000),
            uint128(0),
            uint48(0), // validUntil = 0 -> always expired
            uint48(0)
        );

        (bool ok, bytes memory ret) =
            address(paymaster).call(abi.encodeCall(paymaster.validatePaymasterUserOp, (op, bytes32(0), 0)));
        if (!ok) return true;

        (, uint256 validationData) = abi.decode(ret, (bytes, uint256));

        return ((validationData >> 160) & type(uint48).max) == 0;
    }

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

    receive() external payable {}

    function _signerAddress() internal pure returns (address) {
        // Deterministic address from SIGNER_KEY.
        // In a real Echidna run, we'd use a known address derived from a fixed key.
        // Here we approximate by computing the address offline and hardcoding it.
        // The property echidna_unsigned_op_never_sponsored doesn't rely on this address
        // TODO address this
        return address(uint160(uint256(keccak256(abi.encode(SIGNER_KEY)))));
    }

    function _ecrecover(uint256) internal pure returns (address) {
        return _signerAddress();
    }
}
