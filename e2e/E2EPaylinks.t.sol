// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";

import {MozaikPaylinks} from "../src/paylinks/MozaikPaylinks.sol";
import {E2EBase} from "./E2EBase.t.sol";

/// @title E2E: sponsored paylink creation from a smart account, claimed by an EOA.
contract E2EPaylinksTest is E2EBase {
    function test_Paylink_SponsoredCreateAndEOAClaim() public {
        AccountFixture memory a = _createAccount("acct");

        ERC20Mock usdc = new ERC20Mock();
        usdc.mint(a.addr, 1000e6);

        MozaikPaylinks links = new MozaikPaylinks(IERC20(address(usdc)));

        (address linkPubKey, uint256 linkPrivKey) = makeAddrAndKey("paylinkEphemeralKey");
        uint256 linkAmount = 100e6;
        uint64 linkExpiry = uint64(block.timestamp + 1 days);

        // Approve the escrow to pull USDC from the smart account (sponsored UserOp).
        _sendSpendingOp(
            a.addr,
            a.spendingKey,
            abi.encodeCall(
                BaseAccount.execute,
                (address(usdc), 0, abi.encodeCall(usdc.approve, (address(links), type(uint256).max)))
            )
        );

        // Create the paylink (sponsored UserOp). Account loses linkAmount USDC into escrow.
        _sendSpendingOp(
            a.addr,
            a.spendingKey,
            abi.encodeCall(
                BaseAccount.execute,
                (address(links), 0, abi.encodeCall(links.create, (linkPubKey, linkAmount, linkExpiry)))
            )
        );

        assertEq(usdc.balanceOf(address(links)), linkAmount, "link funds not escrowed");
        assertEq(usdc.balanceOf(a.addr), 900e6, "account balance after create incorrect");

        // Recipient claims via direct EOA call (no Mozaik account required).
        address paylinkRecipient = makeAddr("paylinkRecipient");

        bytes32 linksDomainSep = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("MozaikPaylinks"),
                keccak256("1"),
                block.chainid,
                address(links)
            )
        );
        bytes32 claimStructHash = keccak256(
            abi.encode(keccak256("Claim(address claimSigner,address recipient)"), linkPubKey, paylinkRecipient)
        );
        bytes32 claimDigest = keccak256(abi.encodePacked("\x19\x01", linksDomainSep, claimStructHash));

        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(linkPrivKey, claimDigest);
        bytes memory claimSig = abi.encodePacked(cr, cs, cv);

        vm.prank(paylinkRecipient);
        links.claim(linkPubKey, claimSig);

        assertEq(usdc.balanceOf(paylinkRecipient), linkAmount, "recipient didn't get paylink funds");
        assertEq(usdc.balanceOf(address(links)), 0, "escrow not drained");
    }
}
