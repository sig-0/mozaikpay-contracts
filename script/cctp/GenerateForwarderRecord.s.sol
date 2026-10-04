// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {MozaikCCTPForwarder} from "../../src/cctp/MozaikCCTPForwarder.sol";
import {MozaikCCTPForwarderFactory} from "../../src/cctp/MozaikCCTPForwarderFactory.sol";
import {CCTPForwarderRecord} from "./CCTPForwarderRecord.sol";

/// @notice Rebuilds the record at CCTP_FORWARDER_RECORD from the current source. Only for a version that is not
///         deployed yet, because any source change moves every address.
/// @dev Keeps the record's config and golden account, and rewrites every field derived from the source.
contract GenerateForwarderRecordScript is Script, CCTPForwarderRecord {
    function run() external {
        string memory path = vm.envString("CCTP_FORWARDER_RECORD");
        ForwarderRecord memory record = _readForwarderRecord(path);

        Deployment memory implementation = _build(
            abi.encodePacked(
                type(MozaikCCTPForwarder).creationCode,
                abi.encode(record.tokenMessenger, record.baseUsdc, record.baseChainId)
            )
        );
        Deployment memory factory =
            _build(abi.encodePacked(type(MozaikCCTPForwarderFactory).creationCode, abi.encode(implementation.addr)));
        address goldenForwarder = MozaikCCTPForwarderFactory(factory.addr).predict(record.goldenAccount);

        _writeDeployment(path, ".implementation", implementation);
        _writeDeployment(path, ".factory", factory);
        vm.writeJson(_quote(vm.toString(goldenForwarder)), path, ".golden.forwarder");

        console.log("Record:         ", path);
        console.log("Implementation: ", implementation.addr);
        console.log("Factory:        ", factory.addr);
        console.log("Golden forward: ", goldenForwarder);
    }

    /// @dev Deploys `initCode` and returns its record fields.
    function _build(bytes memory initCode) internal returns (Deployment memory deployment) {
        deployment.initCode = initCode;
        deployment.addr = vm.computeCreate2Address(bytes32(0), keccak256(initCode), CREATE2_DEPLOYER);

        require(_deployRecorded(deployment), "Already deployed on the local EVM");
        deployment.codeHash = deployment.addr.codehash;
    }

    function _writeDeployment(string memory path, string memory key, Deployment memory deployment) internal {
        vm.writeJson(_quote(vm.toString(deployment.addr)), path, string.concat(key, ".address"));
        vm.writeJson(_quote(vm.toString(deployment.codeHash)), path, string.concat(key, ".codeHash"));
        vm.writeJson(_quote(vm.toString(deployment.initCode)), path, string.concat(key, ".initCode"));
    }

    function _quote(string memory value) internal pure returns (string memory) {
        return string.concat('"', value, '"');
    }
}
