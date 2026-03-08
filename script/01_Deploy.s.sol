// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";

import {MozaikAccountFactory} from "../src/account/MozaikAccountFactory.sol";
import {MozaikVerifyingPaymaster} from "../src/paymaster/MozaikVerifyingPaymaster.sol";

contract DeployScript is Script {
    address internal constant ENTRY_POINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address verifyingSigner = vm.envAddress("VERIFYING_SIGNER_ADDRESS");
        address paymasterOwner = vm.envOr("PAYMASTER_OWNER_ADDRESS", deployer);

        vm.startBroadcast(deployer);

        (MozaikAccountFactory factory, MozaikVerifyingPaymaster paymaster) = _deploy(verifyingSigner, paymasterOwner);

        vm.stopBroadcast();

        _log(factory, paymaster, deployer);
    }

    function _deploy(address verifyingSigner, address paymasterOwner)
        internal
        returns (MozaikAccountFactory factory, MozaikVerifyingPaymaster paymaster)
    {
        factory = new MozaikAccountFactory(IEntryPoint(ENTRY_POINT_V09));
        paymaster = new MozaikVerifyingPaymaster(IEntryPoint(ENTRY_POINT_V09), verifyingSigner, paymasterOwner);

        // Smoke check: getAddress must return a non-zero counterfactual address.
        address testOwner = address(1);
        address counterfactual = factory.getAddress(testOwner);

        require(counterfactual != address(0), "getAddress returned zero");
    }

    function _log(MozaikAccountFactory factory, MozaikVerifyingPaymaster paymaster, address deployer) internal view {
        console.log("Deployer:           ", deployer);
        console.log("EntryPoint:         ", ENTRY_POINT_V09);
        console.log("AccountImpl:        ", address(factory.ACCOUNT_IMPLEMENTATION()));
        console.log("AccountFactory:     ", address(factory));
        console.log("VerifyingPaymaster: ", address(paymaster));
        console.log("VerifyingSigner:    ", paymaster.verifyingSigner());
    }
}
