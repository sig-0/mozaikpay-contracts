// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAddrResolver} from "ens-contracts/resolvers/profiles/IAddrResolver.sol";
import {IExtendedResolver} from "ens-contracts/resolvers/profiles/IExtendedResolver.sol";
import {ITextResolver} from "ens-contracts/resolvers/profiles/ITextResolver.sol";
import {NameCoder} from "ens-contracts/utils/NameCoder.sol";

import {MozaikL1Resolver} from "../../src/ens/MozaikL1Resolver.sol";
import {SignatureVerifier} from "../../src/ens/SignatureVerifier.sol";

/// @dev Stands in for the ENS public resolver that holds the parent name's own records.
contract RootResolverMock is ERC165 {
    string public constant TEST_TEXT = "parent text";

    address public parentAddress;

    constructor(address parentAddress_) {
        parentAddress = parentAddress_;
    }

    function addr(bytes32) external view returns (address) {
        return parentAddress;
    }

    function text(bytes32, string calldata) external pure returns (string memory) {
        return TEST_TEXT;
    }

    function fail() external pure {
        revert("root: failed");
    }

    function supportsInterface(bytes4 interfaceID) public view override returns (bool) {
        return interfaceID == type(IAddrResolver).interfaceId || interfaceID == type(ITextResolver).interfaceId
            || super.supportsInterface(interfaceID);
    }
}

