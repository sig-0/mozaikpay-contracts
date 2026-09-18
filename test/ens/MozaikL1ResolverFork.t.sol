// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ENS} from "ens-contracts/registry/ENS.sol";
import {IAddrResolver} from "ens-contracts/resolvers/profiles/IAddrResolver.sol";
import {IExtendedResolver} from "ens-contracts/resolvers/profiles/IExtendedResolver.sol";
import {IUniversalResolver} from "ens-contracts/universalResolver/IUniversalResolver.sol";
import {NameCoder} from "ens-contracts/utils/NameCoder.sol";

import {MozaikL1Resolver} from "../../src/ens/MozaikL1Resolver.sol";

/// @notice Fork test against Ethereum mainnet: resolves mozaikpay.eth through the real ENS contracts.
/// @dev    Skipped when ETH_MAINNET_RPC is not set. Run with `make test-fork`.
contract MozaikL1ResolverForkTest is Test {
    /// @dev The ENS registry, same address on every network.
    ENS internal constant REGISTRY = ENS(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e);

    /// @dev lib/ens-contracts/deployments/mainnet/UniversalResolver.json
    IUniversalResolver internal constant UNIVERSAL_RESOLVER =
        IUniversalResolver(0xED73a03F19e8D849E44a39252d222c6ad5217E1e);

    string internal constant GATEWAY_URL = "https://ens.mozaik.money/ccip/{sender}/{data}.json";

    MozaikL1Resolver internal resolver;

    /// @dev Read from the live registry so the test follows the name wherever it moves.
    address internal nameOwner;
    address internal publicResolver;

    bytes internal parentName;
    bytes internal subname;
    bytes32 internal parentNode;
    bytes32 internal subnode;

    address internal owner;
    address internal signer;
    uint256 internal signerKey;

    modifier onlyFork() {
        string memory rpc = vm.envOr("ETH_MAINNET_RPC", string(""));
        if (bytes(rpc).length == 0) return;

        vm.createSelectFork(rpc);
        _;
    }

    function _setupFork() internal {
        parentName = NameCoder.encode("mozaikpay.eth");
        subname = NameCoder.encode("juan.mozaikpay.eth");
        parentNode = NameCoder.namehash(parentName, 0);
        subnode = NameCoder.namehash(subname, 0);

        nameOwner = REGISTRY.owner(parentNode);
        publicResolver = REGISTRY.resolver(parentNode);
        require(nameOwner != address(0), "fork: mozaikpay.eth is not registered");
        require(publicResolver != address(0), "fork: mozaikpay.eth has no resolver");

        owner = makeAddr("forkOwner");
        (signer, signerKey) = makeAddrAndKey("forkGatewaySigner");

        address[] memory signers = new address[](1);
        signers[0] = signer;

        resolver = new MozaikL1Resolver(GATEWAY_URL, signers, owner, publicResolver, parentName);

        vm.prank(nameOwner);
        REGISTRY.setResolver(parentNode, address(resolver));
    }

    function test_Fork_Registry_PointsAtResolver() public onlyFork {
        _setupFork();

        assertEq(REGISTRY.resolver(parentNode), address(resolver));
        assertEq(REGISTRY.resolver(subnode), address(0));
    }

    function test_Fork_UniversalResolver_ParentNameResolvesOnChain() public onlyFork {
        _setupFork();

        (bytes memory result, address used) =
            UNIVERSAL_RESOLVER.resolve(parentName, abi.encodeCall(IAddrResolver.addr, (parentNode)));

        assertEq(used, address(resolver));
        assertEq(abi.decode(result, (address)), IAddrResolver(publicResolver).addr(parentNode));
    }

    function test_Fork_UniversalResolver_FindsResolverForSubname() public onlyFork {
        _setupFork();

        (address found, bytes32 node, uint256 offset) = UNIVERSAL_RESOLVER.findResolver(subname);

        assertEq(found, address(resolver));
        assertEq(node, subnode);
        assertEq(offset, 5);
        assertTrue(resolver.supportsInterface(type(IExtendedResolver).interfaceId));
    }

    function test_Fork_UniversalResolver_SubnameRevertsWithOffchainLookup() public onlyFork {
        _setupFork();

        (bool ok, bytes memory err) = address(UNIVERSAL_RESOLVER)
            .staticcall(
                abi.encodeCall(IUniversalResolver.resolve, (subname, abi.encodeCall(IAddrResolver.addr, (subnode))))
            );

        assertFalse(ok);
        assertEq(bytes4(err), MozaikL1Resolver.OffchainLookup.selector);

        (address sender, string[] memory urls, bytes memory callData,,) =
            abi.decode(_body(err), (address, string[], bytes, bytes4, bytes));

        assertEq(sender, address(UNIVERSAL_RESOLVER));
        assertGt(urls.length, 0);
        assertTrue(_contains(callData, abi.encodePacked(address(resolver))));
    }

    function test_Fork_Subname_RoundTripWithSignedResponse() public onlyFork {
        _setupFork();

        bytes memory request =
            abi.encodeCall(IExtendedResolver.resolve, (subname, abi.encodeCall(IAddrResolver.addr, (subnode))));

        (bool ok, bytes memory err) = address(resolver).staticcall(request);

        assertFalse(ok);
        assertEq(bytes4(err), MozaikL1Resolver.OffchainLookup.selector);

        (address sender, string[] memory urls, bytes memory callData, bytes4 callback, bytes memory extraData) =
            abi.decode(_body(err), (address, string[], bytes, bytes4, bytes));

        assertEq(sender, address(resolver));
        assertEq(urls.length, 1);
        assertEq(urls[0], GATEWAY_URL);
        assertEq(callData, request);
        assertEq(callback, MozaikL1Resolver.resolveWithProof.selector);
        assertEq(extraData, request);

        address juan = makeAddr("forkJuan");
        bytes memory result = abi.encode(juan);
        uint64 expires = uint64(block.timestamp + 5 minutes);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerKey, resolver.makeSignatureHash(address(resolver), expires, extraData, result));
        bytes memory response = abi.encode(result, expires, abi.encodePacked(r, s, v));

        assertEq(abi.decode(resolver.resolveWithProof(response, extraData), (address)), juan);
    }

    function test_Fork_LegacyClient_ReadsParentRecordsThroughFallback() public onlyFork {
        _setupFork();

        assertTrue(resolver.supportsInterface(type(IAddrResolver).interfaceId));
        assertEq(IAddrResolver(address(resolver)).addr(parentNode), IAddrResolver(publicResolver).addr(parentNode));
    }

    /// @dev Revert data without its 4-byte selector.
    function _body(bytes memory data) internal pure returns (bytes memory body) {
        body = new bytes(data.length - 4);

        for (uint256 i = 0; i < body.length; i++) {
            body[i] = data[i + 4];
        }
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length > haystack.length) return false;

        for (uint256 i = 0; i + needle.length <= haystack.length; i++) {
            bool matched = true;

            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    matched = false;

                    break;
                }
            }

            if (matched) return true;
        }

        return false;
    }
}
