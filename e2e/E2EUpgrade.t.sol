// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MozaikAccount} from "../src/account/MozaikAccount.sol";
import {MozaikAccountFactory} from "../src/account/MozaikAccountFactory.sol";
import {E2EBase} from "./E2EBase.t.sol";

/// @dev V2 mock used in upgrade tests. Adds a version() getter.
contract MockMozaikAccountV2 is MozaikAccount {
    function version() external pure returns (uint256) {
        return 2;
    }
}

interface IVersionedAccount {
    function version() external view returns (uint256);
}

/// @title E2E: UUPS upgrades, including across a fresh factory's implementation.
contract E2EUpgradeTest is E2EBase {
    function test_Upgrade_ToNewImplementation() public {
        AccountFixture memory a = _createAccount("acct");

        MockMozaikAccountV2 v2Impl = new MockMozaikAccountV2();
        _sendRecoveryOp(a.addr, a.recoveryKey, abi.encodeCall(a.account.upgradeToAndCall, (address(v2Impl), "")));

        assertEq(IVersionedAccount(a.addr).version(), 2, "upgrade to V2 failed");
        assertEq(a.account.spendingSigner(), a.spendingSigner, "spending signer lost after upgrade");
        assertEq(a.account.recoverySigner(), a.recoverySigner, "recovery signer lost after upgrade");
    }

    function test_Upgrade_CrossFactoryVersion() public {
        AccountFixture memory a = _createAccount("orig");

        // A fresh factory ships its own account implementation.
        MozaikAccountFactory newFactory = new MozaikAccountFactory();
        MozaikAccount newImpl = newFactory.ACCOUNT_IMPLEMENTATION();
        assertTrue(address(newImpl) != address(factory.ACCOUNT_IMPLEMENTATION()), "new impl should differ");

        // The new factory can create accounts through the real EntryPoint.
        AccountFixture memory b = _createAccount(newFactory, "cross");
        assertTrue(b.addr.code.length > 0, "new factory account not deployed");
        assertEq(b.account.spendingSigner(), b.spendingSigner, "wrong spending signer on cross account");

        // Upgrade the original account to the new factory's implementation.
        _sendRecoveryOp(a.addr, a.recoveryKey, abi.encodeCall(a.account.upgradeToAndCall, (address(newImpl), "")));

        assertEq(a.account.spendingSigner(), a.spendingSigner, "spending signer lost after cross-version upgrade");
        assertEq(a.account.recoverySigner(), a.recoverySigner, "recovery signer lost after cross-version upgrade");
    }
}
