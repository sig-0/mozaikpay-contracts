// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {MozaikCCTPForwarder} from "../../src/cctp/MozaikCCTPForwarder.sol";
import {MozaikCCTPForwarderFactory} from "../../src/cctp/MozaikCCTPForwarderFactory.sol";
import {ITokenMessengerV2} from "../../src/cctp/ITokenMessengerV2.sol";
import {MockMessageTransmitterV2, MockTokenMessengerV2, MockTokenMinterV2} from "../cctp/CCTPBaseTest.t.sol";

/// @notice Echidna fuzz target for MozaikCCTPForwarder and MozaikCCTPForwarderFactory.
/// @dev Drives Base-mode and source-mode forwarders for two accounts from varied callers, holding USDC, an
///      unrelated token and native coin. Each call is predicted to succeed or revert, and ghost totals pin every
///      balance.
contract CCTPEchidna {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant ACCOUNT_A = address(0xA11CE);
    address internal constant ACCOUNT_B = address(0xB0B);
    address internal constant RESCUE_TO = address(0xBEEF);

    uint32 internal constant BASE_DOMAIN = 6;
    uint32 internal constant FINALITY_FAST = 1000;
    uint32 internal constant FINALITY_STANDARD = 2000;

    /// @dev Base-mode implementations transfer on forward. Source-mode ones burn.
    uint256 internal constant BASE_MODE = 0;
    uint256 internal constant SOURCE_MODE = 1;

    /// @dev Slot = 2 * account index + mode. Slots 0 and 1 serve ACCOUNT_A, slots 2 and 3 serve ACCOUNT_B.
    uint256 internal constant SLOT_COUNT = 4;

    uint256 internal constant ASSET_BASE_USDC = 0;
    uint256 internal constant ASSET_LOCAL_USDC = 1;
    uint256 internal constant ASSET_OTHER = 2;
    uint256 internal constant ASSET_NATIVE = 3;
    uint256 internal constant ASSET_COUNT = 4;

    /// @dev Fuzzed forward inputs. Each case parameter picks a boundary value or keeps the fuzzed one.
    struct ForwardInput {
        uint8 amountCase;
        uint256 amountSeed;
        uint8 feeCase;
        uint256 feeSeed;
        uint8 thresholdCase;
        uint32 anyThreshold;
    }

    struct ForwardArgs {
        uint256 amount;
        uint256 maxFee;
        uint32 threshold;
    }

    /// @dev Fuzzed rescue message inputs. Each case parameter picks a boundary value or keeps the fuzzed one.
    struct MessageInput {
        uint8 slotSeed;
        uint8 assetSeed;
        uint8 amountCase;
        uint256 amountSeed;
        uint8 senderCase;
        bytes32 anySender;
        uint8 domainCase;
        uint32 anyDomain;
        uint8 thresholdCase;
        uint32 anyThreshold;
        uint8 deadlineCase;
        uint256 anyDeadline;
    }

    struct Message {
        uint256 slot;
        uint256 asset;
        uint256 amount;
        bytes32 sender;
        uint32 domain;
        uint32 threshold;
        uint256 deadline;
    }

    ERC20Mock internal baseUsdc;
    ERC20Mock internal localUsdc;
    ERC20Mock internal other;
    MockMessageTransmitterV2 internal transmitter;
    MockTokenMessengerV2 internal messenger;
    MockTokenMinterV2 internal minter;

    /// @dev Indexed by mode.
    MozaikCCTPForwarder[2] internal implementations;
    MozaikCCTPForwarderFactory[2] internal factories;

    /// @dev The account each implementation would report if it accepted direct calls.
    address[2] internal junkAccounts;

    address[SLOT_COUNT] internal forwarders;
    bool[SLOT_COUNT] internal deployed;
    bool internal linked;

    uint256[ASSET_COUNT][SLOT_COUNT] internal funded;
    uint256[ASSET_COUNT][SLOT_COUNT] internal rescued;
    uint256[SLOT_COUNT] internal forwarded;
    uint256[ASSET_COUNT][2] internal implementationFunded;
    uint256 internal burns;

    bool internal validCallReverted;
    bool internal invalidCallSucceeded;
    bool internal factoryMismatch;

    event ValidCallReverted(string action);
    event InvalidCallSucceeded(string action);

    constructor() payable {
        baseUsdc = new ERC20Mock();
        localUsdc = new ERC20Mock();
        other = new ERC20Mock();
        transmitter = new MockMessageTransmitterV2();
        minter = new MockTokenMinterV2();
        messenger = new MockTokenMessengerV2(address(transmitter), address(minter));
        minter.setLocalToken(BASE_DOMAIN, address(baseUsdc), address(localUsdc));
        linked = true;

        ITokenMessengerV2 tokenMessenger = ITokenMessengerV2(address(messenger));
        implementations[BASE_MODE] = new MozaikCCTPForwarder(tokenMessenger, address(baseUsdc), block.chainid);
        implementations[SOURCE_MODE] = new MozaikCCTPForwarder(tokenMessenger, address(baseUsdc), block.chainid + 1);

        for (uint256 i = 0; i < 2; i++) {
            factories[i] = new MozaikCCTPForwarderFactory(implementations[i]);
            junkAccounts[i] = address(bytes20(Clones.fetchCloneArgs(address(implementations[i]))));
        }

        for (uint256 slot = 0; slot < SLOT_COUNT; slot++) {
            forwarders[slot] = factories[_slotMode(slot)].predict(_account(slot));
        }

        // ACCOUNT_A's forwarders exist from the start. The fuzzer deploys ACCOUNT_B's.
        for (uint256 slot = 0; slot < 2; slot++) {
            if (factories[_slotMode(slot)].deploy(ACCOUNT_A) != forwarders[slot]) factoryMismatch = true;
            deployed[slot] = forwarders[slot].code.length > 0;
        }
    }

    /// @notice Mints a token to, or deals native coin to, a forwarder, deployed or not.
    function fundForwarder(uint8 slotSeed, uint8 assetSeed, uint96 amount) external {
        uint256 slot = _slot(slotSeed);
        uint256 asset = _asset(assetSeed);

        _give(forwarders[slot], asset, amount);
        funded[slot][asset] += amount;
    }

    /// @notice Mints a token to, or deals native coin to, an implementation.
    function fundImplementation(bool base, uint8 assetSeed, uint96 amount) external {
        uint256 mode = _mode(base);
        uint256 asset = _asset(assetSeed);

        _give(address(implementations[mode]), asset, amount);
        implementationFunded[mode][asset] += amount;
    }

    /// @notice Sends native coin to a forwarder with a plain call. Only an undeployed forwarder accepts it.
    function sendNativeToForwarder(uint8 slotSeed, uint64 amount, bytes calldata data) external {
        uint256 slot = _slot(slotSeed);
        if (_sendNative(forwarders[slot], amount, data)) funded[slot][ASSET_NATIVE] += amount;
    }

    /// @notice Sends native coin to an implementation with a plain call, which it must reject.
    function sendNativeToImplementation(bool base, uint64 amount, bytes calldata data) external {
        uint256 mode = _mode(base);
        if (_sendNative(address(implementations[mode]), amount, data)) {
            implementationFunded[mode][ASSET_NATIVE] += amount;
        }
    }

    /// @notice Removes or restores the minter's link from baseUsdc to localUsdc.
    function setLink(bool isLinked) external {
        linked = isLinked;
        minter.setLocalToken(BASE_DOMAIN, address(baseUsdc), isLinked ? address(localUsdc) : address(0));
    }

    /// @notice Deploys a slot's forwarder from any caller. Deploying an existing one returns it.
    function deploy(uint8 slotSeed, address caller) external {
        uint256 slot = _slot(slotSeed);
        bytes memory data = abi.encodeCall(MozaikCCTPForwarderFactory.deploy, (_account(slot)));

        (bool ok, bytes memory returned) = _callAs(caller, address(factories[_slotMode(slot)]), data);
        _check(true, ok, "deploy");
        if (ok) _recordDeploy(slot, abi.decode(returned, (address)));
    }

    /// @notice Deploys a forwarder for the zero account, which the factory must refuse.
    function deployForZeroAccount(bool base, address caller) external {
        bytes memory data = abi.encodeCall(MozaikCCTPForwarderFactory.deploy, (address(0)));

        (bool ok,) = _callAs(caller, address(factories[_mode(base)]), data);
        _check(false, ok, "deployForZeroAccount");
    }

    /// @notice Deploys a slot's forwarder if needed and forwards from it, from any caller.
    function deployAndForward(uint8 slotSeed, address caller, ForwardInput calldata input) external {
        uint256 slot = _slot(slotSeed);
        ForwardArgs memory args = _forwardArgs(slot, input);
        bool valid = _expectForward(slot, args);
        bytes memory data = abi.encodeCall(
            MozaikCCTPForwarderFactory.deployAndForward, (_account(slot), args.amount, args.maxFee, args.threshold)
        );

        (bool ok, bytes memory returned) = _callAs(caller, address(factories[_slotMode(slot)]), data);
        _check(valid, ok, "deployAndForward");
        if (!ok) return;

        _recordDeploy(slot, abi.decode(returned, (address)));
        _recordForward(slot, args.amount);
    }

    /// @notice Calls deployAndForward for the zero account, which the factory must refuse.
    function deployAndForwardForZeroAccount(bool base, address caller, uint256 amount, uint256 maxFee, uint32 threshold)
        external
    {
        bytes memory data =
            abi.encodeCall(MozaikCCTPForwarderFactory.deployAndForward, (address(0), amount, maxFee, threshold));

        (bool ok,) = _callAs(caller, address(factories[_mode(base)]), data);
        _check(false, ok, "deployAndForwardForZeroAccount");
    }

    /// @notice Calls forward on a deployed forwarder from any caller.
    function forward(uint8 slotSeed, address caller, ForwardInput calldata input) external {
        uint256 slot = _slot(slotSeed);
        if (!deployed[slot]) return;

        ForwardArgs memory args = _forwardArgs(slot, input);
        bool valid = _expectForward(slot, args);
        bytes memory data = abi.encodeCall(MozaikCCTPForwarder.forward, (args.amount, args.maxFee, args.threshold));

        (bool ok,) = _callAs(caller, forwarders[slot], data);
        _check(valid, ok, "forward");
        if (ok) _recordForward(slot, args.amount);
    }

    /// @notice Calls rescue on a deployed forwarder from the account, the other account, the harness or anyone.
    function rescueDirect(
        uint8 slotSeed,
        uint8 callerCase,
        address anyCaller,
        uint8 assetSeed,
        uint8 amountCase,
        uint256 amountSeed
    ) external {
        uint256 slot = _slot(slotSeed);
        if (!deployed[slot]) return;

        uint256 asset = _asset(assetSeed);
        uint256 amount = _amount(amountCase, amountSeed, _balance(asset, forwarders[slot]));
        address caller = _rescueCaller(slot, callerCase, anyCaller);
        bool valid = _expectRescue(slot, caller, asset, amount);
        bytes memory data = abi.encodeCall(MozaikCCTPForwarder.rescue, (_token(asset), RESCUE_TO, amount));

        (bool ok,) = _callAs(caller, forwarders[slot], data);
        _check(valid, ok, "rescueDirect");
        if (ok) rescued[slot][asset] += amount;
    }

    /// @notice Delivers a rescue message through the transmitter, which routes it by its threshold.
    function deliverMessage(MessageInput calldata input) external {
        uint256 slot = _slot(input.slotSeed);
        if (!deployed[slot]) return;

        Message memory message = _message(slot, input);
        bool valid = _expectMessage(message, address(transmitter));
        bytes memory data = abi.encodeCall(
            MockMessageTransmitterV2.deliver,
            (forwarders[slot], message.domain, message.sender, message.threshold, _body(message))
        );

        (bool ok, bytes memory returned) = address(transmitter).call(data);
        _settleMessage(message, valid, ok, returned, "deliverMessage");
    }

    /// @notice Delivers a rescue message to the finalized handler at any threshold, as a misrouting transmitter would.
    function deliverMisroutedMessage(MessageInput calldata input) external {
        uint256 slot = _slot(input.slotSeed);
        if (!deployed[slot]) return;

        Message memory message = _message(slot, input);
        bool valid = _expectMessage(message, address(transmitter));
        bytes memory data = abi.encodeCall(
            MockMessageTransmitterV2.deliverFinalized,
            (forwarders[slot], message.domain, message.sender, message.threshold, _body(message))
        );

        (bool ok, bytes memory returned) = address(transmitter).call(data);
        _settleMessage(message, valid, ok, returned, "deliverMisroutedMessage");
    }

    /// @notice Calls the finalized handler directly as the transmitter, the account or the harness.
    function callFinalizedHandler(MessageInput calldata input, uint8 callerCase) external {
        uint256 slot = _slot(input.slotSeed);
        if (!deployed[slot]) return;

        Message memory message = _message(slot, input);
        address caller = _handlerCaller(slot, callerCase);
        bool valid = _expectMessage(message, caller);
        bytes memory data = abi.encodeCall(
            MozaikCCTPForwarder.handleReceiveFinalizedMessage,
            (message.domain, message.sender, message.threshold, _body(message))
        );

        (bool ok, bytes memory returned) = _callAs(caller, forwarders[slot], data);
        _settleMessage(message, valid, ok, returned, "callFinalizedHandler");
    }

    /// @notice Calls the unfinalized handler directly, which must always revert.
    function callUnfinalizedHandler(MessageInput calldata input) external {
        uint256 slot = _slot(input.slotSeed);
        if (!deployed[slot]) return;

        Message memory message = _message(slot, input);
        bytes memory data = abi.encodeCall(
            MozaikCCTPForwarder.handleReceiveUnfinalizedMessage,
            (message.domain, message.sender, message.threshold, _body(message))
        );

        (bool ok, bytes memory returned) = forwarders[slot].call(data);
        _settleMessage(message, false, ok, returned, "callUnfinalizedHandler");
    }

    /// @notice Calls forward on an implementation from any caller, which must revert.
    function forwardFromImplementation(bool base, address caller, uint8 amountCase, uint256 amountSeed) external {
        uint256 mode = _mode(base);
        uint256 amount = _implementationAmount(mode, amountCase, amountSeed);
        bytes memory data = abi.encodeCall(MozaikCCTPForwarder.forward, (amount, 0, FINALITY_STANDARD));

        (bool ok,) = _callAs(caller, address(implementations[mode]), data);
        _check(false, ok, "forwardFromImplementation");
    }

    /// @notice Calls rescue on an implementation as the account it would report, which must revert.
    function rescueFromImplementation(bool base, uint8 amountCase, uint256 amountSeed) external {
        uint256 mode = _mode(base);
        uint256 amount = _implementationAmount(mode, amountCase, amountSeed);
        bytes memory data = abi.encodeCall(MozaikCCTPForwarder.rescue, (_token(_forwardAsset(mode)), RESCUE_TO, amount));

        (bool ok,) = _callAs(junkAccounts[mode], address(implementations[mode]), data);
        _check(false, ok, "rescueFromImplementation");
    }

    /// @notice Sends an implementation a rescue message from the account it would report, which must revert.
    function messageImplementation(bool base, uint8 amountCase, uint256 amountSeed) external {
        uint256 mode = _mode(base);
        uint256 amount = _implementationAmount(mode, amountCase, amountSeed);
        bytes memory body = abi.encode(_token(_forwardAsset(mode)), RESCUE_TO, amount, block.timestamp);
        bytes memory data = abi.encodeCall(
            MockMessageTransmitterV2.deliver,
            (address(implementations[mode]), BASE_DOMAIN, _padded(junkAccounts[mode]), FINALITY_STANDARD, body)
        );

        (bool ok,) = address(transmitter).call(data);
        _check(false, ok, "messageImplementation");
    }

    /// @notice Reads account() on an implementation, which must revert.
    function readImplementationAccount(bool base) external {
        bytes memory data = abi.encodeCall(MozaikCCTPForwarder.account, ());

        (bool ok,) = address(implementations[_mode(base)]).staticcall(data);
        _check(false, ok, "readImplementationAccount");
    }

    /// @notice Each forwarder's balance of each asset is exactly what entered it minus what forward and rescue moved.
    function echidna_balances_match_exits() external view returns (bool) {
        for (uint256 slot = 0; slot < SLOT_COUNT; slot++) {
            for (uint256 asset = 0; asset < ASSET_COUNT; asset++) {
                uint256 forwardedOut = asset == _forwardAsset(_slotMode(slot)) ? forwarded[slot] : 0;
                uint256 out = rescued[slot][asset] + forwardedOut;
                if (_balance(asset, forwarders[slot]) + out != funded[slot][asset]) return false;
            }
        }

        return true;
    }

    /// @notice Every call the model deems valid succeeds.
    function echidna_valid_calls_succeed() external view returns (bool) {
        return !validCallReverted;
    }

    /// @notice Every call the model deems invalid reverts, so value moves only through the allowed exits.
    function echidna_invalid_calls_revert() external view returns (bool) {
        return !invalidCallSucceeded;
    }

    /// @notice Burned localUsdc sits at the minter, and each account holds exactly its Base transfers. RESCUE_TO
    ///         holds exactly the rescues, and no allowance to the messenger is left over.
    function echidna_exits_reach_their_targets() external view returns (bool) {
        return _minterHoldsOnlyBurns() && _accountsHoldOnlyTransfers() && _rescueToHoldsRescues() && _noAllowanceLeft();
    }

    /// @notice Every burn is a valid source forward of localUsdc to its forwarder's account on Base, and the burns add
    ///         up to what each forwarder forwarded.
    function echidna_burns_go_to_account() external view returns (bool) {
        uint256 count = messenger.burnCount();
        if (count != burns) return false;

        uint256[SLOT_COUNT] memory burned;
        for (uint256 i = 0; i < count; i++) {
            MockTokenMessengerV2.Burn memory burn = messenger.burnAt(i);
            (bool known, uint256 slot) = _sourceSlotOf(burn.depositor);
            if (!known || !_burnFollowsRules(burn, slot)) return false;

            burned[slot] += burn.amount;
        }

        for (uint256 slot = 0; slot < SLOT_COUNT; slot++) {
            if (!_onBase(slot) && burned[slot] != forwarded[slot]) return false;
        }

        return true;
    }

    /// @notice Every forwarder the factories deployed sits at its predicted address, serves its account and carries
    ///         its implementation's config.
    function echidna_forwarders_serve_their_accounts() external view returns (bool) {
        if (factoryMismatch) return false;

        for (uint256 mode = 0; mode < 2; mode++) {
            if (address(factories[mode].FORWARDER_IMPLEMENTATION()) != address(implementations[mode])) return false;
        }

        for (uint256 slot = 0; slot < SLOT_COUNT; slot++) {
            if (forwarders[slot].code.length > 0 && !_servesItsAccount(slot)) return false;
        }

        return true;
    }

    /// @notice Calls that reach an implementation directly never move its funds.
    function echidna_implementations_keep_funds() external view returns (bool) {
        for (uint256 mode = 0; mode < 2; mode++) {
            for (uint256 asset = 0; asset < ASSET_COUNT; asset++) {
                if (_balance(asset, address(implementations[mode])) != implementationFunded[mode][asset]) return false;
            }
        }

        return true;
    }

    /// @dev Forward arguments that often land on a zero amount, the fee cap and the valid thresholds.
    function _forwardArgs(uint256 slot, ForwardInput memory input) internal view returns (ForwardArgs memory) {
        uint256 balance = _balance(_forwardAsset(_slotMode(slot)), forwarders[slot]);
        uint256 amount = _amount(input.amountCase, input.amountSeed, balance);

        return ForwardArgs({
            amount: amount,
            maxFee: _maxFee(input.feeCase, input.feeSeed, amount),
            threshold: _forwardThreshold(input.thresholdCase, input.anyThreshold)
        });
    }

    /// @dev forward moves part of the forwarder's forward token. On Base it takes no fee.
    function _expectForward(uint256 slot, ForwardArgs memory args) internal view returns (bool) {
        uint256 balance = _balance(_forwardAsset(_slotMode(slot)), forwarders[slot]);
        if (args.amount == 0 || args.amount > balance) return false;

        return _onBase(slot) ? args.maxFee == 0 : _burnAllowed(args);
    }

    /// @dev A burn needs a CCTP threshold, a fee within the cap and below the amount, and the token link.
    function _burnAllowed(ForwardArgs memory args) internal view returns (bool) {
        bool knownThreshold = args.threshold == FINALITY_FAST || args.threshold == FINALITY_STANDARD;

        return knownThreshold && args.maxFee <= _feeCap(args.amount) && args.maxFee < args.amount && linked;
    }

    /// @dev Only the account can rescue, only on Base, and only what the forwarder holds.
    function _expectRescue(uint256 slot, address caller, uint256 asset, uint256 amount) internal view returns (bool) {
        return caller == _account(slot) && _onBase(slot) && amount <= _balance(asset, forwarders[slot]);
    }

    /// @dev A message rescues only through the transmitter, from the account on Base, finalized and in time.
    function _expectMessage(Message memory message, address handlerCaller) internal view returns (bool) {
        return handlerCaller == address(transmitter) && message.domain == BASE_DOMAIN
            && message.sender == _padded(_account(message.slot)) && message.threshold >= FINALITY_STANDARD
            && block.timestamp <= message.deadline
            && message.amount <= _balance(message.asset, forwarders[message.slot]);
    }

    function _message(uint256 slot, MessageInput memory input) internal view returns (Message memory) {
        uint256 asset = _asset(input.assetSeed);

        return Message({
            slot: slot,
            asset: asset,
            amount: _amount(input.amountCase, input.amountSeed, _balance(asset, forwarders[slot])),
            sender: _sender(slot, input.senderCase, input.anySender),
            domain: _domain(input.domainCase, input.anyDomain),
            threshold: _messageThreshold(input.thresholdCase, input.anyThreshold),
            deadline: _deadline(input.deadlineCase, input.anyDeadline)
        });
    }

    function _body(Message memory message) internal view returns (bytes memory) {
        return abi.encode(_token(message.asset), RESCUE_TO, message.amount, message.deadline);
    }

    /// @dev A valid message must also return true. Records the rescue of any message that went through.
    function _settleMessage(Message memory message, bool valid, bool ok, bytes memory returned, string memory action)
        internal
    {
        bool succeeded = valid ? ok && _returnedTrue(returned) : ok;
        _check(valid, succeeded, action);
        if (ok) rescued[message.slot][message.asset] += message.amount;
    }

    /// @dev Code-bearing targets must reject native coin. Returns whether the coin went through.
    function _sendNative(address to, uint64 amount, bytes calldata data) internal returns (bool ok) {
        if (amount == 0 || amount > address(this).balance) return false;

        bool valid = to.code.length == 0;
        (ok,) = to.call{value: amount}(data);
        _check(valid, ok, "sendNative");
    }

    /// @dev The prank covers only this call.
    function _callAs(address caller, address target, bytes memory data)
        internal
        returns (bool ok, bytes memory returned)
    {
        vm.prank(caller);
        (ok, returned) = target.call(data);
    }

    function _give(address to, uint256 asset, uint256 amount) internal {
        if (asset == ASSET_NATIVE) {
            vm.deal(to, to.balance + amount);
        } else {
            ERC20Mock(_token(asset)).mint(to, amount);
        }
    }

    function _recordDeploy(uint256 slot, address forwarder) internal {
        if (forwarder != forwarders[slot]) factoryMismatch = true;
        deployed[slot] = forwarders[slot].code.length > 0;
    }

    function _recordForward(uint256 slot, uint256 amount) internal {
        forwarded[slot] += amount;
        if (!_onBase(slot)) burns++;
    }

    /// @dev Flags a valid call that reverted or an invalid call that succeeded.
    function _check(bool valid, bool succeeded, string memory action) internal {
        if (valid == succeeded) return;

        if (valid) {
            validCallReverted = true;
            emit ValidCallReverted(action);
        } else {
            invalidCallSucceeded = true;
            emit InvalidCallSucceeded(action);
        }
    }

    /// @dev Zero, one past the balance, or an amount within it.
    function _amount(uint8 amountCase, uint256 amountSeed, uint256 balance) internal pure returns (uint256) {
        uint8 kind = amountCase % 8;
        if (kind == 0) return 0;
        if (kind == 1) return balance + 1;

        return amountSeed % (balance + 1);
    }

    /// @dev Zero, the cap, one past the cap, within 30 bps, or anything.
    function _maxFee(uint8 feeCase, uint256 feeSeed, uint256 amount) internal pure returns (uint256) {
        uint8 kind = feeCase % 6;
        if (kind < 2) return 0;
        if (kind == 2) return _feeCap(amount);
        if (kind == 3) return _feeCap(amount) + 1;
        if (kind == 4) return feeSeed % (amount * 30 / 10_000 + 1);

        return feeSeed;
    }

    /// @dev Fast, Standard, or anything.
    function _forwardThreshold(uint8 thresholdCase, uint32 anyThreshold) internal pure returns (uint32) {
        uint8 kind = thresholdCase % 4;
        if (kind == 0) return FINALITY_FAST;
        if (kind == 1) return FINALITY_STANDARD;

        return anyThreshold;
    }

    /// @dev Anything, just below finalized, or finalized.
    function _messageThreshold(uint8 thresholdCase, uint32 anyThreshold) internal pure returns (uint32) {
        uint8 kind = thresholdCase % 4;
        if (kind == 0) return anyThreshold;
        if (kind == 1) return FINALITY_STANDARD - 1;

        return FINALITY_STANDARD;
    }

    /// @dev Mostly Base, sometimes anything.
    function _domain(uint8 domainCase, uint32 anyDomain) internal pure returns (uint32) {
        return domainCase % 4 == 0 ? anyDomain : BASE_DOMAIN;
    }

    /// @dev Mostly the account. Otherwise the account with dirty upper bits, the other account, the harness or
    ///      anything.
    function _sender(uint256 slot, uint8 senderCase, bytes32 anySender) internal view returns (bytes32) {
        bytes32 accountSender = _padded(_account(slot));
        uint8 kind = senderCase % 8;
        if (kind < 4) return accountSender;
        if (kind == 4) return accountSender | bytes32((uint256(anySender) | 1) << 160);
        if (kind == 5) return _padded(_account(_otherAccountSlot(slot)));
        if (kind == 6) return _padded(address(this));

        return anySender;
    }

    /// @dev Just expired, expiring now, one second left, anything, or within a day.
    function _deadline(uint8 deadlineCase, uint256 anyDeadline) internal view returns (uint256) {
        uint8 kind = deadlineCase % 8;
        if (kind == 0) return block.timestamp - 1;
        if (kind == 1) return block.timestamp;
        if (kind == 2) return block.timestamp + 1;
        if (kind == 3) return anyDeadline;

        return block.timestamp + anyDeadline % 1 days;
    }

    /// @dev The account, the other account, the harness, or anyone.
    function _rescueCaller(uint256 slot, uint8 callerCase, address anyCaller) internal view returns (address) {
        uint8 kind = callerCase % 4;
        if (kind == 0) return _account(slot);
        if (kind == 1) return _account(_otherAccountSlot(slot));
        if (kind == 2) return address(this);

        return anyCaller;
    }

    /// @dev The transmitter, the account, or the harness.
    function _handlerCaller(uint256 slot, uint8 callerCase) internal view returns (address) {
        uint8 kind = callerCase % 3;
        if (kind == 0) return address(transmitter);
        if (kind == 1) return _account(slot);

        return address(this);
    }

    /// @dev An amount of the implementation's forward token, sometimes zero or one past its balance.
    function _implementationAmount(uint256 mode, uint8 amountCase, uint256 amountSeed) internal view returns (uint256) {
        uint256 balance = _balance(_forwardAsset(mode), address(implementations[mode]));

        return _amount(amountCase, amountSeed, balance);
    }

    function _minterHoldsOnlyBurns() internal view returns (bool) {
        uint256 totalBurned;
        for (uint256 slot = 0; slot < SLOT_COUNT; slot++) {
            if (!_onBase(slot)) totalBurned += forwarded[slot];
        }

        if (localUsdc.balanceOf(address(minter)) != totalBurned) return false;

        return baseUsdc.balanceOf(address(minter)) == 0 && other.balanceOf(address(minter)) == 0
            && address(minter).balance == 0;
    }

    /// @dev Each account holds exactly what its Base forwarder forwarded, and no other asset.
    function _accountsHoldOnlyTransfers() internal view returns (bool) {
        for (uint256 slot = 0; slot < SLOT_COUNT; slot++) {
            if (_onBase(slot) && !_accountHoldsOnlyTransfers(_account(slot), forwarded[slot])) return false;
        }

        return true;
    }

    function _accountHoldsOnlyTransfers(address account, uint256 transferred) internal view returns (bool) {
        return baseUsdc.balanceOf(account) == transferred && localUsdc.balanceOf(account) == 0
            && other.balanceOf(account) == 0 && account.balance == 0;
    }

    function _rescueToHoldsRescues() internal view returns (bool) {
        for (uint256 asset = 0; asset < ASSET_COUNT; asset++) {
            uint256 total;
            for (uint256 slot = 0; slot < SLOT_COUNT; slot++) {
                total += rescued[slot][asset];
            }

            if (_balance(asset, RESCUE_TO) != total) return false;
        }

        return true;
    }

    function _noAllowanceLeft() internal view returns (bool) {
        for (uint256 slot = 0; slot < SLOT_COUNT; slot++) {
            if (localUsdc.allowance(forwarders[slot], address(messenger)) != 0) return false;
            if (baseUsdc.allowance(forwarders[slot], address(messenger)) != 0) return false;
        }

        return true;
    }

    function _sourceSlotOf(address depositor) internal view returns (bool known, uint256 slot) {
        for (uint256 i = 0; i < SLOT_COUNT; i++) {
            if (!_onBase(i) && forwarders[i] == depositor) return (true, i);
        }

        return (false, 0);
    }

    function _burnFollowsRules(MockTokenMessengerV2.Burn memory burn, uint256 slot) internal view returns (bool) {
        bool knownThreshold =
            burn.minFinalityThreshold == FINALITY_FAST || burn.minFinalityThreshold == FINALITY_STANDARD;

        return burn.mintRecipient == _padded(_account(slot)) && burn.burnToken == address(localUsdc)
            && burn.destinationDomain == BASE_DOMAIN && burn.destinationCaller == bytes32(0) && knownThreshold
            && burn.maxFee * 10_000 <= burn.amount * 20;
    }

    function _servesItsAccount(uint256 slot) internal view returns (bool) {
        MozaikCCTPForwarder forwarder = MozaikCCTPForwarder(forwarders[slot]);
        try forwarder.account() returns (address account) {
            if (account != _account(slot)) return false;
        } catch {
            return false;
        }

        return address(forwarder.TOKEN_MESSENGER()) == address(messenger) && forwarder.BASE_USDC() == address(baseUsdc)
            && forwarder.BASE_CHAIN_ID() == block.chainid + _slotMode(slot);
    }

    function _slot(uint8 slotSeed) internal pure returns (uint256) {
        return slotSeed % SLOT_COUNT;
    }

    function _asset(uint8 assetSeed) internal pure returns (uint256) {
        return assetSeed % ASSET_COUNT;
    }

    function _mode(bool base) internal pure returns (uint256) {
        return base ? BASE_MODE : SOURCE_MODE;
    }

    function _slotMode(uint256 slot) internal pure returns (uint256) {
        return slot % 2;
    }

    function _onBase(uint256 slot) internal pure returns (bool) {
        return _slotMode(slot) == BASE_MODE;
    }

    function _account(uint256 slot) internal pure returns (address) {
        return slot < 2 ? ACCOUNT_A : ACCOUNT_B;
    }

    /// @dev The slot of the same mode that serves the other account.
    function _otherAccountSlot(uint256 slot) internal pure returns (uint256) {
        return (slot + 2) % SLOT_COUNT;
    }

    /// @dev The token forward moves: baseUsdc on Base, localUsdc elsewhere.
    function _forwardAsset(uint256 mode) internal pure returns (uint256) {
        return mode == BASE_MODE ? ASSET_BASE_USDC : ASSET_LOCAL_USDC;
    }

    function _feeCap(uint256 amount) internal pure returns (uint256) {
        return amount * 20 / 10_000;
    }

    function _token(uint256 asset) internal view returns (address) {
        if (asset == ASSET_BASE_USDC) return address(baseUsdc);
        if (asset == ASSET_LOCAL_USDC) return address(localUsdc);
        if (asset == ASSET_OTHER) return address(other);

        return address(0);
    }

    function _balance(uint256 asset, address holder) internal view returns (uint256) {
        return asset == ASSET_NATIVE ? holder.balance : ERC20Mock(_token(asset)).balanceOf(holder);
    }

    function _padded(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    /// @dev Handlers return a single bool.
    function _returnedTrue(bytes memory returned) internal pure returns (bool) {
        return returned.length == 32 && abi.decode(returned, (bool));
    }
}
