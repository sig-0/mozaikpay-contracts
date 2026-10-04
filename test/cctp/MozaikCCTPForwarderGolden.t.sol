// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {MozaikCCTPForwarder} from "../../src/cctp/MozaikCCTPForwarder.sol";
import {MozaikCCTPForwarderFactory} from "../../src/cctp/MozaikCCTPForwarderFactory.sol";
import {CCTPForwarderRecord} from "../../script/cctp/CCTPForwarderRecord.sol";

/// @notice Pins the v1 golden vectors for both environments. The same account, forwarder, implementation and
///         factory addresses are pinned in the Go and TypeScript derivation tests.
contract MozaikCCTPForwarderGoldenTest is Test, CCTPForwarderRecord {
    address internal constant GOLDEN_ACCOUNT = 0x287B02E09a220f911f5BbAaA3F1c9D170C1B9a08;

    address internal constant MAINNET_IMPLEMENTATION = 0x96A750CDE9C840bb47bc9D31844747c96eb78793;
    address internal constant MAINNET_FACTORY = 0xa5B1963D744E160EaC7C02C95e8C797B76Bc551a;
    address internal constant MAINNET_GOLDEN_FORWARDER = 0xd60bD0f86a55D4f716082960fd9973F9D92F1b1f;

    address internal constant SEPOLIA_IMPLEMENTATION = 0x8c28726fa4C8F3ad347D677C785fE1ECD8103d4E;
    address internal constant SEPOLIA_FACTORY = 0x84559FB3CC966663586Faa85af090dEaD4Ebc440;
    address internal constant SEPOLIA_GOLDEN_FORWARDER = 0x0206049E6f71279a94F22ab6C401A935e9a630A4;

    ForwarderRecord internal mainnet;
    ForwarderRecord internal sepolia;

    function setUp() public {
        mainnet = _readForwarderRecord("script/cctp/forwarder-v1.json");
        sepolia = _readForwarderRecord("script/cctp/forwarder-v1-sepolia.json");
    }

    function test_Record_PinsMainnetGoldenVector() public view {
        _assertPins(mainnet, MAINNET_IMPLEMENTATION, MAINNET_FACTORY, MAINNET_GOLDEN_FORWARDER);
        assertEq(mainnet.tokenMessenger, 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d, "token messenger");
        assertEq(mainnet.baseUsdc, 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, "Base USDC");
        assertEq(mainnet.baseChainId, 8453, "Base chain id");
    }

    function test_Record_PinsSepoliaGoldenVector() public view {
        _assertPins(sepolia, SEPOLIA_IMPLEMENTATION, SEPOLIA_FACTORY, SEPOLIA_GOLDEN_FORWARDER);
        assertEq(sepolia.tokenMessenger, 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA, "token messenger");
        assertEq(sepolia.baseUsdc, 0x036CbD53842c5426634e7929541eC2318f3dCF7e, "Base USDC");
        assertEq(sepolia.baseChainId, 84532, "Base chain id");
    }

    /// @dev Keeps the tests on the deployed bytecode. Coverage builds without the optimizer, so it skips.
    function test_Record_MatchesBuild() public {
        vm.skip(vm.isContext(VmSafe.ForgeContext.Coverage));

        _assertMatchesBuild(mainnet);
        _assertMatchesBuild(sepolia);
    }

    function test_Record_DeploysAtGoldenAddresses() public {
        _assertDeploys(mainnet);
        _assertDeploys(sepolia);
    }

    function _assertPins(ForwarderRecord memory record, address implementation, address factory, address forwarder)
        internal
        pure
    {
        assertEq(record.create2Deployer, CREATE2_DEPLOYER, "CREATE2 deployer");
        assertEq(record.implementation.addr, implementation, "implementation");
        assertEq(record.factory.addr, factory, "factory");
        assertEq(record.goldenAccount, GOLDEN_ACCOUNT, "golden account");
        assertEq(record.goldenForwarder, forwarder, "golden forwarder");
        assertEq(record.implementation.salt, bytes32(0), "implementation salt");
        assertEq(record.factory.salt, bytes32(0), "factory salt");
    }

    function _assertMatchesBuild(ForwarderRecord memory record) internal pure {
        assertEq(
            record.implementation.initCode,
            abi.encodePacked(
                type(MozaikCCTPForwarder).creationCode,
                abi.encode(record.tokenMessenger, record.baseUsdc, record.baseChainId)
            ),
            "implementation"
        );
        assertEq(
            record.factory.initCode,
            abi.encodePacked(type(MozaikCCTPForwarderFactory).creationCode, abi.encode(record.implementation.addr)),
            "factory"
        );
    }

    function _assertDeploys(ForwarderRecord memory record) internal {
        assertEq(
            vm.computeCreate2Address(bytes32(0), keccak256(record.implementation.initCode), CREATE2_DEPLOYER),
            record.implementation.addr
        );
        assertEq(
            vm.computeCreate2Address(bytes32(0), keccak256(record.factory.initCode), CREATE2_DEPLOYER),
            record.factory.addr
        );

        assertTrue(_deployRecorded(record.implementation), "implementation deployed");
        assertTrue(_deployRecorded(record.factory), "factory deployed");
        assertFalse(_deployRecorded(record.factory), "second deploy is a no-op");

        assertEq(record.implementation.addr.codehash, record.implementation.codeHash, "implementation code hash");
        assertEq(record.factory.addr.codehash, record.factory.codeHash, "factory code hash");

        MozaikCCTPForwarder implementation = MozaikCCTPForwarder(record.implementation.addr);
        assertEq(address(implementation.TOKEN_MESSENGER()), record.tokenMessenger);
        assertEq(implementation.BASE_USDC(), record.baseUsdc);
        assertEq(implementation.BASE_CHAIN_ID(), record.baseChainId);

        MozaikCCTPForwarderFactory factory = MozaikCCTPForwarderFactory(record.factory.addr);
        assertEq(address(factory.FORWARDER_IMPLEMENTATION()), record.implementation.addr);
        assertEq(factory.predict(GOLDEN_ACCOUNT), record.goldenForwarder);
        assertEq(factory.deploy(GOLDEN_ACCOUNT), record.goldenForwarder);
        assertEq(MozaikCCTPForwarder(record.goldenForwarder).account(), GOLDEN_ACCOUNT);
    }
}
