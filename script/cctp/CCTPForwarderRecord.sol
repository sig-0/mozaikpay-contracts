// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CommonBase} from "forge-std/Base.sol";

import {ITokenMessengerV2} from "../../src/cctp/ITokenMessengerV2.sol";

/// @notice Subset of Circle's MessageTransmitterV2.
interface IMessageTransmitterV2 {
    function localDomain() external view returns (uint32);
}

/// @notice Subset of Circle's TokenMessengerV2 that the record checks read.
interface ITokenMessengerV2Routes {
    function remoteTokenMessengers(uint32 domain) external view returns (bytes32);
}

/// @notice Subset of Circle's TokenMinterV2 that the record checks read.
interface ITokenMinterV2Limits {
    function burnLimitsPerMessage(address token) external view returns (uint256);
}

/// @notice Reads a frozen CCTP forwarder record and deploys its init code through Nick's deployer.
/// @dev A record holds the exact v1 init code for one environment. Every chain, fork and local node of that
///      environment deploys these bytes, so the implementation, the factory and every forwarder get the same
///      addresses everywhere.
abstract contract CCTPForwarderRecord is CommonBase {
    /// @dev Nick's deterministic deployment proxy (github.com/Arachnid/deterministic-deployment-proxy). It has the
    ///      same address on every EVM chain and runs CREATE2 with the caller's salt and init code.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev CCTP domain of Base.
    uint32 internal constant BASE_DOMAIN = 6;

    struct Deployment {
        bytes32 salt;
        address addr;
        bytes32 codeHash;
        bytes initCode;
    }

    struct ForwarderRecord {
        address create2Deployer;
        address tokenMessenger;
        address baseUsdc;
        uint256 baseChainId;
        Deployment implementation;
        Deployment factory;
        address goldenAccount;
        address goldenForwarder;
    }

    function _readForwarderRecord(string memory path) internal view returns (ForwarderRecord memory record) {
        string memory json = vm.readFile(path);

        record.create2Deployer = vm.parseJsonAddress(json, ".create2Deployer");
        record.tokenMessenger = vm.parseJsonAddress(json, ".config.tokenMessenger");
        record.baseUsdc = vm.parseJsonAddress(json, ".config.baseUsdc");
        record.baseChainId = vm.parseJsonUint(json, ".config.baseChainId");
        record.implementation = _readDeployment(json, ".implementation");
        record.factory = _readDeployment(json, ".factory");
        record.goldenAccount = vm.parseJsonAddress(json, ".golden.account");
        record.goldenForwarder = vm.parseJsonAddress(json, ".golden.forwarder");
    }

    /// @dev Checks Circle's CCTP V2 contracts on this chain against the record, and off Base that USDC can burn to
    ///      Base. Returns the local CCTP domain and USDC.
    function _checkCircle(ForwarderRecord memory record) internal view returns (uint32 domain, address usdc) {
        ITokenMessengerV2 messenger = ITokenMessengerV2(record.tokenMessenger);
        require(address(messenger).code.length > 0, "No TokenMessengerV2 on this chain");
        domain = IMessageTransmitterV2(messenger.localMessageTransmitter()).localDomain();

        bool onBase = block.chainid == record.baseChainId;
        require(onBase == (domain == BASE_DOMAIN), "Base chain id and CCTP domain disagree");

        usdc = onBase
            ? record.baseUsdc
            : messenger.localMinter().getLocalToken(BASE_DOMAIN, bytes32(uint256(uint160(record.baseUsdc))));
        require(usdc.code.length > 0, "No USDC for this chain");

        if (onBase) return (domain, usdc);

        require(
            ITokenMessengerV2Routes(address(messenger)).remoteTokenMessengers(BASE_DOMAIN) != bytes32(0),
            "No CCTP route to Base"
        );
        require(
            ITokenMinterV2Limits(address(messenger.localMinter())).burnLimitsPerMessage(usdc) > 0,
            "USDC burns are disabled on this chain"
        );
    }

    /// @dev Deploys the recorded init code unless the recorded address already has code. Reverts if Nick's
    ///      deployer is missing or the contract lands at another address.
    function _deployRecorded(Deployment memory deployment) internal returns (bool deployed) {
        if (deployment.addr.code.length > 0) return false;
        require(CREATE2_DEPLOYER.code.length > 0, "Nick's deployer is not on this chain");

        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(deployment.salt, deployment.initCode));
        require(ok && ret.length == 20 && address(bytes20(ret)) == deployment.addr, "Deploy landed elsewhere");

        return true;
    }

    function _readDeployment(string memory json, string memory key) private pure returns (Deployment memory d) {
        d.salt = vm.parseJsonBytes32(json, string.concat(key, ".salt"));
        d.addr = vm.parseJsonAddress(json, string.concat(key, ".address"));
        d.codeHash = vm.parseJsonBytes32(json, string.concat(key, ".codeHash"));
        d.initCode = vm.parseJsonBytes(json, string.concat(key, ".initCode"));
    }
}
