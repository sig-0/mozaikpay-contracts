// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MozaikAccount} from "../../src/account/MozaikAccount.sol";

contract AccountEchidna {
    address internal immutable OWNER;
    MozaikAccount internal account;
    EntryPoint internal entryPoint;

    address internal constant ENTRY_POINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;

    constructor() payable {
        // A fixed owner address that Echidna won't control
        OWNER = address(0x1234567890123456789012345678901234567890);

        entryPoint = new EntryPoint();

        MozaikAccount impl = new MozaikAccount();
        bytes memory initData = abi.encodeCall(MozaikAccount.initialize, (OWNER));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        account = MozaikAccount(payable(address(proxy)));
    }

    function echidna_non_owner_cannot_execute() external returns (bool) {
        // Any call to execute from this contract (which is not the owner or EntryPoint) must revert
        (bool ok,) = address(account).call(abi.encodeCall(account.execute, (address(this), 0, "")));

        return !ok; // must revert
    }

    function echidna_bad_signature_always_fails() external view returns (bool) {
        // A UserOp signed with zero bytes must return SIG_VALIDATION_FAILED
        PackedUserOperation memory op;
        op.sender = address(account);
        op.signature = new bytes(65); // 65 zero bytes

        // validateUserOp must be called from the EntryPoint. We can't easily test this
        // without the real EntryPoint at the hardcoded address.
        // Instead, test isValidSignature which has no entryPoint guard
        bytes32 hash = keccak256("arbitrary");
        bytes4 result = account.isValidSignature(hash, new bytes(65));

        return result == bytes4(0xffffffff); // invalid sig must return fallback value
    }

    function echidna_owner_is_always_signer() external view returns (bool) {
        return account.signers(OWNER);
    }

    function tryExecute(address target, uint256 value, bytes calldata data) external {
        // This will revert since msg.sender (Echidna) is not the owner or EntryPoint
        account.execute(target, value, data);
    }

    receive() external payable {}
}
