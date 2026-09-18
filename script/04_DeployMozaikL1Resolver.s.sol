// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {NameCoder} from "ens-contracts/utils/NameCoder.sol";

import {MozaikL1Resolver} from "../src/ens/MozaikL1Resolver.sol";

contract DeployMozaikL1ResolverScript is Script {
    function run() external {
        string memory gatewayUrl = vm.envString("ENS_GATEWAY_URL");
        address[] memory signers = vm.envAddress("ENS_SIGNER_ADDRESSES", ",");
        address owner = vm.envAddress("ENS_RESOLVER_OWNER");
        address rootResolver = vm.envAddress("ENS_ROOT_RESOLVER");
        string memory parentName = vm.envString("ENS_PARENT_NAME");

        require(block.chainid == 1 || block.chainid == 11155111, "ENS resolver deploys to Ethereum only");
        require(signers.length > 0, "ENS_SIGNER_ADDRESSES required");

        vm.startBroadcast();

        MozaikL1Resolver resolver =
            new MozaikL1Resolver(gatewayUrl, signers, owner, rootResolver, NameCoder.encode(parentName));

        vm.stopBroadcast();

        console.log("MozaikL1Resolver:     ", address(resolver));
        console.log("Gateway URL:    ", resolver.url());
        console.log("Owner:          ", resolver.owner());
        console.log("Root resolver:  ", resolver.rootResolver());
        console.log("Parent name:    ", parentName);
        for (uint256 i = 0; i < signers.length; i++) {
            console.log("Signer:         ", signers[i]);
        }
    }
}
