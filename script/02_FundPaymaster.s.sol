// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {MozaikVerifyingPaymaster} from "../src/paymaster/MozaikVerifyingPaymaster.sol";

contract FundPaymasterScript is Script {
    address internal constant ENTRY_POINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;

    function run() external {
        address paymasterAddr = vm.envAddress("PAYMASTER_ADDRESS");
        uint256 depositAmount = vm.envUint("DEPOSIT_AMOUNT_WEI");
        address funder = vm.envAddress("DEPLOYER_ADDRESS");

        MozaikVerifyingPaymaster paymaster = MozaikVerifyingPaymaster(payable(paymasterAddr));
        IEntryPoint entryPoint = IEntryPoint(ENTRY_POINT_V09);

        vm.startBroadcast(funder);
        paymaster.deposit{value: depositAmount}();
        vm.stopBroadcast();

        uint256 balance = entryPoint.balanceOf(paymasterAddr);
        require(balance >= depositAmount, "Deposit not reflected in EntryPoint");

        console.log("Paymaster:         ", paymasterAddr);
        console.log("Deposit amount:    ", depositAmount);
        console.log("EntryPoint balance:", balance);
    }
}
