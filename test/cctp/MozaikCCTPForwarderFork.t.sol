// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MozaikCCTPForwarder} from "../../src/cctp/MozaikCCTPForwarder.sol";
import {MozaikCCTPForwarderFactory} from "../../src/cctp/MozaikCCTPForwarderFactory.sol";
import {ITokenMessengerV2} from "../../src/cctp/ITokenMessengerV2.sol";
import {CCTPForwarderRecord} from "../../script/cctp/CCTPForwarderRecord.sol";

/// @notice The parts of Circle's MessageTransmitterV2 that the end-to-end rescue tests use.
interface ICircleMessageTransmitterV2 {
    function version() external view returns (uint32);
    function localDomain() external view returns (uint32);
    function attesterManager() external view returns (address);
    function signatureThreshold() external view returns (uint256);
    function enableAttester(address newAttester) external;
    function setSignatureThreshold(uint256 newSignatureThreshold) external;
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool);
}

/// @notice Fork tests against Circle's live CCTP V2 contracts. Each test deploys the frozen v1 record of its
///         environment through Nick's deployer, checks that the golden vector holds on that chain, and runs real
///         burns, transfers and rescues.
/// @dev    Each chain's RPC variable overrides its public default.
contract MozaikCCTPForwarderForkTest is Test, CCTPForwarderRecord {
    string internal constant MAINNET_RECORD = "script/cctp/forwarder-v1.json";
    string internal constant SEPOLIA_RECORD = "script/cctp/forwarder-v1-sepolia.json";

    address internal constant ETHEREUM_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant POLYGON_USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;

    string internal constant ETHEREUM_PUBLIC_RPC = "https://ethereum-rpc.publicnode.com";
    string internal constant ARBITRUM_PUBLIC_RPC = "https://arb1.arbitrum.io/rpc";
    string internal constant POLYGON_PUBLIC_RPC = "https://polygon.drpc.org";
    string internal constant BASE_PUBLIC_RPC = "https://mainnet.base.org";
    string internal constant BASE_SEPOLIA_PUBLIC_RPC = "https://sepolia.base.org";

    bytes32 internal constant MESSAGE_SENT = keccak256("MessageSent(bytes)");

    uint256 internal constant AMOUNT = 50_000_000; // 50 USDC
    uint256 internal constant FEE_CAP = AMOUNT * 20 / 10_000; // 20 bps

    ITokenMessengerV2 internal messenger;
    address internal baseUsdc;
    MozaikCCTPForwarderFactory internal factory;
    address internal account;
    address internal forwarder;

    /// @dev An empty RPC variable counts as unset.
    modifier onFork(string memory rpcVar, string memory publicRpc) {
        string memory rpc = vm.envOr(rpcVar, string(""));
        vm.createSelectFork(bytes(rpc).length == 0 ? publicRpc : rpc);
        _;
    }

    /// @dev Deploys the recorded contracts (or reuses them if already live) and checks the golden vector.
    function _setupFork(string memory recordPath) internal {
        ForwarderRecord memory record = _readForwarderRecord(recordPath);
        _deployRecorded(record.implementation);
        _deployRecorded(record.factory);

        assertEq(record.implementation.addr.codehash, record.implementation.codeHash, "implementation code hash");
        assertEq(record.factory.addr.codehash, record.factory.codeHash, "factory code hash");

        messenger = ITokenMessengerV2(record.tokenMessenger);
        baseUsdc = record.baseUsdc;
        factory = MozaikCCTPForwarderFactory(record.factory.addr);
        assertEq(factory.predict(record.goldenAccount), record.goldenForwarder, "golden forwarder");

        account = makeAddr("forkAccount");
        forwarder = factory.predict(account);
    }

    function _fund(address token, uint256 amount) internal {
        deal(token, forwarder, amount, true);
        require(IERC20(token).balanceOf(forwarder) == amount, "deal: USDC balance setup failed");
    }

    function _assertLinked(address localUsdc) internal view {
        address found = messenger.localMinter().getLocalToken(6, bytes32(uint256(uint160(baseUsdc))));
        assertEq(found, localUsdc, "getLocalToken");
    }

    /// @dev Runs deployAndForward from an outside caller and checks the MessageSent bytes field by field.
    function _burnAndCheck(address usdc, uint32 sourceDomain, uint256 maxFee, uint32 threshold) internal {
        _fund(usdc, AMOUNT);
        address transmitter = messenger.localMessageTransmitter();
        address caller = makeAddr("forkCaller");

        vm.recordLogs();
        vm.prank(caller, caller);
        factory.deployAndForward(account, AMOUNT, maxFee, threshold);

        bytes memory message = _messageSent(vm.getRecordedLogs(), transmitter);

        assertEq(message.length, 148 + 228, "header plus burn body without hook");
        assertEq(_u32(message, 4), sourceDomain, "source domain");
        assertEq(_u32(message, 8), 6, "destination domain");
        assertEq(_b32(message, 44), bytes32(uint256(uint160(address(messenger)))), "sender");
        assertEq(_b32(message, 76), bytes32(uint256(uint160(address(messenger)))), "recipient");
        assertEq(_b32(message, 108), bytes32(0), "destination caller");
        assertEq(_u32(message, 140), threshold, "min finality threshold");

        assertEq(_b32(message, 148 + 4), bytes32(uint256(uint160(usdc))), "burn token");
        assertEq(_b32(message, 148 + 36), bytes32(uint256(uint160(account))), "mint recipient");
        assertEq(uint256(_b32(message, 148 + 68)), AMOUNT, "amount");
        assertEq(_b32(message, 148 + 100), bytes32(uint256(uint160(forwarder))), "message sender");
        assertEq(uint256(_b32(message, 148 + 132)), maxFee, "max fee");

        assertEq(IERC20(usdc).balanceOf(forwarder), 0, "forwarder emptied");
        assertEq(IERC20(usdc).allowance(forwarder, address(messenger)), 0, "no leftover allowance");
    }

    function _messageSent(Vm.Log[] memory logs, address transmitter) internal pure returns (bytes memory message) {
        uint256 found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == transmitter && logs[i].topics[0] == MESSAGE_SENT) {
                message = abi.decode(logs[i].data, (bytes));
                found++;
            }
        }
        require(found == 1, "expected one MessageSent");
    }

    function _b32(bytes memory data, uint256 offset) internal pure returns (bytes32 value) {
        assembly {
            value := mload(add(add(data, 32), offset))
        }
    }

    function _u32(bytes memory data, uint256 offset) internal pure returns (uint32) {
        return uint32(bytes4(_b32(data, offset)));
    }

    function _baseTransferAndRescue() internal {
        _fund(baseUsdc, AMOUNT);
        uint256 before = IERC20(baseUsdc).balanceOf(account);

        vm.prank(makeAddr("forkCaller"));
        factory.deployAndForward(account, AMOUNT, 0, 0);

        assertEq(IERC20(baseUsdc).balanceOf(account), before + AMOUNT, "account credited");
        assertEq(IERC20(baseUsdc).balanceOf(forwarder), 0, "forwarder emptied");

        _fund(baseUsdc, AMOUNT);
        vm.deal(forwarder, 1 ether);
        address to = makeAddr("forkRescueTo");

        vm.startPrank(account);
        MozaikCCTPForwarder(forwarder).rescue(baseUsdc, to, AMOUNT);
        MozaikCCTPForwarder(forwarder).rescue(address(0), to, 1 ether);
        vm.stopPrank();

        assertEq(IERC20(baseUsdc).balanceOf(to), AMOUNT, "USDC rescued");
        assertEq(to.balance, 1 ether, "native rescued");
    }

    function test_Fork_EthereumFastAtFeeCap() public onFork("ETH_MAINNET_RPC", ETHEREUM_PUBLIC_RPC) {
        _setupFork(MAINNET_RECORD);
        _assertLinked(ETHEREUM_USDC);

        _burnAndCheck(ETHEREUM_USDC, 0, FEE_CAP, 1000);
    }

    function test_Fork_EthereumFastWithZeroFeeDoesNotRevert() public onFork("ETH_MAINNET_RPC", ETHEREUM_PUBLIC_RPC) {
        _setupFork(MAINNET_RECORD);

        _burnAndCheck(ETHEREUM_USDC, 0, 0, 1000);
    }

    function test_Fork_EthereumStandard() public onFork("ETH_MAINNET_RPC", ETHEREUM_PUBLIC_RPC) {
        _setupFork(MAINNET_RECORD);

        _burnAndCheck(ETHEREUM_USDC, 0, 0, 2000);
    }

    function test_Fork_ArbitrumFastAtFeeCap() public onFork("ARBITRUM_MAINNET_RPC", ARBITRUM_PUBLIC_RPC) {
        _setupFork(MAINNET_RECORD);
        _assertLinked(ARBITRUM_USDC);

        _burnAndCheck(ARBITRUM_USDC, 3, FEE_CAP, 1000);
    }

    function test_Fork_ArbitrumStandard() public onFork("ARBITRUM_MAINNET_RPC", ARBITRUM_PUBLIC_RPC) {
        _setupFork(MAINNET_RECORD);

        _burnAndCheck(ARBITRUM_USDC, 3, 0, 2000);
    }

    function test_Fork_ArbitrumStandardAtFeeCap() public onFork("ARBITRUM_MAINNET_RPC", ARBITRUM_PUBLIC_RPC) {
        _setupFork(MAINNET_RECORD);

        _burnAndCheck(ARBITRUM_USDC, 3, FEE_CAP, 2000);
    }

    function test_Fork_ArbitrumRescueByMessage() public onFork("ARBITRUM_MAINNET_RPC", ARBITRUM_PUBLIC_RPC) {
        _setupFork(MAINNET_RECORD);
        factory.deploy(account);
        _fund(ARBITRUM_USDC, AMOUNT);
        address to = makeAddr("forkRescueTo");

        vm.prank(messenger.localMessageTransmitter());
        MozaikCCTPForwarder(forwarder)
            .handleReceiveFinalizedMessage(
                6, bytes32(uint256(uint160(account))), 2000, abi.encode(ARBITRUM_USDC, to, AMOUNT, block.timestamp)
            );

        assertEq(IERC20(ARBITRUM_USDC).balanceOf(to), AMOUNT);

        vm.prank(account);
        vm.expectRevert(MozaikCCTPForwarder.UnsupportedChain.selector);
        MozaikCCTPForwarder(forwarder).rescue(ARBITRUM_USDC, to, 0);
    }

    function test_Fork_ArbitrumRescueThroughReceiveMessage()
        public
        onFork("ARBITRUM_MAINNET_RPC", ARBITRUM_PUBLIC_RPC)
    {
        _setupFork(MAINNET_RECORD);
        factory.deploy(account);
        _fund(ARBITRUM_USDC, AMOUNT);
        address to = makeAddr("forkRescueTo");

        (bytes memory message, bytes memory attestation) = _signedRescue(2000, to);
        ICircleMessageTransmitterV2 transmitter = _transmitter();

        vm.prank(makeAddr("forkRelayer"));
        transmitter.receiveMessage(message, attestation);

        assertEq(IERC20(ARBITRUM_USDC).balanceOf(to), AMOUNT, "rescued through receiveMessage");
        assertEq(IERC20(ARBITRUM_USDC).balanceOf(forwarder), 0, "forwarder emptied");
    }

    function test_Fork_ArbitrumRescueRejectsFastMessage() public onFork("ARBITRUM_MAINNET_RPC", ARBITRUM_PUBLIC_RPC) {
        _setupFork(MAINNET_RECORD);
        factory.deploy(account);
        _fund(ARBITRUM_USDC, AMOUNT);

        (bytes memory message, bytes memory attestation) = _signedRescue(1000, makeAddr("forkRescueTo"));
        ICircleMessageTransmitterV2 transmitter = _transmitter();

        vm.expectRevert(MozaikCCTPForwarder.InvalidMessage.selector);
        transmitter.receiveMessage(message, attestation);

        assertEq(IERC20(ARBITRUM_USDC).balanceOf(forwarder), AMOUNT, "funds stay");
    }

    function _transmitter() internal view returns (ICircleMessageTransmitterV2) {
        return ICircleMessageTransmitterV2(messenger.localMessageTransmitter());
    }

    /// @dev Makes a test key the only attester the forked transmitter needs, then builds the message that the
    ///      account's sendMessage on Base produces, with the fields the attesters fill in, and signs it.
    function _signedRescue(uint32 finalityThresholdExecuted, address to)
        internal
        returns (bytes memory message, bytes memory attestation)
    {
        ICircleMessageTransmitterV2 transmitter = _transmitter();
        (address attester, uint256 attesterKey) = makeAddrAndKey("forkAttester");

        vm.startPrank(transmitter.attesterManager());
        transmitter.enableAttester(attester);
        if (transmitter.signatureThreshold() != 1) transmitter.setSignatureThreshold(1);
        vm.stopPrank();

        message = abi.encodePacked(
            transmitter.version(),
            uint32(6), // source domain: Base
            transmitter.localDomain(),
            keccak256(abi.encode("forkRescueNonce", finalityThresholdExecuted)),
            bytes32(uint256(uint160(account))), // sender: the account on Base
            bytes32(uint256(uint160(forwarder))), // recipient
            bytes32(0), // destination caller: anyone
            uint32(2000), // min finality threshold
            finalityThresholdExecuted,
            abi.encode(ARBITRUM_USDC, to, AMOUNT, block.timestamp + 1 hours)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterKey, keccak256(message));
        attestation = abi.encodePacked(r, s, v);
    }

    function test_Fork_PolygonStandard() public onFork("POLYGON_MAINNET_RPC", POLYGON_PUBLIC_RPC) {
        _setupFork(MAINNET_RECORD);
        _assertLinked(POLYGON_USDC);

        _burnAndCheck(POLYGON_USDC, 7, 0, 2000);
    }

    function test_Fork_PolygonFastWithZeroFee() public onFork("POLYGON_MAINNET_RPC", POLYGON_PUBLIC_RPC) {
        _setupFork(MAINNET_RECORD);

        _burnAndCheck(POLYGON_USDC, 7, 0, 1000);
    }

    function test_Fork_BaseTransferAndRescue() public onFork("BASE_MAINNET_RPC", BASE_PUBLIC_RPC) {
        _setupFork(MAINNET_RECORD);
        assertEq(block.chainid, 8453, "Base chain id");

        _baseTransferAndRescue();
    }

    function test_Fork_BaseSepoliaTransferAndRescue() public onFork("BASE_SEPOLIA_RPC", BASE_SEPOLIA_PUBLIC_RPC) {
        _setupFork(SEPOLIA_RECORD);
        assertEq(block.chainid, 84532, "Base Sepolia chain id");

        _baseTransferAndRescue();
    }
}
