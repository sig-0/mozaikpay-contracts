// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MozaikAccount} from "../../src/account/MozaikAccount.sol";

contract AccountEchidna {
    address internal immutable SPENDING_SIGNER;
    MozaikAccount internal account;
    EntryPoint internal entryPoint;

    constructor() payable {
        SPENDING_SIGNER = address(0x1234567890123456789012345678901234567890);
        address recoverySigner = address(0xdeaDDeADDEaDdeaDdEAddEADDEAdDeadDEADDEaD);

        entryPoint = new EntryPoint();

        MozaikAccount impl = new MozaikAccount();
        bytes memory initData = abi.encodeCall(MozaikAccount.initialize, (SPENDING_SIGNER, recoverySigner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        account = MozaikAccount(payable(address(proxy)));
    }

    function echidna_non_owner_cannot_execute() external returns (bool) {
        (bool ok,) = address(account).call(abi.encodeCall(account.execute, (address(this), 0, "")));
        return !ok;
    }

    function echidna_spending_signer_set() external view returns (bool) {
        return account.spendingSigner() == SPENDING_SIGNER;
    }

    function tryExecute(address target, uint256 value, bytes calldata data) external {
        account.execute(target, value, data);
    }

    receive() external payable {}
}
