// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MozaikVerifyingPaymaster} from "../src/paymaster/MozaikVerifyingPaymaster.sol";

contract TransferOwnershipScript is Script {
    function run() external {
        address paymasterAddr = vm.envAddress("PAYMASTER_ADDRESS");
        address newOwner = vm.envAddress("NEW_OWNER_ADDRESS");

        MozaikVerifyingPaymaster paymaster = MozaikVerifyingPaymaster(payable(paymasterAddr));

        vm.startBroadcast();
        paymaster.transferOwnership(newOwner);
        vm.stopBroadcast();

        // Ownable2Step: ownership is pending until the new owner calls acceptOwnership().
        require(paymaster.pendingOwner() == newOwner, "Ownership transfer not initiated");

        console.log("Paymaster:      ", paymasterAddr);
        console.log("Current owner:  ", paymaster.owner());
        console.log("Pending owner:  ", paymaster.pendingOwner());
        console.log("New owner must call acceptOwnership() to complete the transfer.");
    }
}
