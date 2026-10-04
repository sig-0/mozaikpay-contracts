// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {MozaikCCTPForwarderFactory} from "../src/cctp/MozaikCCTPForwarderFactory.sol";
import {CCTPForwarderRecord} from "./cctp/CCTPForwarderRecord.sol";

/// @notice Deploys the frozen v1 CCTP forwarder implementation and factory through Nick's deployer.
/// @dev Reads the record at CCTP_FORWARDER_RECORD and sends its init code, not a fresh build, so the addresses
///      match every other chain of the same environment. Before sending, it checks Circle's CCTP V2 contracts on
///      this chain against the record. Contracts that already exist are skipped.
contract DeployCCTPForwarderScript is Script, CCTPForwarderRecord {
    function run() external {
        ForwarderRecord memory record = _readForwarderRecord(vm.envString("CCTP_FORWARDER_RECORD"));
        _checkCircle(record);

        vm.startBroadcast();

        bool implementationDeployed = _deployRecorded(record.implementation);
        bool factoryDeployed = _deployRecorded(record.factory);

        vm.stopBroadcast();

        require(record.implementation.addr.codehash == record.implementation.codeHash, "Implementation code hash");
        require(record.factory.addr.codehash == record.factory.codeHash, "Factory code hash");
        require(
            MozaikCCTPForwarderFactory(record.factory.addr).predict(record.goldenAccount) == record.goldenForwarder,
            "Golden forwarder"
        );

        console.log("Chain id:       ", block.chainid);
        console.log("Implementation: ", record.implementation.addr, implementationDeployed ? "(new)" : "(existing)");
        console.log("Factory:        ", record.factory.addr, factoryDeployed ? "(new)" : "(existing)");
        console.log("Golden account: ", record.goldenAccount);
        console.log("Golden forward: ", record.goldenForwarder);
    }
}
