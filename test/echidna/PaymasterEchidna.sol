// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {IStakeManager} from "account-abstraction/interfaces/IStakeManager.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {BasePaymaster} from "account-abstraction/core/BasePaymaster.sol";
import {ValidationData, _packValidationData, _parseValidationData} from "account-abstraction/core/Helpers.sol";
import {MozaikVerifyingPaymaster} from "../../src/paymaster/MozaikVerifyingPaymaster.sol";

/// @notice Echidna fuzz target for MozaikVerifyingPaymaster.
/// @dev Validates fuzzed ops, signers and windows as the EntryPoint, on the paymaster and on a twin with the
///      same sponsor. Several callers call the owner functions. Every result is checked against a model of the
///      owner, pending owner and sponsor. Chain id binding is out of scope: Echidna has no chainId cheatcode.
contract PaymasterEchidna {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant ENTRY_POINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;
    EntryPoint internal constant ENTRY_POINT = EntryPoint(payable(ENTRY_POINT_V09));

    /// @dev Marks the signature suffix in paymasterAndData. It is keccak256("PaymasterSignature")[:8].
    bytes8 internal constant PAYMASTER_SIG_MAGIC = 0x22e325a297439656;

    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant SECP256K1_HALF_N = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    uint256 internal constant KEY_POOL = 4;
    uint256 internal constant CALLER_POOL = 4;

    /// @dev Short enough for Echidna's time jumps to pass, so withdrawStake is reachable.
    uint32 internal constant MAX_UNSTAKE_DELAY = 3 days;

    /// @dev The owner, the pending owner and the sponsor's index in the key pool.
    struct Roles {
        address owner;
        address pending;
        uint256 sponsorKey;
    }

    /// @dev A call's predicted outcome. Only an authorized, valid call that succeeds changes the model.
    struct Outcome {
        bool authorized;
        bool valid;
    }

    /// @dev What the fuzzer picks for a signed op. The op's fields derive from `seed`.
    struct SignRequest {
        uint8 keySeed;
        bool forTwin;
        uint48 validUntil;
        uint48 validAfter;
        uint256 seed;
        bytes callData;
    }

    /// @dev A sponsor approval as signed, and the window the validated op carries.
    struct Approval {
        bytes sig;
        bytes32 signedDigest;
        bool validSigner;
        uint48 validUntil;
        uint48 validAfter;
        uint256 seed;
    }

    /// @dev An op signed by the current sponsor, for the signature encoding actions.
    struct Probe {
        PackedUserOperation op;
        bytes32 digest;
        uint8 v;
        bytes32 r;
        bytes32 s;
        uint48 validUntil;
        uint48 validAfter;
        uint256 seed;
    }

    MozaikVerifyingPaymaster internal paymaster;

    /// @dev Same sponsor as `paymaster`. An approval signed for one must fail on the other.
    MozaikVerifyingPaymaster internal twin;

    uint256[KEY_POOL] internal keys;
    address[KEY_POOL] internal signers;

    /// @dev callers[0] is the harness itself. The rest are codeless EOAs.
    address[CALLER_POOL] internal callers;

    uint256 internal initialEth;

    Roles internal roles;

    bool internal validationMismatch;
    bool internal validationReverted;
    bool internal contextNotEmpty;
    bool internal nonEntryPointValidated;
    bool internal signatureMismatch;
    bool internal accessViolation;
    bool internal modelMismatch;

    constructor() payable {
        for (uint256 i = 0; i < KEY_POOL; i++) {
            keys[i] = uint256(keccak256(abi.encode("mozaik.echidna.sponsor", i))) % (SECP256K1_N - 1) + 1;
            signers[i] = vm.addr(keys[i]);
        }

        callers[0] = address(this);
        callers[1] = address(0xA11CE);
        callers[2] = address(0xB0B);
        callers[3] = address(0xCAFE);

        paymaster = new MozaikVerifyingPaymaster(signers[0]);
        twin = new MozaikVerifyingPaymaster(signers[0]);

        roles = Roles({owner: address(this), pending: address(0), sponsorKey: 0});
        initialEth = address(this).balance;
    }

    receive() external payable {}

    /// @notice Validation sponsors exactly the ops the sponsor signed for this paymaster, and
    ///         returns the window unchanged.
    function echidna_validation_matches_model() external view returns (bool) {
        return !validationMismatch;
    }

    /// @notice A well-formed paymasterAndData never makes validation revert. A bad approval
    ///         returns sigFailed instead, so bundlers can simulate.
    function echidna_validation_never_reverts() external view returns (bool) {
        return !validationReverted;
    }

    /// @notice Validation always returns an empty context, so postOp never runs.
    function echidna_context_always_empty() external view returns (bool) {
        return !contextNotEmpty;
    }

    /// @notice Only the EntryPoint can call validatePaymasterUserOp.
    function echidna_only_entrypoint_validates() external view returns (bool) {
        return !nonEntryPointValidated;
    }

    /// @notice A signature is accepted only if it is a 65-byte low-s signature by the sponsor
    ///         (no malleable, compact, raw-v or unmarked forms).
    function echidna_signature_encoding_matches_model() external view returns (bool) {
        return !signatureMismatch;
    }

    /// @notice Owner functions and acceptOwnership revert with OwnableUnauthorizedAccount for any
    ///         other caller, and renounceOwnership always reverts.
    function echidna_access_control_holds() external view returns (bool) {
        return !accessViolation;
    }

    /// @notice Authorized owner calls and deposits succeed exactly when the EntryPoint accepts
    ///         them, and move the expected amounts.
    function echidna_owner_calls_match_model() external view returns (bool) {
        return !modelMismatch;
    }

    /// @notice Owner, pending owner and sponsor always equal the model, which changes only on
    ///         authorized calls.
    function echidna_roles_match_model() external view returns (bool) {
        address sponsor = signers[roles.sponsorKey];

        return paymaster.owner() == roles.owner && paymaster.pendingOwner() == roles.pending
            && paymaster.sponsor() == sponsor && twin.sponsor() == sponsor;
    }

    /// @notice No ETH is created or lost: the harness, the callers, both paymasters and their
    ///         EntryPoint deposits and stakes always hold the starting balance.
    function echidna_eth_conserved() external view returns (bool) {
        uint256 total = _heldFor(address(paymaster)) + _heldFor(address(twin));
        for (uint256 i = 0; i < CALLER_POOL; i++) {
            total += callers[i].balance;
        }

        return total == initialEth;
    }

    /// @notice Validates a signed op, unchanged, on both paymasters.
    function validateOp(SignRequest calldata request) external {
        (PackedUserOperation memory op, Approval memory approval) = _signedOp(request);

        _validateOnBoth(op, approval);
    }

    /// @notice Validates a signed op whose sender changed after signing.
    function validateTamperedSender(SignRequest calldata request, address sender) external {
        (PackedUserOperation memory op, Approval memory approval) = _signedOp(request);
        op.sender = sender;

        _validateOnBoth(op, approval);
    }

    /// @notice Validates a signed op whose nonce changed after signing.
    function validateTamperedNonce(SignRequest calldata request, uint256 nonce) external {
        (PackedUserOperation memory op, Approval memory approval) = _signedOp(request);
        op.nonce = nonce;

        _validateOnBoth(op, approval);
    }

    /// @notice Validates a signed op whose initCode changed after signing.
    function validateTamperedInitCode(SignRequest calldata request, uint256 initCodeWord) external {
        (PackedUserOperation memory op, Approval memory approval) = _signedOp(request);
        op.initCode = abi.encodePacked(initCodeWord);

        _validateOnBoth(op, approval);
    }

    /// @notice Validates a signed op whose callData changed after signing.
    function validateTamperedCallData(SignRequest calldata request, uint256 callDataWord) external {
        (PackedUserOperation memory op, Approval memory approval) = _signedOp(request);
        op.callData = abi.encodePacked(callDataWord);

        _validateOnBoth(op, approval);
    }

    /// @notice Validates a signed op whose accountGasLimits changed after signing.
    function validateTamperedAccountGasLimits(SignRequest calldata request, bytes32 accountGasLimits) external {
        (PackedUserOperation memory op, Approval memory approval) = _signedOp(request);
        op.accountGasLimits = accountGasLimits;

        _validateOnBoth(op, approval);
    }

    /// @notice Validates a signed op whose preVerificationGas changed after signing.
    function validateTamperedPreVerificationGas(SignRequest calldata request, uint256 preVerificationGas) external {
        (PackedUserOperation memory op, Approval memory approval) = _signedOp(request);
        op.preVerificationGas = preVerificationGas;

        _validateOnBoth(op, approval);
    }

    /// @notice Validates a signed op whose gasFees changed after signing.
    function validateTamperedGasFees(SignRequest calldata request, bytes32 gasFees) external {
        (PackedUserOperation memory op, Approval memory approval) = _signedOp(request);
        op.gasFees = gasFees;

        _validateOnBoth(op, approval);
    }

    /// @notice Validates a signed op whose validUntil changed after signing.
    function validateTamperedValidUntil(SignRequest calldata request, uint48 validUntil) external {
        (PackedUserOperation memory op, Approval memory approval) = _signedOp(request);
        approval.validUntil = validUntil;

        _validateOnBoth(op, approval);
    }

    /// @notice Validates a signed op whose validAfter changed after signing.
    function validateTamperedValidAfter(SignRequest calldata request, uint48 validAfter) external {
        (PackedUserOperation memory op, Approval memory approval) = _signedOp(request);
        approval.validAfter = validAfter;

        _validateOnBoth(op, approval);
    }

    /// @notice Validates an op whose signature is fuzzed bytes.
    function validateRawSignature(bytes calldata raw, uint256 seed, uint48 validUntil, uint48 validAfter) external {
        // The suffix stores the signature length in 2 bytes.
        if (raw.length > type(uint16).max) return;

        _checkProbe(_sponsorProbe(seed, validUntil, validAfter), raw, PAYMASTER_SIG_MAGIC);
    }

    /// @notice Validates an op with the sponsor's canonical signature, which must be sponsored.
    function validateCanonicalSignature(uint256 seed, uint48 validUntil, uint48 validAfter) external {
        Probe memory probe = _sponsorProbe(seed, validUntil, validAfter);

        _checkProbe(probe, _canonical(probe.v, probe.r, probe.s), PAYMASTER_SIG_MAGIC);
    }

    /// @notice Validates an op with the malleable high-s form of the sponsor's signature.
    function validateHighSSignature(uint256 seed, uint48 validUntil, uint48 validAfter) external {
        Probe memory probe = _sponsorProbe(seed, validUntil, validAfter);

        _checkProbe(probe, _highS(probe.v, probe.r, probe.s), PAYMASTER_SIG_MAGIC);
    }

    /// @notice Validates an op with the sponsor's signature and one trailing byte.
    function validatePaddedSignature(uint256 seed, uint48 validUntil, uint48 validAfter) external {
        Probe memory probe = _sponsorProbe(seed, validUntil, validAfter);

        _checkProbe(probe, _padded(probe.v, probe.r, probe.s), PAYMASTER_SIG_MAGIC);
    }

    /// @notice Validates an op with the 64-byte compact form of the sponsor's signature.
    function validateCompactSignature(uint256 seed, uint48 validUntil, uint48 validAfter) external {
        Probe memory probe = _sponsorProbe(seed, validUntil, validAfter);

        _checkProbe(probe, _compact(probe.v, probe.r, probe.s), PAYMASTER_SIG_MAGIC);
    }

    /// @notice Validates an op with the sponsor's signature carrying v as 0 or 1.
    function validateRawVSignature(uint256 seed, uint48 validUntil, uint48 validAfter) external {
        Probe memory probe = _sponsorProbe(seed, validUntil, validAfter);

        _checkProbe(probe, _rawV(probe.v, probe.r, probe.s), PAYMASTER_SIG_MAGIC);
    }

    /// @notice Validates an op with the sponsor's signature behind a wrong suffix marker.
    function validateUnmarkedSignature(uint256 seed, uint48 validUntil, uint48 validAfter) external {
        Probe memory probe = _sponsorProbe(seed, validUntil, validAfter);

        _checkProbe(probe, _canonical(probe.v, probe.r, probe.s), ~PAYMASTER_SIG_MAGIC);
    }

    /// @notice A caller other than the EntryPoint validates a sponsored op, which must revert.
    function validateFromNonEntryPoint(uint8 callerSeed, uint256 seed) external {
        Probe memory probe = _sponsorProbe(seed, 0, 0);
        bytes memory sig = _canonical(probe.v, probe.r, probe.s);
        probe.op.paymasterAndData = _paymasterAndData(address(paymaster), bytes32(seed), 0, 0, sig, PAYMASTER_SIG_MAGIC);
        bytes memory data = abi.encodeCall(paymaster.validatePaymasterUserOp, (probe.op, bytes32(0), 0));

        (bool ok, bytes memory ret) = _callAs(_caller(callerSeed), 0, data);

        if (ok || _selector(ret) != BasePaymaster.NotFromEntryPoint.selector) nonEntryPointValidated = true;
    }

    /// @notice Any caller sets the sponsor to a pool key.
    function setSponsor(uint8 callerSeed, uint8 keySeed) external {
        address caller = _caller(callerSeed);
        uint256 keyIndex = keySeed % KEY_POOL;
        Roles memory next = roles;
        Outcome memory outcome = _expectSetSponsor(caller, keyIndex, next);
        bytes memory data = abi.encodeCall(paymaster.setSponsor, (signers[keyIndex]));

        (bool ok, bytes memory ret) = _callAs(caller, 0, data);

        if (!_settle(outcome, ok, ret)) return;

        roles = next;
        twin.setSponsor(signers[keyIndex]);
    }

    /// @notice Any caller sets the sponsor to the zero address, which the paymaster rejects.
    function setSponsorToZero(uint8 callerSeed) external {
        address caller = _caller(callerSeed);
        Outcome memory outcome = _ownerCall(caller, false);
        bytes memory data = abi.encodeCall(paymaster.setSponsor, (address(0)));

        (bool ok, bytes memory ret) = _callAs(caller, 0, data);

        _settle(outcome, ok, ret);
    }

    /// @notice Any caller withdraws up to one wei more than the deposit, to any caller.
    function withdrawTo(uint8 callerSeed, uint8 recipientSeed, uint256 amountSeed) external {
        address caller = _caller(callerSeed);
        address payable recipient = _recipient(recipientSeed);
        uint256 depositBefore = ENTRY_POINT.balanceOf(address(paymaster));
        uint256 amount = amountSeed % (depositBefore + 2);
        uint256 recipientBefore = recipient.balance;
        Outcome memory outcome = _ownerCall(caller, amount <= depositBefore);
        bytes memory data = abi.encodeCall(paymaster.withdrawTo, (recipient, amount));

        (bool ok, bytes memory ret) = _callAs(caller, 0, data);

        if (!_settle(outcome, ok, ret)) return;

        bool paid = recipient.balance == recipientBefore + amount;
        if (!paid || ENTRY_POINT.balanceOf(address(paymaster)) != depositBefore - amount) modelMismatch = true;
    }

    /// @notice Any caller adds stake with a delay below MAX_UNSTAKE_DELAY, paying the value itself.
    function addStake(uint8 callerSeed, uint32 delaySeed, uint96 valueSeed) external {
        address caller = _caller(callerSeed);
        uint32 delay = delaySeed % MAX_UNSTAKE_DELAY;
        uint256 value = _spendable(valueSeed);
        if (!_fund(caller, value)) return;

        IStakeManager.DepositInfo memory before = _depositInfo();
        Outcome memory outcome = _ownerCall(caller, _addStakeValid(delay, value, before));
        bytes memory data = abi.encodeCall(paymaster.addStake, (delay));

        (bool ok, bytes memory ret) = _callAs(caller, value, data);

        if (_settle(outcome, ok, ret)) _checkStakeAdded(before, delay, value);
    }

    /// @notice Any caller unlocks the stake.
    function unlockStake(uint8 callerSeed) external {
        address caller = _caller(callerSeed);
        IStakeManager.DepositInfo memory before = _depositInfo();
        Outcome memory outcome = _ownerCall(caller, _unlockValid(before));

        (bool ok, bytes memory ret) = _callAs(caller, 0, abi.encodeCall(paymaster.unlockStake, ()));

        if (_settle(outcome, ok, ret)) _checkUnlocked(before);
    }

    /// @notice Any caller withdraws the stake to any caller.
    function withdrawStake(uint8 callerSeed, uint8 recipientSeed) external {
        address caller = _caller(callerSeed);
        address payable recipient = _recipient(recipientSeed);
        IStakeManager.DepositInfo memory before = _depositInfo();
        uint256 recipientBefore = recipient.balance;
        Outcome memory outcome = _ownerCall(caller, _withdrawStakeValid(before));
        bytes memory data = abi.encodeCall(paymaster.withdrawStake, (recipient));

        (bool ok, bytes memory ret) = _callAs(caller, 0, data);

        if (!_settle(outcome, ok, ret)) return;

        if (recipient.balance != recipientBefore + before.stake || _depositInfo().stake != 0) modelMismatch = true;
    }

    /// @notice Any caller proposes any caller as the next owner.
    function transferOwnership(uint8 callerSeed, uint8 newOwnerSeed) external {
        _proposeOwner(_caller(callerSeed), _caller(newOwnerSeed));
    }

    /// @notice Any caller cancels a pending ownership transfer.
    function cancelOwnershipTransfer(uint8 callerSeed) external {
        _proposeOwner(_caller(callerSeed), address(0));
    }

    /// @notice Any caller accepts ownership. Only the pending owner is authorized.
    function acceptOwnership(uint8 callerSeed) external {
        address caller = _caller(callerSeed);
        Roles memory next = roles;
        Outcome memory outcome = _expectAccept(caller, next);

        (bool ok, bytes memory ret) = _callAs(caller, 0, abi.encodeCall(paymaster.acceptOwnership, ()));

        if (_settle(outcome, ok, ret)) roles = next;
    }

    /// @notice Any caller renounces ownership, which must revert with RenounceDisabled.
    function renounceOwnership(uint8 callerSeed) external {
        bytes memory data = abi.encodeCall(paymaster.renounceOwnership, ());

        (bool ok, bytes memory ret) = _callAs(_caller(callerSeed), 0, data);

        if (ok || _selector(ret) != MozaikVerifyingPaymaster.RenounceDisabled.selector) accessViolation = true;
    }

    /// @notice Anyone deposits, and the paymaster's EntryPoint deposit grows by exactly the amount.
    function deposit(uint8 callerSeed, uint96 amountSeed) external {
        address caller = _caller(callerSeed);
        uint256 amount = _spendable(amountSeed);
        if (!_fund(caller, amount)) return;

        uint256 before = ENTRY_POINT.balanceOf(address(paymaster));

        (bool ok,) = _callAs(caller, amount, abi.encodeCall(paymaster.deposit, ()));

        if (!ok || ENTRY_POINT.balanceOf(address(paymaster)) != before + amount) modelMismatch = true;
    }

    /// @dev Records a call against its prediction. Returns true when an authorized, valid call succeeded.
    function _settle(Outcome memory outcome, bool ok, bytes memory ret) internal returns (bool) {
        if (!outcome.authorized) {
            if (ok || _selector(ret) != Ownable.OwnableUnauthorizedAccount.selector) accessViolation = true;

            return false;
        }

        if (ok != outcome.valid) modelMismatch = true;

        return ok && outcome.valid;
    }

    /// @dev An owner-only call. `valid` is the call's own precondition.
    function _ownerCall(address caller, bool valid) internal view returns (Outcome memory) {
        return Outcome({authorized: caller == roles.owner, valid: valid});
    }

    function _expectSetSponsor(address caller, uint256 keyIndex, Roles memory next)
        internal
        pure
        returns (Outcome memory outcome)
    {
        outcome = Outcome({authorized: caller == next.owner, valid: true});
        next.sponsorKey = keyIndex;
    }

    /// @dev address(0) cancels a pending transfer.
    function _expectTransfer(address caller, address newOwner, Roles memory next)
        internal
        pure
        returns (Outcome memory outcome)
    {
        outcome = Outcome({authorized: caller == next.owner, valid: true});
        next.pending = newOwner;
    }

    function _expectAccept(address caller, Roles memory next) internal pure returns (Outcome memory outcome) {
        outcome = Outcome({authorized: caller == next.pending, valid: true});
        next.owner = caller;
        next.pending = address(0);
    }

    /// @dev The EntryPoint takes a nonzero delay that does not shrink, and a nonzero total stake.
    function _addStakeValid(uint32 delay, uint256 value, IStakeManager.DepositInfo memory info)
        internal
        pure
        returns (bool)
    {
        return delay > 0 && delay >= info.unstakeDelaySec && uint256(info.stake) + value > 0;
    }

    /// @dev Only a locked stake can be unlocked.
    function _unlockValid(IStakeManager.DepositInfo memory info) internal pure returns (bool) {
        return info.unstakeDelaySec != 0 && info.staked;
    }

    /// @dev Only an unlocked stake whose delay has passed can be withdrawn.
    function _withdrawStakeValid(IStakeManager.DepositInfo memory info) internal view returns (bool) {
        return info.stake > 0 && info.withdrawTime > 0 && info.withdrawTime <= block.timestamp;
    }

    function _proposeOwner(address caller, address newOwner) internal {
        Roles memory next = roles;
        Outcome memory outcome = _expectTransfer(caller, newOwner, next);
        bytes memory data = abi.encodeCall(paymaster.transferOwnership, (newOwner));

        (bool ok, bytes memory ret) = _callAs(caller, 0, data);

        if (_settle(outcome, ok, ret)) roles = next;
    }

    function _checkStakeAdded(IStakeManager.DepositInfo memory before, uint32 delay, uint256 value) internal {
        IStakeManager.DepositInfo memory info = _depositInfo();
        bool locked = info.staked && info.withdrawTime == 0 && info.unstakeDelaySec == delay;

        if (!locked || info.stake != uint256(before.stake) + value) modelMismatch = true;
    }

    function _checkUnlocked(IStakeManager.DepositInfo memory before) internal {
        IStakeManager.DepositInfo memory info = _depositInfo();

        if (info.staked || info.withdrawTime != block.timestamp + before.unstakeDelaySec) modelMismatch = true;
    }

    /// @dev Calls the paymaster as `caller`. The harness calls without a prank.
    function _callAs(address caller, uint256 value, bytes memory data) internal returns (bool ok, bytes memory ret) {
        if (caller != address(this)) vm.prank(caller);

        return address(paymaster).call{value: value}(data);
    }

    /// @dev Validates `op` on `target` as the EntryPoint. A revert or a non-empty context sets its flag.
    function _validate(MozaikVerifyingPaymaster target, PackedUserOperation memory op, uint256 seed)
        internal
        returns (bool ok, uint256 validationData)
    {
        bytes memory data = abi.encodeCall(target.validatePaymasterUserOp, (op, keccak256(abi.encode(seed)), seed));
        bytes memory ret;

        vm.prank(ENTRY_POINT_V09);
        (ok, ret) = address(target).call(data);

        if (!ok) {
            validationReverted = true;

            return (false, 0);
        }

        bytes memory context;
        (context, validationData) = abi.decode(ret, (bytes, uint256));
        if (context.length != 0) contextNotEmpty = true;
    }

    function _validateOnBoth(PackedUserOperation memory op, Approval memory approval) internal {
        _validateOn(paymaster, op, approval);
        _validateOn(twin, op, approval);
    }

    function _validateOn(MozaikVerifyingPaymaster target, PackedUserOperation memory op, Approval memory approval)
        internal
    {
        op.paymasterAndData = _paymasterAndData(
            address(target),
            bytes32(approval.seed),
            approval.validUntil,
            approval.validAfter,
            approval.sig,
            PAYMASTER_SIG_MAGIC
        );
        bool sponsored = _expectSponsored(address(target), op, approval);

        (bool ok, uint256 validationData) = _validate(target, op, approval.seed);

        if (ok && !_matches(validationData, !sponsored, approval.validUntil, approval.validAfter)) {
            validationMismatch = true;
        }
    }

    /// @dev Sponsored only when a valid signer signed this paymaster's digest of the op as validated.
    function _expectSponsored(address target, PackedUserOperation memory op, Approval memory approval)
        internal
        view
        returns (bool)
    {
        return approval.validSigner
            && _digest(target, op, approval.validUntil, approval.validAfter) == approval.signedDigest;
    }

    /// @dev Only a marked 65-byte low-s signature by the sponsor may be sponsored.
    function _checkProbe(Probe memory probe, bytes memory sig, bytes8 magic) internal {
        bool sponsored = magic == PAYMASTER_SIG_MAGIC && _isSponsorSignature(probe.digest, sig);
        probe.op.paymasterAndData =
            _paymasterAndData(address(paymaster), bytes32(0), probe.validUntil, probe.validAfter, sig, magic);

        (bool ok, uint256 validationData) = _validate(paymaster, probe.op, probe.seed);

        if (ok && !_matches(validationData, !sponsored, probe.validUntil, probe.validAfter)) signatureMismatch = true;
    }

    /// @dev Compares validation data the way the EntryPoint reads it.
    function _matches(uint256 validationData, bool sigFailed, uint48 validUntil, uint48 validAfter)
        internal
        pure
        returns (bool)
    {
        ValidationData memory got = _parseValidationData(validationData);
        ValidationData memory want = _parseValidationData(_packValidationData(sigFailed, validUntil, validAfter));

        return
            got.aggregator == want.aggregator && got.validUntil == want.validUntil && got.validAfter == want.validAfter;
    }

    /// @dev The sponsor approval digest, computed independently of the paymaster.
    function _digest(address target, PackedUserOperation memory op, uint48 validUntil, uint48 validAfter)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                target,
                block.chainid,
                op.sender,
                op.nonce,
                keccak256(op.initCode),
                keccak256(op.callData),
                op.accountGasLimits,
                op.preVerificationGas,
                op.gasFees,
                validUntil,
                validAfter
            )
        );
    }

    /// @dev ECDSA acceptance rule: 65 bytes, low s, and ecrecover returns the model sponsor.
    function _isSponsorSignature(bytes32 digest, bytes memory sig) internal view returns (bool) {
        if (sig.length != 65) return false;

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        if (uint256(s) > SECP256K1_HALF_N) return false;

        address recovered = ecrecover(digest, v, r, s);

        return recovered != address(0) && recovered == signers[roles.sponsorKey];
    }

    /// @dev Builds the request's op and signs it for the paymaster or the twin.
    function _signedOp(SignRequest calldata request)
        internal
        view
        returns (PackedUserOperation memory op, Approval memory approval)
    {
        op = _buildOp(request.seed, request.callData);
        address signedFor = request.forTwin ? address(twin) : address(paymaster);
        uint256 key = _signerKey(request.keySeed);
        bytes32 digest = _digest(signedFor, op, request.validUntil, request.validAfter);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);

        approval = Approval({
            sig: _canonical(v, r, s),
            signedDigest: digest,
            validSigner: key == keys[roles.sponsorKey] && uint256(s) <= SECP256K1_HALF_N,
            validUntil: request.validUntil,
            validAfter: request.validAfter,
            seed: request.seed
        });
    }

    /// @dev An op signed by the current sponsor over this paymaster's digest.
    function _sponsorProbe(uint256 seed, uint48 validUntil, uint48 validAfter)
        internal
        view
        returns (Probe memory probe)
    {
        probe.op = _buildOp(seed, abi.encode(seed));
        probe.digest = _digest(address(paymaster), probe.op, validUntil, validAfter);
        (probe.v, probe.r, probe.s) = vm.sign(keys[roles.sponsorKey], probe.digest);
        probe.validUntil = validUntil;
        probe.validAfter = validAfter;
        probe.seed = seed;
    }

    /// @dev A pool key, or the current sponsor's key for the extra slot.
    function _signerKey(uint8 keySeed) internal view returns (uint256) {
        uint256 index = keySeed % (KEY_POOL + 1);

        return index == KEY_POOL ? keys[roles.sponsorKey] : keys[index];
    }

    /// @dev The harness or one of the EOAs.
    function _caller(uint8 callerSeed) internal view returns (address) {
        return callers[callerSeed % CALLER_POOL];
    }

    function _recipient(uint8 recipientSeed) internal view returns (address payable) {
        return payable(_caller(recipientSeed));
    }

    /// @dev Up to a sixteenth of the harness balance.
    function _spendable(uint96 amountSeed) internal view returns (uint256) {
        return uint256(amountSeed) % (address(this).balance / 16 + 1);
    }

    function _buildOp(uint256 seed, bytes memory callData) internal pure returns (PackedUserOperation memory op) {
        op.sender = address(uint160(uint256(keccak256(abi.encode(seed, 0)))));
        op.nonce = seed;
        op.initCode = seed % 3 == 0 ? bytes("") : abi.encodePacked(keccak256(abi.encode(seed, 1)));
        op.callData = callData;
        op.accountGasLimits = keccak256(abi.encode(seed, 2));
        op.preVerificationGas = uint256(keccak256(abi.encode(seed, 3))) >> 192;
        op.gasFees = keccak256(abi.encode(seed, 4));
        op.signature = abi.encodePacked(keccak256(abi.encode(seed, 5)));
    }

    /// @dev Header || window || sig || uint16(sig.length) || magic. The approval does not cover the header's gas limits.
    function _paymasterAndData(
        address target,
        bytes32 gasLimits,
        uint48 validUntil,
        uint48 validAfter,
        bytes memory sig,
        bytes8 magic
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(target, gasLimits, validUntil, validAfter, sig, uint16(sig.length), magic);
    }

    /// @dev r || s || v, the only accepted form.
    function _canonical(uint8 v, bytes32 r, bytes32 s) internal pure returns (bytes memory) {
        return abi.encodePacked(r, s, v);
    }

    /// @dev The same signature with s in the upper half and v flipped.
    function _highS(uint8 v, bytes32 r, bytes32 s) internal pure returns (bytes memory) {
        uint8 flippedV = v == 27 ? 28 : 27;

        return abi.encodePacked(r, bytes32(SECP256K1_N - uint256(s)), flippedV);
    }

    function _padded(uint8 v, bytes32 r, bytes32 s) internal pure returns (bytes memory) {
        return abi.encodePacked(r, s, v, uint8(0));
    }

    /// @dev The 64-byte ERC-2098 form r || yParity-and-s.
    function _compact(uint8 v, bytes32 r, bytes32 s) internal pure returns (bytes memory) {
        return abi.encodePacked(r, bytes32(uint256(s) | (uint256(v - 27) << 255)));
    }

    function _rawV(uint8 v, bytes32 r, bytes32 s) internal pure returns (bytes memory) {
        return abi.encodePacked(r, s, v - 27);
    }

    /// @dev The error selector of revert data. Shorter data is zero-padded.
    function _selector(bytes memory ret) internal pure returns (bytes4) {
        return bytes4(ret);
    }

    /// @dev Moves `amount` from the harness to `caller`.
    function _fund(address caller, uint256 amount) internal returns (bool) {
        if (caller == address(this) || amount == 0) return true;

        (bool ok,) = payable(caller).call{value: amount}("");

        return ok;
    }

    function _depositInfo() internal view returns (IStakeManager.DepositInfo memory) {
        return ENTRY_POINT.getDepositInfo(address(paymaster));
    }

    /// @dev ETH held for a paymaster: its own balance plus its EntryPoint deposit and stake.
    function _heldFor(address paymasterAddress) internal view returns (uint256) {
        IStakeManager.DepositInfo memory info = ENTRY_POINT.getDepositInfo(paymasterAddress);

        return paymasterAddress.balance + info.deposit + info.stake;
    }
}
