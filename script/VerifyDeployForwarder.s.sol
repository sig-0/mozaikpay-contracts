// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {MozaikCCTPForwarderFactory} from "../src/cctp/MozaikCCTPForwarderFactory.sol";
import {CCTPForwarderRecord} from "./cctp/CCTPForwarderRecord.sol";

/// @notice Checks a CCTP forwarder deployment against the frozen record at CCTP_FORWARDER_RECORD, and checks that
///         Circle's CCTP V2 contracts on this chain match the record's config.
contract VerifyDeployForwarderScript is Script, CCTPForwarderRecord {
    function run() external view {
        ForwarderRecord memory record = _readForwarderRecord(vm.envString("CCTP_FORWARDER_RECORD"));
        MozaikCCTPForwarderFactory factory = MozaikCCTPForwarderFactory(record.factory.addr);

        require(record.implementation.addr.codehash == record.implementation.codeHash, "Implementation code hash");
        require(record.factory.addr.codehash == record.factory.codeHash, "Factory code hash");
        require(address(factory.FORWARDER_IMPLEMENTATION()) == record.implementation.addr, "Factory implementation");
        require(factory.predict(record.goldenAccount) == record.goldenForwarder, "Golden forwarder");

        (uint32 domain, address usdc) = _checkCircle(record);

        console.log("Chain id:       ", block.chainid);
        console.log("CCTP domain:    ", domain);
        console.log("USDC:           ", usdc, IERC20Metadata(usdc).symbol());
        console.log("Implementation: ", record.implementation.addr);
        console.log("Factory:        ", record.factory.addr);
        console.log("Golden forward: ", record.goldenForwarder);
        console.log("--- All checks passed ---");
    }
}
