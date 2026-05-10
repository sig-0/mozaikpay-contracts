// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MozaikLinks} from "../src/paylinks/MozaikLinks.sol";

/// @notice Deploys MozaikLinks bound to the USDC address provided in env.
/// @dev    Requires `USDC_ADDRESS` in the environment. Pass `EXTRA="--broadcast"` to send.
contract DeployPaylinksScript is Script {
    function run() external {
        address usdcAddr = vm.envAddress("USDC_ADDRESS");

        vm.startBroadcast();

        MozaikLinks links = new MozaikLinks(IERC20(usdcAddr));

        vm.stopBroadcast();

        console.log("USDC:           ", usdcAddr);
        console.log("MozaikLinks:    ", address(links));
        console.log("ChainId:        ", block.chainid);
    }
}
