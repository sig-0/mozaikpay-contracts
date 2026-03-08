// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MozaikVerifyingPaymaster} from "../src/paymaster/MozaikVerifyingPaymaster.sol";

contract TransferOwnershipScript is Script {
    function run() external {
        address paymasterAddr = vm.envAddress("PAYMASTER_ADDRESS");
        address multisig = vm.envAddress("MULTISIG_ADDRESS");
        address currentOwner = vm.envAddress("DEPLOYER_ADDRESS");

        MozaikVerifyingPaymaster paymaster = MozaikVerifyingPaymaster(payable(paymasterAddr));

        vm.startBroadcast(currentOwner);
        paymaster.transferOwnership(multisig);
        vm.stopBroadcast();

        // Ownership in Ownable2Step is pending until the new owner accepts.
        address pending = paymaster.pendingOwner();
        require(pending == multisig, "Ownership transfer not initiated");

        console.log("Paymaster:          ", paymasterAddr);
        console.log("Pending owner:      ", pending);
        console.log("(New owner must call acceptOwnership() to complete transfer)");
    }
}
