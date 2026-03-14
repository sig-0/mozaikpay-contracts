// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {MozaikAccountFactory} from "../src/account/MozaikAccountFactory.sol";
import {MozaikVerifyingPaymaster} from "../src/paymaster/MozaikVerifyingPaymaster.sol";

contract VerifyDeployScript is Script {
    address internal constant ENTRY_POINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;

    function run() external view {
        address factoryAddr = vm.envAddress("FACTORY_ADDRESS");
        address paymasterAddr = vm.envAddress("PAYMASTER_ADDRESS");

        MozaikAccountFactory factory = MozaikAccountFactory(factoryAddr);
        MozaikVerifyingPaymaster paymaster = MozaikVerifyingPaymaster(payable(paymasterAddr));

        address accountImpl = address(factory.ACCOUNT_IMPLEMENTATION());

        require(factoryAddr.code.length > 0, "Factory has no code");
        require(accountImpl.code.length > 0, "AccountImpl has no code");
        require(paymasterAddr.code.length > 0, "Paymaster has no code");
        require(paymaster.sponsor() != address(0), "Sponsor not set");
        require(paymaster.owner() != address(0), "Owner not set");

        uint256 epBalance = IEntryPoint(ENTRY_POINT_V09).balanceOf(paymasterAddr);

        console.log("--- Factory ---");
        console.log("Factory:        ", factoryAddr);
        console.log("AccountImpl:    ", accountImpl);
        console.log("--- Paymaster ---");
        console.log("Paymaster:      ", paymasterAddr);
        console.log("Sponsor:        ", paymaster.sponsor());
        console.log("Owner:          ", paymaster.owner());
        console.log("Pending owner:  ", paymaster.pendingOwner());
        console.log("EP balance:     ", epBalance);
        console.log("--- All checks passed ---");
    }
}
