// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";

import {E2EBase} from "./E2EBase.t.sol";

/// @title E2E: recovery-key rotation of the spending and recovery signers.
contract E2ERecoveryTest is E2EBase {
    function test_Recovery_RotatesSpendingSigner() public {
        AccountFixture memory a = _createAccount("acct");

        ERC20Mock usdc = new ERC20Mock();
        usdc.mint(a.addr, 1000e6);
        address recipient = makeAddr("recipient");

        (address newSpendingSigner, uint256 newSpendingKey) = makeAddrAndKey("newSpendingSigner");

        _sendRecoveryOp(a.addr, a.recoveryKey, abi.encodeCall(a.account.rotateSpendingSigner, (newSpendingSigner)));
        assertEq(a.account.spendingSigner(), newSpendingSigner, "spending signer not rotated");

        // The rotated-in key can spend.
        _sendSpendingOp(
            a.addr,
            newSpendingKey,
            abi.encodeCall(BaseAccount.execute, (address(usdc), 0, abi.encodeCall(usdc.transfer, (recipient, 50e6))))
        );
        assertEq(usdc.balanceOf(recipient), 50e6, "new spending key transfer failed");
    }

    function test_Recovery_RotatesRecoverySigner() public {
        AccountFixture memory a = _createAccount("acct");

        (address newRecoverySigner,) = makeAddrAndKey("newRecoverySigner");

        _sendRecoveryOp(a.addr, a.recoveryKey, abi.encodeCall(a.account.rotateRecoverySigner, (newRecoverySigner)));
        assertEq(a.account.recoverySigner(), newRecoverySigner, "recovery signer not rotated");
    }
}
