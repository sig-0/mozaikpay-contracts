// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";
import {IAccountExecute} from "account-abstraction/interfaces/IAccountExecute.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {MozaikAccount} from "../../src/account/MozaikAccount.sol";
import {MozaikAccountFactory} from "../../src/account/MozaikAccountFactory.sol";

/// @notice Echidna fuzz target for MozaikAccount and MozaikAccountFactory.
/// @dev Each action predicts its outcome from a ghost model that never reads the account. Direct actions come
///      from every key, a stranger and the EntryPoint. UserOp actions are signed by current, rotated-out or
///      unrelated keys. Other actions fund the account, create accounts and pin the upgrade-data path.
contract AccountEchidna {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant ENTRY_POINT = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;

    /// @dev Codeless, so a call to it fails only when the account cannot cover the value.
    address internal constant BENIGN_TARGET = address(0xBEEF);

    uint256 internal constant INITIAL_FUNDS = 10 ether;
    uint256 internal constant MAX_FUNDING = 100 ether;
    uint256 internal constant MAX_BATCH_CALLS = 3;

    /// @dev Signer roles rotate within the pool. The stranger key is never installed.
    uint256 internal constant POOL_SIZE = 4;
    uint256 internal constant STRANGER = POOL_SIZE;
    uint256 internal constant KEY_COUNT = POOL_SIZE + 1;

    uint8 internal constant SIG_SPENDING = 0x00;
    uint8 internal constant SIG_RECOVERY = 0x01;

    /// @dev The account treats every other sigType the same way.
    uint8 internal constant SIG_UNKNOWN = 0x02;

    uint256 internal constant SIG_VALIDATION_SUCCESS = 0;
    uint256 internal constant SIG_VALIDATION_FAILED = 1;

    /// @dev Account entry points an action can call.
    uint8 internal constant FN_EXECUTE = 0;
    uint8 internal constant FN_BATCH = 1;
    uint8 internal constant FN_ROTATE_SPENDING = 2;
    uint8 internal constant FN_ROTATE_RECOVERY = 3;
    uint8 internal constant FN_UPGRADE = 4;
    uint8 internal constant FN_INITIALIZE = 5;
    uint8 internal constant FN_COUNT = 6;

    /// @dev Calldata passed to upgradeToAndCall.
    uint8 internal constant UPGRADE_DATA_NONE = 0;
    uint8 internal constant UPGRADE_DATA_INITIALIZE = 1;
    uint8 internal constant UPGRADE_DATA_EXECUTE = 2;
    uint8 internal constant UPGRADE_DATA_ROTATE = 3;
    uint8 internal constant UPGRADE_DATA_COUNT = 4;

    /// @dev Calls inside execute and executeBatch.
    uint8 internal constant CALL_TRANSFER = 0;
    uint8 internal constant CALL_SELF_TRANSFER = 1;
    uint8 internal constant CALL_SELF_PRIVILEGED = 2;
    uint8 internal constant CALL_KIND_COUNT = 3;

    /// @dev UserOp encodings. Only the first is well formed.
    uint8 internal constant SHAPE_OK = 0;
    uint8 internal constant SHAPE_BAD_LENGTH = 1;
    uint8 internal constant SHAPE_UNRECOVERABLE = 2;
    uint8 internal constant SHAPE_UNWRAPPED = 3;
    uint8 internal constant SHAPE_SHORT = 4;

    struct Model {
        address spending;
        address recovery;
        address implementation;
        uint256 balance;
        uint256 paidOut;
        uint256 prefunded;
    }

    struct Action {
        uint8 fn;
        address target;
        address signer;
        address signer2;
        address implementation;
        uint8 upgradeData;
        uint256 value;
        BaseAccount.Call[] calls;
    }

    struct Outcome {
        bool authorized;
        bool valid;
        bool reinit;
        bool stale;
    }

    struct OpCase {
        uint8 sigType;
        uint256 key;
        uint8 shape;
        uint256 missing;
    }

    /// @dev A fuzzed call inside execute or executeBatch.
    struct CallSeed {
        uint8 kind;
        uint8 privilegedCall;
        uint256 value;
    }

    /// @dev A fuzzed upgradeToAndCall.
    struct UpgradeSeed {
        uint8 implementation;
        uint8 data;
        uint8 signer;
        uint256 value;
    }

    /// @dev Who signs a UserOp, and under which sigType.
    struct OpSeed {
        bool signedByHolder;
        uint8 key;
        uint8 sigType;
    }

    MozaikAccount internal account;
    MozaikAccount internal implementation;
    MozaikAccount internal altImplementation;
    MozaikAccountFactory internal factory;
    address internal factoryImplementation;
    address internal senderCreator;

    uint256[KEY_COUNT] internal keys;
    address[KEY_COUNT] internal keyAddr;
    uint256 internal opCount;

    Model internal ghost;

    bool internal validReverted;
    bool internal unauthorizedSucceeded;
    bool internal invalidSucceeded;
    bool internal reinitSucceeded;
    bool internal validationMismatch;
    bool internal staleOpSucceeded;
    bool internal factoryMismatch;
    bool internal recoveryUpgradeExecuteBlocked;

    constructor() payable {
        for (uint256 i = 0; i < KEY_COUNT; i++) {
            keys[i] = 0xA11CE + i;
            keyAddr[i] = vm.addr(keys[i]);
        }

        implementation = new MozaikAccount();
        altImplementation = new MozaikAccount();

        bytes memory initData = abi.encodeCall(MozaikAccount.initialize, (keyAddr[0], keyAddr[1]));
        account = MozaikAccount(payable(address(new ERC1967Proxy(address(implementation), initData))));

        (bool funded,) = payable(address(account)).call{value: INITIAL_FUNDS}("");
        require(funded, "funding failed");

        ghost = Model({
            spending: keyAddr[0],
            recovery: keyAddr[1],
            implementation: address(implementation),
            balance: INITIAL_FUNDS,
            paidOut: 0,
            prefunded: 0
        });

        factory = new MozaikAccountFactory();
        factoryImplementation = address(factory.ACCOUNT_IMPLEMENTATION());
        senderCreator = address(EntryPoint(payable(ENTRY_POINT)).senderCreator());
    }

    /// @notice Any caller calls execute with one call.
    function directExecute(uint8 callerSeed, CallSeed calldata call) external {
        Model memory model = ghost;
        _callDirect(callerSeed, _executeAction(call, model), model);
    }

    /// @notice Any caller calls executeBatch with up to three calls.
    function directExecuteBatch(uint8 callerSeed, CallSeed[] calldata calls) external {
        Model memory model = ghost;
        _callDirect(callerSeed, _batchAction(calls, model), model);
    }

    /// @notice Any caller rotates the spending signer to a pooled key or the zero address.
    function directRotateSpending(uint8 callerSeed, uint8 signerSeed) external {
        _callDirect(callerSeed, _rotationAction(FN_ROTATE_SPENDING, signerSeed), ghost);
    }

    /// @notice Any caller rotates the recovery signer to a pooled key or the zero address.
    function directRotateRecovery(uint8 callerSeed, uint8 signerSeed) external {
        _callDirect(callerSeed, _rotationAction(FN_ROTATE_RECOVERY, signerSeed), ghost);
    }

    /// @notice Any caller upgrades the account, with or without call data.
    function directUpgrade(uint8 callerSeed, UpgradeSeed calldata upgrade) external {
        Model memory model = ghost;
        _callDirect(callerSeed, _upgradeAction(upgrade, model), model);
    }

    /// @notice Any caller initializes the proxy or an implementation again.
    function directInitialize(uint8 callerSeed, uint8 targetSeed, uint8 signerSeed) external {
        _callDirect(callerSeed, _initializeAction(targetSeed, signerSeed), ghost);
    }

    /// @notice The EntryPoint validates a UserOp with any signer, sigType, inner call, encoding and prefund.
    function userOpValidate(
        OpSeed calldata op,
        uint8 fnSeed,
        bool wellFormed,
        uint8 malformedSeed,
        bool payPrefund,
        uint256 prefundSeed
    ) external {
        Model memory model = ghost;
        uint8 fn = fnSeed % FN_COUNT;
        OpCase memory opCase = _opCase(op, fn, wellFormed ? SHAPE_OK : _malformedShape(malformedSeed), model);
        opCase.missing = payPrefund ? _prefund(prefundSeed, model) : 0;

        _validateUserOp(fn, opCase, model);
    }

    /// @notice The EntryPoint executes a UserOp that wraps execute.
    function userOpExecuteCall(OpSeed calldata op, bool recoverable, CallSeed calldata call) external {
        Model memory model = ghost;
        _executeUserOp(op, recoverable, _executeAction(call, model), model);
    }

    /// @notice The EntryPoint executes a UserOp that wraps executeBatch.
    function userOpExecuteBatch(OpSeed calldata op, bool recoverable, CallSeed[] calldata calls) external {
        Model memory model = ghost;
        _executeUserOp(op, recoverable, _batchAction(calls, model), model);
    }

    /// @notice The EntryPoint executes a UserOp that wraps rotateSpendingSigner.
    function userOpExecuteRotateSpending(OpSeed calldata op, bool recoverable, uint8 signerSeed) external {
        _executeUserOp(op, recoverable, _rotationAction(FN_ROTATE_SPENDING, signerSeed), ghost);
    }

    /// @notice The EntryPoint executes a UserOp that wraps rotateRecoverySigner.
    function userOpExecuteRotateRecovery(OpSeed calldata op, bool recoverable, uint8 signerSeed) external {
        _executeUserOp(op, recoverable, _rotationAction(FN_ROTATE_RECOVERY, signerSeed), ghost);
    }

    /// @notice The EntryPoint executes a UserOp that wraps upgradeToAndCall.
    function userOpExecuteUpgrade(OpSeed calldata op, bool recoverable, UpgradeSeed calldata upgrade) external {
        Model memory model = ghost;
        _executeUserOp(op, recoverable, _upgradeAction(upgrade, model), model);
    }

    /// @notice The EntryPoint executes a UserOp that wraps initialize, which no sigType allows.
    function userOpExecuteInitialize(OpSeed calldata op, bool recoverable, uint8 targetSeed, uint8 signerSeed)
        external
    {
        _executeUserOp(op, recoverable, _initializeAction(targetSeed, signerSeed), ghost);
    }

    /// @notice A key submits a valid UserOp to validateUserOp. Only the EntryPoint may.
    function userOpValidateFromKey(uint8 keySeed) external {
        OpCase memory opCase = _spendingOpCase(ghost);
        opCase.missing = 1;

        _callAsKeyExpectingRevert(keySeed, _validateCall(_encode(_transferAction(1)), opCase));
    }

    /// @notice A key submits a valid UserOp to executeUserOp. Only the EntryPoint may.
    function userOpExecuteFromKey(uint8 keySeed) external {
        _callAsKeyExpectingRevert(keySeed, _executeUserOpCall(_encode(_transferAction(1)), _spendingOpCase(ghost)));
    }

    /// @notice Anyone sends ETH to the account.
    function fundAccount(uint256 amountSeed) external {
        uint256 amount = amountSeed % MAX_FUNDING;

        (bool ok,) = payable(address(account)).call{value: amount}("");

        if (!ok) {
            validReverted = true;

            return;
        }

        ghost.balance += amount;
    }

    /// @notice The SenderCreator, a stranger or the EntryPoint asks the factory for an account with any signer pair.
    function factoryCreate(uint8 callerSeed, uint8 spendingSeed, uint8 recoverySeed) external {
        address caller = _factoryCaller(callerSeed);
        address spending = _newSigner(spendingSeed);
        address recovery = _newSigner(recoverySeed);
        bool valid = caller == senderCreator && _isValidPair(spending, recovery);
        address predicted = _predictAccount(spending, recovery);
        bytes memory data = abi.encodeCall(MozaikAccountFactory.createAccount, (spending, recovery));

        vm.prank(caller);
        (bool ok, bytes memory ret) = address(factory).call(data);

        if (ok != valid) {
            factoryMismatch = true;

            return;
        }

        if (ok && !_createdAsPredicted(abi.decode(ret, (address)), predicted, spending, recovery)) {
            factoryMismatch = true;
        }
    }

    /// @notice The current recovery key sends ETH through upgradeToAndCall data in a UserOp.
    function recoveryExecutesViaUpgradeData(uint256 valueSeed) external {
        Model memory model = ghost;
        Action memory action = _pinnedUpgradeAction(valueSeed, model);
        OpCase memory opCase =
            OpCase({sigType: SIG_RECOVERY, key: _keyIndex(model.recovery), shape: SHAPE_OK, missing: 0});

        (PackedUserOperation memory op, bytes32 hash) = _userOp(_encode(action), opCase);
        bytes memory validateData = abi.encodeCall(account.validateUserOp, (op, hash, 0));
        bytes memory executeData = abi.encodeCall(MozaikAccount.executeUserOp, (op, hash));
        Outcome memory outcome = _expect(action, ENTRY_POINT, model);

        vm.prank(ENTRY_POINT);
        (bool validated, bytes memory ret) = address(account).call(validateData);

        if (!validated || abi.decode(ret, (uint256)) != SIG_VALIDATION_SUCCESS) {
            recoveryUpgradeExecuteBlocked = true;

            return;
        }

        uint256 targetBefore = BENIGN_TARGET.balance;

        vm.prank(ENTRY_POINT);
        (bool executed,) = address(account).call(executeData);

        if (!executed || BENIGN_TARGET.balance != targetBefore + action.value) {
            recoveryUpgradeExecuteBlocked = true;

            return;
        }

        _record(executed, outcome, model);
    }

    /// @notice The on-chain signers equal the model's.
    function echidna_signers_match_model() external view returns (bool) {
        return account.spendingSigner() == ghost.spending && account.recoverySigner() == ghost.recovery;
    }

    /// @notice The two signers are never the same address.
    function echidna_signers_distinct() external view returns (bool) {
        return account.spendingSigner() != account.recoverySigner();
    }

    /// @notice Neither signer is ever the zero address.
    function echidna_signers_nonzero() external view returns (bool) {
        return account.spendingSigner() != address(0) && account.recoverySigner() != address(0);
    }

    /// @notice The ERC-1967 implementation changes only through an authorized, valid upgrade.
    function echidna_implementation_matches_model() external view returns (bool) {
        bytes32 slot = vm.load(address(account), ERC1967Utils.IMPLEMENTATION_SLOT);

        return address(uint160(uint256(slot))) == ghost.implementation;
    }

    /// @notice ETH leaves the account only through authorized calls and the EntryPoint prefund.
    function echidna_eth_matches_model() external view returns (bool) {
        return address(account).balance == ghost.balance && BENIGN_TARGET.balance == ghost.paidOut
            && ENTRY_POINT.balance == ghost.prefunded;
    }

    /// @notice A caller without authority for a call never succeeds.
    function echidna_no_unauthorized_success() external view returns (bool) {
        return !unauthorizedSucceeded;
    }

    /// @notice An authorized call that breaks a precondition always reverts.
    function echidna_no_invalid_success() external view returns (bool) {
        return !invalidSucceeded;
    }

    /// @notice An authorized call that meets every precondition never reverts.
    function echidna_valid_actions_succeed() external view returns (bool) {
        return !validReverted;
    }

    /// @notice The proxy and the implementations can never be initialized again.
    function echidna_no_reinitialization() external view returns (bool) {
        return !reinitSucceeded;
    }

    /// @notice UserOp validation accepts exactly a well-formed op signed by the holder of an allowed role.
    function echidna_validation_matches_model() external view returns (bool) {
        return !validationMismatch;
    }

    /// @notice A UserOp signed by a key that no longer holds its role never executes.
    function echidna_no_stale_execution() external view returns (bool) {
        return !staleOpSucceeded;
    }

    /// @notice The factory creates accounts only for its SenderCreator, at the predicted address.
    function echidna_factory_matches_model() external view returns (bool) {
        return !factoryMismatch;
    }

    /// @notice Pins current behaviour: a recovery UserOp can move ETH through upgradeToAndCall data.
    function echidna_recovery_upgrade_data_executes() external view returns (bool) {
        return !recoveryUpgradeExecuteBlocked;
    }

    /// @dev Makes `action` directly from the caller that `callerSeed` picks.
    function _callDirect(uint8 callerSeed, Action memory action, Model memory model) internal {
        address caller = _caller(callerSeed);
        Outcome memory outcome = _expect(action, caller, model);
        bytes memory data = _encode(action);

        vm.prank(caller);
        (bool ok,) = action.target.call(data);

        _record(ok, outcome, model);
    }

    /// @dev The EntryPoint validates a UserOp and must get exactly the predicted result.
    function _validateUserOp(uint8 fn, OpCase memory opCase, Model memory model) internal {
        uint256 expected = _expectValidation(fn, opCase, model);
        bytes memory data = _validateCall(_innerCallFor(fn), opCase);

        vm.prank(ENTRY_POINT);
        (bool ok, bytes memory ret) = address(account).call(data);

        if (!ok) {
            validationMismatch = true;

            return;
        }

        _applyPrefund(opCase.missing, model);
        ghost.balance = model.balance;
        ghost.prefunded = model.prefunded;

        if (abi.decode(ret, (uint256)) != expected) validationMismatch = true;
    }

    /// @dev The EntryPoint executes `action` in a UserOp. A signer that no longer holds its role must be rejected.
    function _executeUserOp(OpSeed memory seed, bool recoverable, Action memory action, Model memory model) internal {
        OpCase memory opCase = _opCase(seed, action.fn, recoverable ? SHAPE_OK : SHAPE_UNRECOVERABLE, model);
        bytes memory data = _executeUserOpCall(_encode(action), opCase);
        Outcome memory outcome = _expectUserOp(action, opCase, model);

        vm.prank(ENTRY_POINT);
        (bool ok,) = address(account).call(data);

        if (outcome.stale) {
            if (ok) staleOpSucceeded = true;

            return;
        }

        _record(ok, outcome, model);
    }

    function _callAsKeyExpectingRevert(uint8 keySeed, bytes memory data) internal {
        address caller = keyAddr[keySeed % KEY_COUNT];

        vm.prank(caller);
        (bool ok,) = address(account).call(data);

        if (ok) unauthorizedSucceeded = true;
    }

    /// @dev Predicts a direct call's outcome. Its effects on `model` count only when the call is authorized and valid.
    function _expect(Action memory action, address caller, Model memory model) internal view returns (Outcome memory) {
        if (action.fn == FN_EXECUTE || action.fn == FN_BATCH) return _expectCalls(action.calls, caller, model);

        if (action.fn == FN_ROTATE_SPENDING || action.fn == FN_ROTATE_RECOVERY) {
            return _expectRotation(action.fn == FN_ROTATE_SPENDING, action.signer, caller, model);
        }

        if (action.fn == FN_UPGRADE) return _expectUpgrade(action, caller, model);

        return Outcome({authorized: false, valid: false, reinit: true, stale: false});
    }

    /// @dev execute and executeBatch.
    function _expectCalls(BaseAccount.Call[] memory calls, address caller, Model memory model)
        internal
        view
        returns (Outcome memory)
    {
        return Outcome({
            authorized: _canSpend(caller, model) && !_callsAccountWithData(calls),
            valid: _payAll(calls, model),
            reinit: false,
            stale: false
        });
    }

    /// @dev rotateSpendingSigner and rotateRecoverySigner.
    function _expectRotation(bool spendingRole, address signer, address caller, Model memory model)
        internal
        pure
        returns (Outcome memory)
    {
        return Outcome({
            authorized: _canRecover(caller, model),
            valid: _applyRotation(spendingRole, signer, model),
            reinit: false,
            stale: false
        });
    }

    /// @dev upgradeToAndCall. The upgrade data runs with the caller's authority.
    function _expectUpgrade(Action memory action, address caller, Model memory model)
        internal
        view
        returns (Outcome memory)
    {
        model.implementation = action.implementation;
        (bool dataAuthorized, bool dataValid, bool reinit) = _expectUpgradeData(action, caller, model);

        return Outcome({
            authorized: _canRecover(caller, model) && dataAuthorized,
            valid: _isImplementation(action.implementation) && dataValid,
            reinit: reinit,
            stale: false
        });
    }

    /// @dev Only the EntryPoint passes execute's check inside an upgrade, so a recovery UserOp can move funds.
    function _expectUpgradeData(Action memory action, address caller, Model memory model)
        internal
        view
        returns (bool authorized, bool valid, bool reinit)
    {
        if (action.upgradeData == UPGRADE_DATA_INITIALIZE) return (true, false, true);

        if (action.upgradeData == UPGRADE_DATA_EXECUTE) {
            return (caller == ENTRY_POINT, _pay(BENIGN_TARGET, action.value, model), false);
        }
        if (action.upgradeData == UPGRADE_DATA_ROTATE) {
            return (true, _applyRotation(true, action.signer, model), false);
        }

        return (true, true, false);
    }

    function _canSpend(address caller, Model memory model) internal pure returns (bool) {
        return caller == model.spending || caller == ENTRY_POINT;
    }

    function _canRecover(address caller, Model memory model) internal pure returns (bool) {
        return caller == model.recovery || caller == ENTRY_POINT;
    }

    function _isImplementation(address candidate) internal view returns (bool) {
        return candidate == address(implementation) || candidate == address(altImplementation);
    }

    /// @dev The account holds no role, so a call from it to itself that carries data is unauthorized.
    function _callsAccountWithData(BaseAccount.Call[] memory calls) internal view returns (bool) {
        for (uint256 i = 0; i < calls.length; i++) {
            if (calls[i].target == address(account) && calls[i].data.length != 0) return true;
        }

        return false;
    }

    /// @dev Pays every call from the model. Returns false if the account cannot cover one of them.
    function _payAll(BaseAccount.Call[] memory calls, Model memory model) internal view returns (bool) {
        for (uint256 i = 0; i < calls.length; i++) {
            if (!_pay(calls[i].target, calls[i].value, model)) return false;
        }

        return true;
    }

    /// @dev Pays `value` to `target` from the model. A payment to the account itself keeps the value in it.
    function _pay(address target, uint256 value, Model memory model) internal view returns (bool) {
        if (value > model.balance) return false;

        if (target != address(account)) {
            model.balance -= value;
            model.paidOut += value;
        }

        return true;
    }

    /// @dev Predicts executeUserOp. A call the op may make runs with the EntryPoint's authority.
    function _expectUserOp(Action memory action, OpCase memory opCase, Model memory model)
        internal
        view
        returns (Outcome memory)
    {
        bool reinit = action.fn == FN_INITIALIZE;

        if (!_isKnownSigType(opCase.sigType)) return _rejected(reinit, false);
        if (opCase.shape == SHAPE_OK && !_signedByHolder(opCase, model)) return _rejected(reinit, true);
        if (!_allowed(opCase.sigType, action.fn)) return _rejected(reinit, false);

        return _expect(action, ENTRY_POINT, model);
    }

    /// @dev Predicts validateUserOp's result.
    function _expectValidation(uint8 fn, OpCase memory opCase, Model memory model) internal view returns (uint256) {
        bool accepted = opCase.shape == SHAPE_OK && _allowed(opCase.sigType, fn) && _signedByHolder(opCase, model);

        return accepted ? SIG_VALIDATION_SUCCESS : SIG_VALIDATION_FAILED;
    }

    /// @dev A prefund the balance cannot cover is skipped, not reverted.
    function _applyPrefund(uint256 missing, Model memory model) internal pure {
        if (missing == 0 || missing > model.balance) return;

        model.balance -= missing;
        model.prefunded += missing;
    }

    function _rejected(bool reinit, bool stale) internal pure returns (Outcome memory) {
        return Outcome({authorized: false, valid: false, reinit: reinit, stale: stale});
    }

    function _isKnownSigType(uint8 sigType) internal pure returns (bool) {
        return sigType == SIG_SPENDING || sigType == SIG_RECOVERY;
    }

    function _signedByHolder(OpCase memory opCase, Model memory model) internal view returns (bool) {
        return keyAddr[opCase.key] == _holder(opCase.sigType, model);
    }

    /// @dev A rotation reverts for the zero address or either current signer.
    function _applyRotation(bool spendingRole, address signer, Model memory model) internal pure returns (bool) {
        if (signer == address(0) || signer == model.spending || signer == model.recovery) return false;

        if (spendingRole) model.spending = signer;
        else model.recovery = signer;

        return true;
    }

    function _allowed(uint8 sigType, uint8 fn) internal pure returns (bool) {
        if (sigType == SIG_SPENDING) return fn == FN_EXECUTE || fn == FN_BATCH;
        if (sigType == SIG_RECOVERY) return fn == FN_ROTATE_SPENDING || fn == FN_ROTATE_RECOVERY || fn == FN_UPGRADE;

        return false;
    }

    function _holder(uint8 sigType, Model memory model) internal pure returns (address) {
        if (sigType == SIG_SPENDING) return model.spending;
        if (sigType == SIG_RECOVERY) return model.recovery;

        return address(0);
    }

    /// @dev Flags a result that contradicts the prediction. A predicted success commits `post`.
    function _record(bool ok, Outcome memory outcome, Model memory post) internal {
        bool expectedSuccess = outcome.authorized && outcome.valid && !outcome.reinit;

        if (!ok) {
            if (expectedSuccess) validReverted = true;

            return;
        }

        if (outcome.reinit) reinitSucceeded = true;
        else if (!outcome.authorized) unauthorizedSucceeded = true;
        else if (!outcome.valid) invalidSucceeded = true;
        else ghost = post;
    }

    function _executeAction(CallSeed memory seed, Model memory model) internal view returns (Action memory action) {
        action.fn = FN_EXECUTE;
        action.target = address(account);
        action.calls = new BaseAccount.Call[](1);
        action.calls[0] = _call(seed, model);
    }

    function _batchAction(CallSeed[] memory seeds, Model memory model) internal view returns (Action memory action) {
        uint256 count = seeds.length < MAX_BATCH_CALLS ? seeds.length : MAX_BATCH_CALLS;

        action.fn = FN_BATCH;
        action.target = address(account);
        action.calls = new BaseAccount.Call[](count);

        for (uint256 i = 0; i < count; i++) {
            action.calls[i] = _call(seeds[i], model);
        }
    }

    function _rotationAction(uint8 fn, uint8 signerSeed) internal view returns (Action memory action) {
        action.fn = fn;
        action.target = address(account);
        action.signer = _newSigner(signerSeed);
    }

    function _upgradeAction(UpgradeSeed memory seed, Model memory model) internal view returns (Action memory action) {
        action.fn = FN_UPGRADE;
        action.target = address(account);
        action.implementation = _upgradeTarget(seed.implementation);
        action.upgradeData = seed.data % UPGRADE_DATA_COUNT;
        action.signer = _newSigner(seed.signer);
        action.value = _value(seed.value, model);
    }

    /// @dev The pair is two different keys, so only the initializer guard can reject it.
    function _initializeAction(uint8 targetSeed, uint8 signerSeed) internal view returns (Action memory action) {
        uint256 first = signerSeed % KEY_COUNT;

        action.fn = FN_INITIALIZE;
        action.target = _initializeTarget(targetSeed);
        action.signer = keyAddr[first];
        action.signer2 = keyAddr[(first + 1) % KEY_COUNT];
    }

    /// @dev A transfer the spending key may make.
    function _transferAction(uint256 value) internal view returns (Action memory action) {
        action.fn = FN_EXECUTE;
        action.target = address(account);
        action.calls = new BaseAccount.Call[](1);
        action.calls[0] = BaseAccount.Call(BENIGN_TARGET, value, "");
    }

    /// @dev Keeps the current implementation and a value the account can cover.
    function _pinnedUpgradeAction(uint256 valueSeed, Model memory model) internal view returns (Action memory action) {
        action.fn = FN_UPGRADE;
        action.target = address(account);
        action.implementation = model.implementation;
        action.upgradeData = UPGRADE_DATA_EXECUTE;
        action.value = valueSeed % (model.balance + 1);
    }

    /// @dev A transfer out, an ETH self-transfer, or a privileged call the account makes to itself.
    function _call(CallSeed memory seed, Model memory model) internal view returns (BaseAccount.Call memory) {
        uint8 kind = seed.kind % CALL_KIND_COUNT;
        uint256 value = _value(seed.value, model);

        if (kind == CALL_TRANSFER) return BaseAccount.Call(BENIGN_TARGET, value, "");
        if (kind == CALL_SELF_TRANSFER) return BaseAccount.Call(address(account), value, "");

        return BaseAccount.Call(address(account), 0, _privilegedSelfCall(seed.privilegedCall, model));
    }

    /// @dev Valid arguments, so only the authority check can stop the call.
    function _privilegedSelfCall(uint8 seed, Model memory model) internal view returns (bytes memory) {
        address freeSigner = _freeSigner(model);
        bytes[4] memory calls = [
            abi.encodeCall(MozaikAccount.rotateSpendingSigner, (freeSigner)),
            abi.encodeCall(MozaikAccount.rotateRecoverySigner, (freeSigner)),
            abi.encodeCall(account.upgradeToAndCall, (address(altImplementation), "")),
            abi.encodeCall(account.execute, (BENIGN_TARGET, 0, ""))
        ];

        return calls[seed % calls.length];
    }

    /// @dev Up to about twice the balance, so roughly half the values cannot be covered.
    function _value(uint256 seed, Model memory model) internal pure returns (uint256) {
        return seed % (2 * model.balance + 2);
    }

    /// @dev Up to a quarter above the balance, so some prefunds cannot be covered.
    function _prefund(uint256 seed, Model memory model) internal pure returns (uint256) {
        return seed % (model.balance * 5 / 4 + 2);
    }

    /// @dev Any key, or the EntryPoint.
    function _caller(uint8 seed) internal view returns (address) {
        uint256 index = seed % (KEY_COUNT + 1);

        if (index == KEY_COUNT) return ENTRY_POINT;

        return keyAddr[index];
    }

    /// @dev A pooled key or the zero address.
    function _newSigner(uint8 seed) internal view returns (address) {
        uint256 index = seed % (POOL_SIZE + 1);

        if (index == POOL_SIZE) return address(0);

        return keyAddr[index];
    }

    /// @dev Two valid implementations, a codeless address, and a contract without proxiableUUID.
    function _upgradeTarget(uint8 seed) internal view returns (address) {
        address[4] memory targets = [address(implementation), address(altImplementation), BENIGN_TARGET, address(this)];

        return targets[seed % targets.length];
    }

    function _initializeTarget(uint8 seed) internal view returns (address) {
        address[3] memory targets = [address(account), address(implementation), address(altImplementation)];

        return targets[seed % targets.length];
    }

    function _factoryCaller(uint8 seed) internal view returns (address) {
        address[3] memory callers = [senderCreator, keyAddr[STRANGER], ENTRY_POINT];

        return callers[seed % callers.length];
    }

    /// @dev A pooled key that holds neither role. The pool always has one.
    function _freeSigner(Model memory model) internal view returns (address) {
        for (uint256 i = 0; i < POOL_SIZE; i++) {
            if (keyAddr[i] != model.spending && keyAddr[i] != model.recovery) return keyAddr[i];
        }

        return address(0);
    }

    /// @dev Returns 0 when no key matches, as for an unknown sigType.
    function _keyIndex(address signer) internal view returns (uint256) {
        for (uint256 i = 0; i < KEY_COUNT; i++) {
            if (keyAddr[i] == signer) return i;
        }

        return 0;
    }

    function _isValidPair(address spending, address recovery) internal pure returns (bool) {
        return spending != address(0) && recovery != address(0) && spending != recovery;
    }

    function _opCase(OpSeed memory seed, uint8 fn, uint8 shape, Model memory model)
        internal
        view
        returns (OpCase memory)
    {
        uint8 sigType = _sigType(seed.sigType, fn);
        uint256 key = seed.signedByHolder ? _keyIndex(_holder(sigType, model)) : seed.key % KEY_COUNT;

        return OpCase({sigType: sigType, key: key, shape: shape, missing: 0});
    }

    /// @dev A well-formed op from the current spending key, as the EntryPoint would accept it.
    function _spendingOpCase(Model memory model) internal view returns (OpCase memory) {
        return OpCase({sigType: SIG_SPENDING, key: _keyIndex(model.spending), shape: SHAPE_OK, missing: 0});
    }

    /// @dev The role the inner call needs, either role regardless, or an unknown type.
    function _sigType(uint8 seed, uint8 fn) internal pure returns (uint8) {
        uint8 required = fn == FN_EXECUTE || fn == FN_BATCH ? SIG_SPENDING : SIG_RECOVERY;
        uint8[4] memory sigTypes = [required, SIG_SPENDING, SIG_RECOVERY, SIG_UNKNOWN];

        return sigTypes[seed % sigTypes.length];
    }

    function _malformedShape(uint8 seed) internal pure returns (uint8) {
        uint8[4] memory shapes = [SHAPE_BAD_LENGTH, SHAPE_UNRECOVERABLE, SHAPE_UNWRAPPED, SHAPE_SHORT];

        return shapes[seed % shapes.length];
    }

    /// @dev Validation reads only the inner selector. The padding keeps unwrapped callData longer than a selector pair.
    function _innerCallFor(uint8 fn) internal view returns (bytes memory) {
        bytes4[FN_COUNT] memory selectors = [
            account.execute.selector,
            account.executeBatch.selector,
            MozaikAccount.rotateSpendingSigner.selector,
            MozaikAccount.rotateRecoverySigner.selector,
            account.upgradeToAndCall.selector,
            MozaikAccount.initialize.selector
        ];

        return abi.encodePacked(selectors[fn], bytes32(0));
    }

    function _encode(Action memory action) internal view returns (bytes memory) {
        if (action.fn == FN_EXECUTE) {
            BaseAccount.Call memory call = action.calls[0];

            return abi.encodeCall(account.execute, (call.target, call.value, call.data));
        }

        if (action.fn == FN_BATCH) return abi.encodeCall(account.executeBatch, (action.calls));

        if (action.fn == FN_ROTATE_SPENDING) {
            return abi.encodeCall(MozaikAccount.rotateSpendingSigner, (action.signer));
        }
        if (action.fn == FN_ROTATE_RECOVERY) {
            return abi.encodeCall(MozaikAccount.rotateRecoverySigner, (action.signer));
        }
        if (action.fn == FN_UPGRADE) {
            return abi.encodeCall(account.upgradeToAndCall, (action.implementation, _upgradeData(action)));
        }

        return abi.encodeCall(MozaikAccount.initialize, (action.signer, action.signer2));
    }

    function _upgradeData(Action memory action) internal view returns (bytes memory) {
        if (action.upgradeData == UPGRADE_DATA_INITIALIZE) {
            return abi.encodeCall(MozaikAccount.initialize, (keyAddr[STRANGER], keyAddr[0]));
        }
        if (action.upgradeData == UPGRADE_DATA_EXECUTE) {
            return abi.encodeCall(account.execute, (BENIGN_TARGET, action.value, ""));
        }
        if (action.upgradeData == UPGRADE_DATA_ROTATE) {
            return abi.encodeCall(MozaikAccount.rotateSpendingSigner, (action.signer));
        }

        return "";
    }

    function _validateCall(bytes memory inner, OpCase memory opCase) internal returns (bytes memory) {
        (PackedUserOperation memory op, bytes32 hash) = _userOp(inner, opCase);

        return abi.encodeCall(account.validateUserOp, (op, hash, opCase.missing));
    }

    function _executeUserOpCall(bytes memory inner, OpCase memory opCase) internal returns (bytes memory) {
        (PackedUserOperation memory op, bytes32 hash) = _userOp(inner, opCase);

        return abi.encodeCall(MozaikAccount.executeUserOp, (op, hash));
    }

    /// @dev The account trusts the EntryPoint's hash, so any unique hash will do.
    function _userOp(bytes memory inner, OpCase memory opCase)
        internal
        returns (PackedUserOperation memory op, bytes32 hash)
    {
        op.sender = address(account);
        op.nonce = ++opCount;
        op.callData = _opCallData(inner, opCase.shape);

        hash = keccak256(abi.encode(address(account), op.nonce, op.callData));
        op.signature = _opSignature(opCase, hash);
    }

    function _opCallData(bytes memory inner, uint8 shape) internal pure returns (bytes memory) {
        bytes4 wrapper = IAccountExecute.executeUserOp.selector;

        if (shape == SHAPE_UNWRAPPED) return inner;
        if (shape == SHAPE_SHORT) return abi.encodePacked(wrapper);

        return abi.encodePacked(wrapper, inner);
    }

    function _opSignature(OpCase memory opCase, bytes32 hash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[opCase.key], hash);

        if (opCase.shape == SHAPE_BAD_LENGTH) return abi.encodePacked(opCase.sigType, r, s, v, uint8(0));
        if (opCase.shape == SHAPE_UNRECOVERABLE) return abi.encodePacked(opCase.sigType, r, s, uint8(0));

        return abi.encodePacked(opCase.sigType, r, s, v);
    }

    /// @dev CREATE2 address computed without the factory.
    function _predictAccount(address spending, address recovery) internal view returns (address) {
        bytes memory initData = abi.encodeCall(MozaikAccount.initialize, (spending, recovery));
        bytes memory initCode =
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(factoryImplementation, initData));
        bytes32 salt = keccak256(abi.encode(spending, recovery));

        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(initCode)))))
        );
    }

    function _createdAsPredicted(address created, address predicted, address spending, address recovery)
        internal
        view
        returns (bool)
    {
        if (created != predicted || created.code.length == 0) return false;

        bytes32 slot = vm.load(created, ERC1967Utils.IMPLEMENTATION_SLOT);

        return MozaikAccount(payable(created)).spendingSigner() == spending
            && MozaikAccount(payable(created)).recoverySigner() == recovery
            && address(uint160(uint256(slot))) == factoryImplementation;
    }
}
