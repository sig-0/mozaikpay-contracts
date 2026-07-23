// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Transfers mock USDC from the pre-funded deployer to a target address.
/// Usage:
///   TO=0x... AMOUNT=1000 make dev-fund
contract DevFundUSDC is Script {
    using SafeERC20 for IERC20;

    /// @dev Deterministic address: Anvil account #0 deploys MockUSDC at nonce 2.
    address internal constant MOCK_USDC = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;

    function run() external {
        address to = vm.envAddress("TO");
        uint256 amount = vm.envUint("AMOUNT") * 1e6; // AMOUNT is in whole USDC

        uint256 balance = IERC20(MOCK_USDC).balanceOf(msg.sender);
        require(balance >= amount, "insufficient mock USDC balance");

        vm.startBroadcast();
        IERC20(MOCK_USDC).safeTransfer(to, amount);
        vm.stopBroadcast();

        console.log("Transferred %s USDC to %s", vm.envUint("AMOUNT"), to);
    }
}
