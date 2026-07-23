// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MozaikAccountFactory} from "../src/account/MozaikAccountFactory.sol";
import {MozaikVerifyingPaymaster} from "../src/paymaster/MozaikVerifyingPaymaster.sol";
import {MozaikPaylinks} from "../src/paylinks/MozaikPaylinks.sol";

contract DeployScript is Script {
    address internal constant ENTRY_POINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;

    // Canonical USDC on the supported chains, used as the paylinks token. Override
    // with USDC_ADDRESS in the environment (e.g. a mock token on a local chain).
    address internal constant USDC_BASE_MAINNET = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external {
        address sponsorAddr = vm.envAddress("SPONSOR_ADDRESS");

        address usdcAddr = vm.envOr("USDC_ADDRESS", address(0));
        if (usdcAddr == address(0)) usdcAddr = _defaultUsdc();

        vm.startBroadcast();

        MozaikAccountFactory factory = new MozaikAccountFactory();
        MozaikVerifyingPaymaster paymaster = new MozaikVerifyingPaymaster(sponsorAddr);
        MozaikPaylinks paylinks = new MozaikPaylinks(IERC20(usdcAddr));

        vm.stopBroadcast();

        console.log("EntryPoint:     ", ENTRY_POINT_V09);
        console.log("AccountImpl:    ", address(factory.ACCOUNT_IMPLEMENTATION()));
        console.log("Factory:        ", address(factory));
        console.log("Paymaster:      ", address(paymaster));
        console.log("Sponsor:        ", paymaster.sponsor());
        console.log("Owner:          ", paymaster.owner());
        console.log("USDC:           ", usdcAddr);
        console.log("Paylinks:       ", address(paylinks));
    }

    // Canonical USDC for the target chain. Only consulted when USDC_ADDRESS is unset.
    function _defaultUsdc() internal view returns (address) {
        if (block.chainid == 8453) return USDC_BASE_MAINNET;
        if (block.chainid == 84532) return USDC_BASE_SEPOLIA;

        revert("USDC_ADDRESS required for this chain");
    }
}
