// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MozaikCCTPForwarder} from "../../src/cctp/MozaikCCTPForwarder.sol";
import {MozaikCCTPForwarderFactory} from "../../src/cctp/MozaikCCTPForwarderFactory.sol";
import {IMessageHandlerV2} from "../../src/cctp/IMessageHandlerV2.sol";
import {ITokenMessengerV2} from "../../src/cctp/ITokenMessengerV2.sol";

/// @notice TokenMinterV2 stand-in with settable token links. Burned tokens stay in this contract.
contract MockTokenMinterV2 {
    mapping(uint32 => mapping(bytes32 => address)) internal _localTokens;

    function setLocalToken(uint32 remoteDomain, address remoteToken, address localToken) external {
        _localTokens[remoteDomain][bytes32(uint256(uint160(remoteToken)))] = localToken;
    }

    function getLocalToken(uint32 remoteDomain, bytes32 remoteToken) external view returns (address) {
        return _localTokens[remoteDomain][remoteToken];
    }
}

/// @notice MessageTransmitterV2 stand-in. deliver() routes a message to a recipient's handler the way
///         receiveMessage does once the attestation checks pass.
contract MockMessageTransmitterV2 {
    function deliver(
        address recipient,
        uint32 sourceDomain,
        bytes32 sender,
        uint32 finalityThresholdExecuted,
        bytes calldata messageBody
    ) external returns (bool) {
        if (finalityThresholdExecuted < 2000) {
            return IMessageHandlerV2(recipient)
                .handleReceiveUnfinalizedMessage(sourceDomain, sender, finalityThresholdExecuted, messageBody);
        }

        return IMessageHandlerV2(recipient)
            .handleReceiveFinalizedMessage(sourceDomain, sender, finalityThresholdExecuted, messageBody);
    }

    /// @notice Calls the finalized handler at any threshold, as a misrouting transmitter would.
    function deliverFinalized(
        address recipient,
        uint32 sourceDomain,
        bytes32 sender,
        uint32 finalityThresholdExecuted,
        bytes calldata messageBody
    ) external returns (bool) {
        return IMessageHandlerV2(recipient)
            .handleReceiveFinalizedMessage(sourceDomain, sender, finalityThresholdExecuted, messageBody);
    }
}

/// @notice TokenMessengerV2 stand-in. depositForBurn applies Circle's source-side argument checks, pulls the
///         tokens into the local minter and records the call.
contract MockTokenMessengerV2 {
    using SafeERC20 for IERC20;

    struct Burn {
        address depositor;
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinalityThreshold;
    }

    address public immutable localMessageTransmitter;
    address public immutable localMinter;

    Burn[] internal _burns;

    constructor(address transmitter, address minter) {
        localMessageTransmitter = transmitter;
        localMinter = minter;
    }

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external {
        require(amount > 0, "Amount must be nonzero");
        require(mintRecipient != bytes32(0), "Mint recipient must be nonzero");
        require(maxFee < amount, "Max fee must be less than amount");

        IERC20(burnToken).safeTransferFrom(msg.sender, localMinter, amount);

        _burns.push(
            Burn({
                depositor: msg.sender,
                amount: amount,
                destinationDomain: destinationDomain,
                mintRecipient: mintRecipient,
                burnToken: burnToken,
                destinationCaller: destinationCaller,
                maxFee: maxFee,
                minFinalityThreshold: minFinalityThreshold
            })
        );
    }

    function burnCount() external view returns (uint256) {
        return _burns.length;
    }

    function burnAt(uint256 index) external view returns (Burn memory) {
        return _burns[index];
    }
}

/// @notice Shared setup for the CCTP forwarder tests. Deploys CCTP stand-ins, a Base USDC and a source-chain USDC
///         linked to it, and a forwarder for `account`. Tests start on a source chain (Arbitrum's chain id).
abstract contract CCTPBaseTest is Test {
    uint256 internal constant BASE_CHAIN_ID = 8453;
    uint256 internal constant SOURCE_CHAIN_ID = 42161;
    uint32 internal constant BASE_DOMAIN = 6;

    MockTokenMessengerV2 internal messenger;
    MockMessageTransmitterV2 internal transmitter;
    MockTokenMinterV2 internal minter;

    /// @dev USDC on Base, the forwarder's BASE_USDC.
    ERC20Mock internal baseUsdc;

    /// @dev USDC on the source chain, linked to `baseUsdc` in the minter.
    ERC20Mock internal usdc;

    MozaikCCTPForwarder internal implementation;
    MozaikCCTPForwarderFactory internal factory;

    address internal account;
    MozaikCCTPForwarder internal forwarder;

    function setUp() public virtual {
        baseUsdc = new ERC20Mock();
        usdc = new ERC20Mock();

        transmitter = new MockMessageTransmitterV2();
        minter = new MockTokenMinterV2();
        messenger = new MockTokenMessengerV2(address(transmitter), address(minter));
        minter.setLocalToken(BASE_DOMAIN, address(baseUsdc), address(usdc));

        implementation =
            new MozaikCCTPForwarder(ITokenMessengerV2(address(messenger)), address(baseUsdc), BASE_CHAIN_ID);
        factory = new MozaikCCTPForwarderFactory(implementation);

        account = makeAddr("account");
        forwarder = MozaikCCTPForwarder(factory.deploy(account));

        vm.chainId(SOURCE_CHAIN_ID);
    }

    function _accountSender() internal view returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    /// @dev A rescue body whose deadline is the current block.
    function _rescueBody(address token, address to, uint256 amount) internal view returns (bytes memory) {
        return abi.encode(token, to, amount, block.timestamp);
    }
}
