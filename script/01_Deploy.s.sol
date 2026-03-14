// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";

import {MozaikAccountFactory} from "../src/account/MozaikAccountFactory.sol";
import {MozaikVerifyingPaymaster} from "../src/paymaster/MozaikVerifyingPaymaster.sol";

contract DeployScript is Script {
    address internal constant ENTRY_POINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;

    function run() external {
        address sponsorAddr = vm.envAddress("SPONSOR_ADDRESS");

        vm.startBroadcast();

        MozaikAccountFactory factory = new MozaikAccountFactory(IEntryPoint(ENTRY_POINT_V09));
        MozaikVerifyingPaymaster paymaster = new MozaikVerifyingPaymaster(IEntryPoint(ENTRY_POINT_V09), sponsorAddr);

        vm.stopBroadcast();

        console.log("EntryPoint:     ", ENTRY_POINT_V09);
        console.log("AccountImpl:    ", address(factory.ACCOUNT_IMPLEMENTATION()));
        console.log("Factory:        ", address(factory));
        console.log("Paymaster:      ", address(paymaster));
        console.log("Sponsor:        ", paymaster.sponsor());
        console.log("Owner:          ", paymaster.owner());
    }
}
