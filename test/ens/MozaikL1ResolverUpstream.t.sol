// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {MozaikL1Resolver} from "../../src/ens/MozaikL1Resolver.sol";
import {SignatureVerifier} from "../../src/ens/SignatureVerifier.sol";
import {RootResolverMock} from "./MozaikL1Resolver.t.sol";

/// Ported from base-org/basenames (test/MozaikL1Resolver).
contract MozaikL1ResolverUpstreamTest is Test {
    string internal constant URL = "TEST_URL";
    bytes4 internal constant ADDR_SELECTOR = 0x3b3b57de;
    bytes4 internal constant TEXT_SELECTOR = 0x59d1d43c;
    bytes4 internal constant EXTENDED_RESOLVER_ID = 0x9061b923;

    bytes internal constant PARENT_NAME = hex"096d6f7a61696b70617903657468" hex"00";
    bytes32 internal constant PARENT_NODE = keccak256("parent-node");

    MozaikL1Resolver internal resolver;
    RootResolverMock internal rootResolver;

    address internal signer;
    uint256 internal signerPk;
    address internal owner;
    address internal parentAddress;

    function setUp() public {
        owner = makeAddr("0x1");
        parentAddress = makeAddr("parent-address");
        (signer, signerPk) = makeAddrAndKey("0xace");

        address[] memory signers = new address[](1);
        signers[0] = signer;

        rootResolver = new RootResolverMock(parentAddress);
        resolver = new MozaikL1Resolver(URL, signers, owner, address(rootResolver), PARENT_NAME);
    }

    // MozaikL1ResolverBase.t.sol

    function test_constructor() public {
        address[] memory signers_ = new address[](1);
        signers_[0] = signer;

        vm.expectEmit();
        emit MozaikL1Resolver.AddedSigners(signers_);
        resolver = new MozaikL1Resolver(URL, signers_, owner, address(rootResolver), PARENT_NAME);

        assertTrue(keccak256(bytes(resolver.url())) == keccak256(bytes(URL)));
        assertTrue(resolver.signers(signer));
        assertTrue(resolver.owner() == owner);
        assertTrue(resolver.rootResolver() == address(rootResolver));
    }

    // AdminMethods.t.sol

    function test_setUrl(string memory newUrl) public {
        vm.prank(makeAddr("0x2"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("0x2")));
        resolver.setUrl(newUrl);

        vm.prank(owner);
        vm.expectEmit();
        emit MozaikL1Resolver.UrlChanged(newUrl);
        resolver.setUrl(newUrl);
    }

    // Upstream fuzzes the array directly; with this repository's 10k runs that rejects too many
    // inputs, so the array is derived from a seed instead.
    function test_addSigners(bytes32 seed, uint8 count) public {
        address[] memory _signers = new address[](bound(count, 0, 9));
        for (uint256 i; i < _signers.length; i++) {
            _signers[i] = address(uint160(uint256(keccak256(abi.encode(seed, i)))));
        }

        vm.prank(makeAddr("0x2"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("0x2")));
        resolver.addSigners(_signers);

        vm.prank(owner);
        vm.expectEmit();
        emit MozaikL1Resolver.AddedSigners(_signers);
        resolver.addSigners(_signers);

        for (uint256 i; i < _signers.length; i++) {
            assertTrue(resolver.signers(_signers[i]));
        }
    }

    function test_removeSigner() public {
        vm.prank(makeAddr("0x2"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("0x2")));
        resolver.removeSigner(signer);
        assertTrue(resolver.signers(signer));

        vm.prank(owner);
        vm.expectEmit();
        emit MozaikL1Resolver.RemovedSigner(signer);
        resolver.removeSigner(signer);
        assertFalse(resolver.signers(signer));
    }

    function test_setRootResolver(address newResolver) public {
        vm.assume(newResolver != address(0));

        vm.prank(makeAddr("0x2"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("0x2")));
        resolver.setRootResolver(newResolver);

        vm.prank(owner);
        vm.expectEmit();
        emit MozaikL1Resolver.RootResolverChanged(newResolver);
        resolver.setRootResolver(newResolver);
    }

    // Resolve.t.sol

    function test_revertsWithOffchainLookup_whenResolvingName(string memory label) public {
        bytes memory dnsName = _subname(label);
        bytes memory data = abi.encodeWithSelector(ADDR_SELECTOR, keccak256(dnsName));
        bytes memory callData = abi.encodeWithSelector(resolver.resolve.selector, dnsName, data);
        string[] memory urls = new string[](1);
        urls[0] = resolver.url();

        vm.expectRevert(
            abi.encodeWithSelector(
                MozaikL1Resolver.OffchainLookup.selector,
                address(resolver),
                urls,
                callData,
                MozaikL1Resolver.resolveWithProof.selector,
                callData
            )
        );
        resolver.resolve(dnsName, data);
    }

    function test_resolvesAddr_whenCallingforRootName() public view {
        bytes memory data = abi.encodeWithSelector(ADDR_SELECTOR, PARENT_NODE);
        bytes memory response = resolver.resolve(PARENT_NAME, data);
        (address resolvedAddress) = abi.decode(response, (address));
        assert(resolvedAddress == rootResolver.parentAddress());
    }

    function test_resolvesText_whenCallingforRootName() public view {
        bytes memory data = abi.encodeWithSelector(TEXT_SELECTOR, PARENT_NODE, "test");
        bytes memory response = resolver.resolve(PARENT_NAME, data);
        (string memory resolvedText) = abi.decode(response, (string));
        assert(keccak256(bytes(resolvedText)) == keccak256(bytes(rootResolver.TEST_TEXT())));
    }

    // ResolveWithProof.t.sol

    function test_returnsResultsWithValidSignature(string memory label) public {
        (address expectedAddress, bytes memory callData, bytes memory result) = _setupProofCallback(label);
        uint64 expires = 1893456000; // 1/1/2030 00:00:00
        bytes32 digest = SignatureVerifier.makeSignatureHash(address(resolver), expires, callData, result);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        bytes memory gatewayResponse = abi.encode(result, expires, sig);

        bytes memory response = resolver.resolveWithProof(gatewayResponse, callData);
        (address returnedAddress) = abi.decode(response, (address));
        assertEq(returnedAddress, expectedAddress);
    }

    function test_revertsWhenTheSignatureIsExpired(string memory label) public {
        (, bytes memory callData, bytes memory result) = _setupProofCallback(label);
        uint64 expires = 0;
        bytes32 digest = SignatureVerifier.makeSignatureHash(address(resolver), expires, callData, result);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        bytes memory gatewayResponse = abi.encode(result, expires, sig);

        vm.expectRevert(SignatureVerifier.SignatureExpired.selector);
        resolver.resolveWithProof(gatewayResponse, callData);
    }

    function test_revertsWhenTheSignerIsInvalid(string memory label) public {
        (, bytes memory callData, bytes memory result) = _setupProofCallback(label);
        uint64 expires = 1893456000; // 1/1/2030 00:00:00
        bytes32 digest = SignatureVerifier.makeSignatureHash(address(resolver), expires, callData, result);
        uint256 pk = 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        bytes memory gatewayResponse = abi.encode(result, expires, sig);

        vm.expectRevert(MozaikL1Resolver.InvalidSigner.selector);
        resolver.resolveWithProof(gatewayResponse, callData);
    }

    // MakeSignatureHash.t.sol

    function test_makesValidSignatureHash(address target, uint64 expires, bytes memory request, bytes memory result)
        public
        view
    {
        bytes32 expectedHash = SignatureVerifier.makeSignatureHash(target, expires, request, result);
        bytes32 testHash = resolver.makeSignatureHash(target, expires, request, result);
        assertEq(expectedHash, testHash);
    }

    // SupportsInterface.t.sol

    function test_supportsExtendedResolver() public view {
        assertTrue(resolver.supportsInterface(EXTENDED_RESOLVER_ID)); // https://docs.ens.domains/ensip/10
    }

    function test_supportsERC165() public view {
        assertTrue(resolver.supportsInterface(type(IERC165).interfaceId));
    }

    function test_supportsForwarding_toIAddrCompliantRootResolver() public view {
        assertTrue(resolver.supportsInterface(ADDR_SELECTOR));
    }

    function test_supportsForwarding_toITextCompliantRootResolver() public view {
        assertTrue(resolver.supportsInterface(TEXT_SELECTOR));
    }

    function test_doesNotSupportArbitraryInterfaceId(bytes4 interfaceID) public view {
        vm.assume(
            interfaceID != EXTENDED_RESOLVER_ID && interfaceID != type(IERC165).interfaceId
                && interfaceID != ADDR_SELECTOR && interfaceID != TEXT_SELECTOR
        );
        assertFalse(resolver.supportsInterface(interfaceID));
    }

    // Fallback.t.sol

    function test_forwardsAddrCall_whenResolvingRootName() public {
        bytes memory data = abi.encodeWithSelector(ADDR_SELECTOR, PARENT_NODE);
        (, bytes memory response) = address(resolver).call{value: 0}(data);
        (address resolvedAddress) = abi.decode(response, (address));
        assert(resolvedAddress == rootResolver.parentAddress());
    }

    function test_forwardsTextCall_whenResolvingRootName() public {
        bytes memory data = abi.encodeWithSelector(TEXT_SELECTOR, PARENT_NODE, "test");
        (, bytes memory response) = address(resolver).call{value: 0}(data);
        (string memory resolvedText) = abi.decode(response, (string));
        assert(keccak256(bytes(resolvedText)) == keccak256(bytes(rootResolver.TEST_TEXT())));
    }

    /// One fuzzed label under the parent name, DNS-encoded.
    function _subname(string memory label) internal pure returns (bytes memory) {
        bytes memory raw = bytes(label);
        vm.assume(raw.length > 0 && raw.length < 64);
        for (uint256 i; i < raw.length; i++) {
            vm.assume(raw[i] != ".");
        }

        return abi.encodePacked(uint8(raw.length), raw, PARENT_NAME);
    }

    function _setupProofCallback(string memory label)
        internal
        returns (address expectedAddress, bytes memory callData, bytes memory result)
    {
        bytes memory dnsName = _subname(label);
        expectedAddress = makeAddr(label);
        bytes memory data = abi.encodeWithSelector(ADDR_SELECTOR, keccak256(dnsName));
        callData = abi.encodeWithSelector(resolver.resolve.selector, dnsName, data);
        result = abi.encode(expectedAddress);
    }
}