contract MozaikL1ResolverTest is Test {
    string internal constant GATEWAY_URL = "https://ens.example/{sender}/{data}.json";

    MozaikL1Resolver internal resolver;
    RootResolverMock internal root;

    // DNS-encoded mozaikpay.eth and juan.mozaikpay.eth
    bytes internal parentName;
    bytes internal subname;

    address internal owner;
    address internal signer;
    uint256 internal signerKey;
    address internal attacker;
    uint256 internal attackerKey;
    address internal parentAddress;
    address internal resolved;

    bytes internal innerCall;

    function setUp() public {
        owner = makeAddr("owner");
        parentAddress = makeAddr("parentAddress");
        resolved = makeAddr("resolved");
        (signer, signerKey) = makeAddrAndKey("gatewaySigner");
        (attacker, attackerKey) = makeAddrAndKey("attacker");

        root = new RootResolverMock(parentAddress);

        parentName = NameCoder.encode("mozaikpay.eth");
        subname = NameCoder.encode("juan.mozaikpay.eth");

        address[] memory initialSigners = new address[](1);
        initialSigners[0] = signer;

        resolver = new MozaikL1Resolver(GATEWAY_URL, initialSigners, owner, address(root), parentName);

        innerCall = abi.encodeWithSelector(IAddrResolver.addr.selector, bytes32(0));
    }

    function test_Constructor_StoresConfig() public view {
        assertEq(resolver.url(), GATEWAY_URL);
        assertEq(resolver.owner(), owner);
        assertEq(resolver.rootResolver(), address(root));
        assertEq(resolver.PARENT_NAME_HASH(), keccak256(parentName));
        assertTrue(resolver.signers(signer));
        assertFalse(resolver.signers(attacker));
    }

    function test_Constructor_EmitsAddedSigners() public {
        address[] memory initialSigners = new address[](2);
        initialSigners[0] = signer;
        initialSigners[1] = attacker;

        vm.expectEmit(true, true, true, true);
        emit MozaikL1Resolver.AddedSigners(initialSigners);

        new MozaikL1Resolver(GATEWAY_URL, initialSigners, owner, address(root), parentName);
    }

    function test_Constructor_RejectsZeroRootResolver() public {
        address[] memory initialSigners = new address[](1);
        initialSigners[0] = signer;

        vm.expectRevert(MozaikL1Resolver.ZeroAddress.selector);
        new MozaikL1Resolver(GATEWAY_URL, initialSigners, owner, address(0), parentName);
    }

    function test_SupportsInterface_ExtendedResolver() public view {
        assertEq(type(IExtendedResolver).interfaceId, bytes4(0x9061b923));
        assertTrue(resolver.supportsInterface(type(IExtendedResolver).interfaceId));
        assertTrue(resolver.supportsInterface(type(IERC165).interfaceId));
    }

    function test_SupportsInterface_DelegatesToRootResolver() public view {
        assertTrue(resolver.supportsInterface(type(IAddrResolver).interfaceId));
        assertTrue(resolver.supportsInterface(type(ITextResolver).interfaceId));
    }

    function test_SupportsInterface_RejectsUnknown() public view {
        assertFalse(resolver.supportsInterface(0xffffffff));
    }

    function test_SetUrl_UpdatesUrl() public {
        vm.expectEmit(true, true, true, true);
        emit MozaikL1Resolver.UrlChanged("https://ens2.example/{sender}/{data}.json");

        vm.prank(owner);
        resolver.setUrl("https://ens2.example/{sender}/{data}.json");

        assertEq(resolver.url(), "https://ens2.example/{sender}/{data}.json");
    }

    function test_SetUrl_NonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        resolver.setUrl("https://evil.example/{sender}/{data}.json");

        assertEq(resolver.url(), GATEWAY_URL);
    }

    function test_AddSigners_ApprovesSigners() public {
        address[] memory added = new address[](1);
        added[0] = attacker;

        vm.expectEmit(true, true, true, true);
        emit MozaikL1Resolver.AddedSigners(added);

        vm.prank(owner);
        resolver.addSigners(added);

        assertTrue(resolver.signers(attacker));
    }

    function test_AddSigners_NonOwner() public {
        address[] memory added = new address[](1);
        added[0] = attacker;

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        resolver.addSigners(added);

        assertFalse(resolver.signers(attacker));
    }

    function test_RemoveSigner_RevokesSigner() public {
        vm.expectEmit(true, true, true, true);
        emit MozaikL1Resolver.RemovedSigner(signer);

        vm.prank(owner);
        resolver.removeSigner(signer);

        assertFalse(resolver.signers(signer));
    }

    function test_RemoveSigner_NonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        resolver.removeSigner(signer);

        assertTrue(resolver.signers(signer));
    }

    function test_RemoveSigner_UnknownSignerIsNoOp() public {
        vm.recordLogs();

        vm.prank(owner);
        resolver.removeSigner(attacker);

        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_SetRootResolver_UpdatesResolver() public {
        RootResolverMock other = new RootResolverMock(attacker);

        vm.expectEmit(true, true, true, true);
        emit MozaikL1Resolver.RootResolverChanged(address(other));

        vm.prank(owner);
        resolver.setRootResolver(address(other));

        assertEq(resolver.rootResolver(), address(other));
    }

    function test_SetRootResolver_NonOwner() public {
        RootResolverMock other = new RootResolverMock(attacker);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        resolver.setRootResolver(address(other));

        assertEq(resolver.rootResolver(), address(root));
    }

    function test_SetRootResolver_ZeroAddress() public {
        vm.expectRevert(MozaikL1Resolver.ZeroAddress.selector);
        vm.prank(owner);
        resolver.setRootResolver(address(0));
    }

    function test_RenounceOwnership_Reverts() public {
        vm.expectRevert(MozaikL1Resolver.RenounceDisabled.selector);
        vm.prank(owner);
        resolver.renounceOwnership();

        assertEq(resolver.owner(), owner);
    }

    function test_RenounceOwnership_RevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        resolver.renounceOwnership();

        assertEq(resolver.owner(), owner);
    }

    function test_TransferOwnership_TwoStep() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        resolver.transferOwnership(newOwner);

        assertEq(resolver.owner(), owner);
        assertEq(resolver.pendingOwner(), newOwner);

        vm.prank(newOwner);
        resolver.acceptOwnership();

        assertEq(resolver.owner(), newOwner);
    }

    function test_Resolve_RevertsWithOffchainLookup() public {
        bytes memory callData = _request();
        string[] memory urls = new string[](1);
        urls[0] = GATEWAY_URL;

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
        resolver.resolve(subname, innerCall);
    }

    function test_ResolveWithProof_AcceptsSignedResponse() public view {
        bytes memory request = _request();
        bytes memory result = abi.encode(resolved);
        uint64 expires = uint64(block.timestamp + 5 minutes);

        bytes memory out = resolver.resolveWithProof(_response(request, result, expires, signerKey), request);

        assertEq(out, result);
    }

    function test_ResolveWithProof_AcceptsExpiryAtCurrentBlock() public view {
        bytes memory request = _request();
        bytes memory result = abi.encode(resolved);

        bytes memory out =
            resolver.resolveWithProof(_response(request, result, uint64(block.timestamp), signerKey), request);

        assertEq(out, result);
    }

    function test_ResolveWithProof_RejectsUnknownSigner() public {
        bytes memory request = _request();
        bytes memory response = _response(request, abi.encode(resolved), uint64(block.timestamp + 1), attackerKey);

        vm.expectRevert(MozaikL1Resolver.InvalidSigner.selector);
        resolver.resolveWithProof(response, request);
    }

    function test_ResolveWithProof_RejectsExpiredResponse() public {
        vm.warp(1_800_000_000);

        bytes memory request = _request();
        bytes memory response = _response(request, abi.encode(resolved), uint64(block.timestamp - 1), signerKey);

        vm.expectRevert(SignatureVerifier.SignatureExpired.selector);
        resolver.resolveWithProof(response, request);
    }

    function test_ResolveWithProof_RejectsTamperedResult() public {
        bytes memory request = _request();
        uint64 expires = uint64(block.timestamp + 5 minutes);

        (, uint64 signedExpires, bytes memory sig) =
            abi.decode(_response(request, abi.encode(resolved), expires, signerKey), (bytes, uint64, bytes));
        bytes memory forgedResponse = abi.encode(abi.encode(attacker), signedExpires, sig);

        vm.expectRevert(MozaikL1Resolver.InvalidSigner.selector);
        resolver.resolveWithProof(forgedResponse, request);
    }

    function test_ResolveWithProof_RejectsTamperedRequest() public {
        bytes memory request = _request();
        bytes memory response = _response(request, abi.encode(resolved), uint64(block.timestamp + 1), signerKey);
        bytes memory otherRequest = abi.encodeWithSelector(IExtendedResolver.resolve.selector, subname, hex"deadbeef");

        vm.expectRevert(MozaikL1Resolver.InvalidSigner.selector);
        resolver.resolveWithProof(response, otherRequest);
    }

    function test_ResolveWithProof_RejectsResponseSignedForAnotherResolver() public {
        address[] memory initialSigners = new address[](1);
        initialSigners[0] = signer;
        MozaikL1Resolver other = new MozaikL1Resolver(GATEWAY_URL, initialSigners, owner, address(root), parentName);

        bytes memory request = _request();
        bytes memory result = abi.encode(resolved);
        uint64 expires = uint64(block.timestamp + 1);

        // Signed for `other`, presented to `resolver`.
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerKey, other.makeSignatureHash(address(other), expires, request, result));
        bytes memory response = abi.encode(result, expires, abi.encodePacked(r, s, v));

        vm.expectRevert(MozaikL1Resolver.InvalidSigner.selector);
        resolver.resolveWithProof(response, request);
    }

    function test_SignerRotation_OverlapThenRevoke() public {
        (address nextSigner, uint256 nextKey) = makeAddrAndKey("nextSigner");
        address[] memory added = new address[](1);
        added[0] = nextSigner;

        bytes memory request = _request();
        bytes memory result = abi.encode(resolved);
        uint64 expires = uint64(block.timestamp + 1);

        vm.prank(owner);
        resolver.addSigners(added);

        // Both keys are valid during the overlap
        assertEq(resolver.resolveWithProof(_response(request, result, expires, signerKey), request), result);
        assertEq(resolver.resolveWithProof(_response(request, result, expires, nextKey), request), result);

        vm.prank(owner);
        resolver.removeSigner(signer);

        bytes memory stale = _response(request, result, expires, signerKey);

        vm.expectRevert(MozaikL1Resolver.InvalidSigner.selector);
        resolver.resolveWithProof(stale, request);

        assertEq(resolver.resolveWithProof(_response(request, result, expires, nextKey), request), result);
    }

    // Fixed vector the gateway implementation must reproduce.
    function test_MakeSignatureHash_MatchesGatewayVector() public view {
        bytes32 digest = resolver.makeSignatureHash(
            0xaabbCCDdeeaABBcCddeeaABbCCDdEeAabBccDDee,
            1_800_000_300,
            hex"00112233",
            hex"000000000000000000000000aabbccddeeaabbccddeeaabbccddeeaabbccddee"
        );

        assertEq(digest, 0xf4393f8b065ef7599feee4587ed75bdc1b00bc6f6635a9ca2469147fcf37878e);
    }

    function testFuzz_ResolveWithProof_AcceptsAnyUnexpiredResult(bytes memory result, uint64 ttl) public view {
        ttl = uint64(bound(ttl, 0, 365 days));

        bytes memory request = _request();
        bytes memory out =
            resolver.resolveWithProof(_response(request, result, uint64(block.timestamp) + ttl, signerKey), request);

        assertEq(out, result);
    }

    function testFuzz_ResolveWithProof_RejectsAnyExpiredResponse(bytes memory result, uint64 age) public {
        vm.warp(1_800_000_000);
        age = uint64(bound(age, 1, 365 days));

        bytes memory request = _request();
        bytes memory response = _response(request, result, uint64(block.timestamp) - age, signerKey);

        vm.expectRevert(SignatureVerifier.SignatureExpired.selector);
        resolver.resolveWithProof(response, request);
    }

    function test_Resolve_ParentNameUsesRootResolver() public view {
        bytes memory out = resolver.resolve(parentName, innerCall);

        assertEq(abi.decode(out, (address)), parentAddress);
    }

    function test_Resolve_ParentNameBubblesRootRevert() public {
        bytes memory failing = abi.encodeWithSelector(RootResolverMock.fail.selector);

        vm.expectRevert("root: failed");
        resolver.resolve(parentName, failing);
    }

    function test_Fallback_ForwardsToRootResolver() public {
        (bool ok, bytes memory out) = address(resolver).call(innerCall);

        assertTrue(ok);
        assertEq(abi.decode(out, (address)), parentAddress);
    }

    function test_Fallback_BubblesRootRevert() public {
        (bool ok, bytes memory out) = address(resolver).call(abi.encodeWithSelector(RootResolverMock.fail.selector));

        assertFalse(ok);
        assertEq(out, abi.encodeWithSignature("Error(string)", "root: failed"));
    }

    function _request() internal view returns (bytes memory) {
        return abi.encodeWithSelector(IExtendedResolver.resolve.selector, subname, innerCall);
    }

    function _response(bytes memory request, bytes memory result, uint64 expires, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = resolver.makeSignatureHash(address(resolver), expires, request, result);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);

        return abi.encode(result, expires, abi.encodePacked(r, s, v));
    }
}
