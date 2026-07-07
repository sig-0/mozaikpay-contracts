# MozaikPay Contracts

This document covers deploying the MozaikPay smart contracts to Base Sepolia (testnet) and Base mainnet.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed (`forge`, `cast`)
- A deployer wallet with ETH on the target chain (for gas)
- A sponsor wallet (hot wallet) whose private key the API will use to sign paymaster approvals
- An RPC endpoint for the target chain. The Makefile defaults to the public Base endpoints
  (`https://sepolia.base.org`, `https://mainnet.base.org`); set `BASE_SEPOLIA_RPC` /
  `BASE_MAINNET_RPC` to use your own (recommended for mainnet)

## Chain Reference

| Parameter       | Base Sepolia (testnet)                        | Base Mainnet                                  |
|-----------------|-----------------------------------------------|-----------------------------------------------|
| Chain ID        | `84532`                                       | `8453`                                        |
| RPC (Infura)    | `https://base-sepolia.infura.io/v3/<API_KEY>` | `https://base-mainnet.infura.io/v3/<API_KEY>` |
| EntryPoint v0.9 | `0x433709009B8330FDa32311DF1C2AFA402eD8D009`  | `0x433709009B8330FDa32311DF1C2AFA402eD8D009`  |
| USDC            | `0x036CbD53842c5426634e7929541eC2318f3dCF7e`  | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`  |
| Block explorer  | `https://sepolia.basescan.org`                | `https://basescan.org`                        |

The EntryPoint v0.9 is already deployed at the canonical address on both chains via deterministic CREATE2.
You do **not** need to deploy it.

## Contracts Overview

Four contracts are deployed per environment:

1. **MozaikAccountFactory** -- CREATE2 factory for deploying ERC-4337 smart accounts. The canonical EntryPoint v0.9 is
   hardcoded (not a constructor argument), matching the account, so deployment and runtime authority cannot diverge.
2. **MozaikVerifyingPaymaster** -- Sponsors gas for UserOperations. Constructor takes the sponsor wallet address; the
   canonical EntryPoint v0.9 is hardcoded.
3. **MozaikAccount** (implementation) -- Deployed automatically by the factory constructor. Not called directly.
4. **MozaikPaylinks** -- Non-upgradeable USDC escrow for payment links. Deployed by `01_Deploy.s.sol` alongside the
   account/paymaster stack, bound to the chain's USDC.
   Constructor takes the USDC token address; immutable thereafter. Lifecycle: `create` (sender locks USDC under an
   ephemeral `claimSigner`), `claim` (recipient redeems with an EIP-712 signature over the claim payload), `reclaim`
   (sender returns funds; sender-only pre-expiry, permissionless at or after expiry).

## Environment Variables

Create a `.env` file in `contracts/` (copy from `.env.example`):

```bash
# RPC endpoints (used by foundry.toml rpc_endpoints)
BASE_SEPOLIA_RPC=https://base-sepolia.infura.io/v3/<YOUR_INFURA_KEY>
BASE_MAINNET_RPC=https://base-mainnet.infura.io/v3/<YOUR_INFURA_KEY>

# 01_Deploy.s.sol -- the address that will sign paymaster approvals
# This is the PUBLIC address of your sponsor hot wallet
SPONSOR_ADDRESS=0x<your_sponsor_public_address>

# 02_FundPaymaster.s.sol (set after deployment)
PAYMASTER_ADDRESS=0x<deployed_paymaster_address>
DEPOSIT_AMOUNT_WEI=100000000000000000   # 0.1 ETH (adjust for testnet vs mainnet)

# 03_TransferOwnership.s.sol (optional, set if transferring ownership)
NEW_OWNER_ADDRESS=0x<new_owner_address>

# VerifyDeploy.s.sol (set after deployment)
FACTORY_ADDRESS=0x<deployed_factory_address>
PAYLINKS_ADDRESS=0x<deployed_paylinks_address>

# 01_Deploy.s.sol (optional) -- override the paylinks USDC token. Defaults to the
# canonical USDC for the target chain (Base mainnet/sepolia) when unset.
# USDC_ADDRESS=0x<usdc_address_for_chain>

# Source verification on Basescan (see "Etherscan (Basescan) Source Verification").
# One Etherscan V2 API key covers both Base mainnet (8453) and Sepolia (84532).
ETHERSCAN_API_KEY=<your_etherscan_v2_api_key>
```

| Variable             | Required By                                                | Description                                                                                                                               |
|----------------------|------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------|
| `BASE_SEPOLIA_RPC`   | All testnet scripts                                        | Infura (or other) RPC URL for Base Sepolia                                                                                                |
| `BASE_MAINNET_RPC`   | All mainnet scripts                                        | Infura (or other) RPC URL for Base mainnet                                                                                                |
| `SPONSOR_ADDRESS`    | `01_Deploy.s.sol`                                          | Public address of the backend's paymaster sponsor key. This is the wallet whose private key the API uses (`MOZAIK_PAYMASTER_SPONSOR_KEY`) |
| `PAYMASTER_ADDRESS`  | `02_FundPaymaster`, `03_TransferOwnership`, `VerifyDeploy` | Address of the deployed paymaster contract (output of step 1)                                                                             |
| `DEPOSIT_AMOUNT_WEI` | `02_FundPaymaster`                                         | ETH to deposit into the EntryPoint on behalf of the paymaster, in wei                                                                     |
| `NEW_OWNER_ADDRESS`  | `03_TransferOwnership`                                     | Address to transfer paymaster ownership to (optional)                                                                                     |
| `FACTORY_ADDRESS`    | `VerifyDeploy`                                             | Address of the deployed factory contract (output of step 1)                                                                               |
| `PAYLINKS_ADDRESS`   | `VerifyDeploy`                                             | Address of the deployed MozaikPaylinks contract (output of step 1)                                                                        |
| `USDC_ADDRESS`       | `01_Deploy` (optional)                                     | Overrides the paylinks USDC token. Defaults to the canonical USDC for the target chain (see chain reference table)                        |
| `ETHERSCAN_API_KEY`  | Source verification (`--verify`, `verify-account-*`)       | Etherscan V2 API key; one key verifies contracts on both Base chains                                                                      |

## Step-by-Step Deployment

All commands below use Base Sepolia. For mainnet, replace `sepolia` with `mainnet` in make targets.

### Step 1: Deploy Factory + Paymaster + Paylinks

The paylinks escrow (`MozaikPaylinks`) is deployed in the same step, bound to the chain's
canonical USDC. Export `USDC_ADDRESS` first only if you need to override that token.

```bash
cd contracts

# Dry-run first (no --broadcast)
make deploy-sepolia

# If the dry-run looks good, broadcast the transaction
# Use --account <keystore_name> for a Foundry keystore, or set PRIVATE_KEY env var
make deploy-sepolia EXTRA="--broadcast --account deployer"
```

The script logs the deployed addresses:

```
EntryPoint:   0x...
AccountImpl:  0x...
Factory:      0x...
Paymaster:    0x...
Sponsor:      0x...
Owner:        0x...
USDC:         0x...
Paylinks:     0x...
```

**Save the Factory, Paymaster, and Paylinks addresses.** You'll need them for the API config (incl.
`MOZAIK_PAYLINKS_ADDR`) and the next steps.

### Step 2: Fund the Paymaster

The paymaster needs an ETH deposit in the EntryPoint to pay for gas on behalf of users.

```bash
# Set the deployed paymaster address and deposit amount
export PAYMASTER_ADDRESS=0x<from_step_1>
export DEPOSIT_AMOUNT_WEI=100000000000000000  # 0.1 ETH for testnet

# Dry-run
make fund-paymaster-sepolia

# Broadcast
make fund-paymaster-sepolia EXTRA="--broadcast --account deployer"
```

**Recommended deposit amounts:**

- Testnet: 0.1 ETH (`100000000000000000` wei) -- enough for extensive testing
- Mainnet: start with 0.01 ETH (`10000000000000000` wei), monitor and top up as needed

### Step 3: Verify Deployment

```bash
export FACTORY_ADDRESS=0x<from_step_1>
export PAYMASTER_ADDRESS=0x<from_step_1>
export PAYLINKS_ADDRESS=0x<from_step_1>

make verify-sepolia
```

This reads on-chain state and confirms:

- Factory and account implementation have code
- Paymaster has code
- Sponsor and owner are non-zero
- EntryPoint deposit exists
- MozaikPaylinks has code and its bound USDC has code

### Step 4 (Optional): Transfer Paymaster Ownership

If you want a different address (e.g., a multisig) to own the paymaster:

```bash
export PAYMASTER_ADDRESS=0x<from_step_1>
export NEW_OWNER_ADDRESS=0x<multisig_or_new_owner>

make transfer-ownership-sepolia EXTRA="--broadcast --account deployer"
```

Ownership uses OpenZeppelin's `Ownable2Step` -- the new owner must call `acceptOwnership()` to finalize.

## Etherscan (Basescan) Source Verification

This is separate from "Step 3: Verify Deployment" above, which only checks
on-chain state. This section publishes the Solidity **source** to Basescan so
anyone viewing a contract address sees verified code and can Read/Write it.

**Why accounts only need to be verified once.** Every user account is an
identical-bytecode `ERC1967Proxy` (only its constructor arguments differ, and
those are not part of runtime bytecode). Basescan's "Similar Match" verifies any
contract whose bytecode matches an already-verified one, so verifying a single
account makes every other account show source automatically. Basescan also
auto-detects the EIP-1967 implementation slot, so once the `MozaikAccount`
implementation is verified, every account exposes its ABI under "Read as Proxy".

Prerequisite: `ETHERSCAN_API_KEY` set in `.env` (see Environment
Variables). One Etherscan V2 key works for both Base chains.

All commands below use Base Sepolia (`--chain 84532`). For mainnet use
`--chain 8453` and the `-mainnet` make target. Mainnet verification, like mainnet
deployment, should only be run with explicit approval.

### Future deploys (automatic)

Pass `--verify` when broadcasting the deploy. Foundry verifies the factory,
paymaster, paylinks, and (normally) the account implementation as it deploys them:

```bash
make deploy-sepolia EXTRA="--broadcast --verify --account deployer"
```

### Already-deployed core contracts (retroactive, once each)

For a stack deployed before verification was wired up, verify each core contract
by address. Factory and implementation take no constructor arguments; paymaster
and paylinks each take one address:

```bash
# Factory (no constructor args)
forge verify-contract <FACTORY> \
  src/account/MozaikAccountFactory.sol:MozaikAccountFactory --chain 84532 --watch

# Account implementation (no constructor args)
forge verify-contract <IMPL> \
  src/account/MozaikAccount.sol:MozaikAccount --chain 84532 --watch

# Paymaster (constructor: sponsor address)
forge verify-contract <PAYMASTER> \
  src/paymaster/MozaikVerifyingPaymaster.sol:MozaikVerifyingPaymaster --chain 84532 \
  --constructor-args $(cast abi-encode "constructor(address)" <SPONSOR>) --watch

# Paylinks (constructor: USDC address)
forge verify-contract <PAYLINKS> \
  src/paylinks/MozaikPaylinks.sol:MozaikPaylinks --chain 84532 \
  --constructor-args $(cast abi-encode "constructor(address)" <USDC>) --watch
```

`<IMPL>` is the factory's `ACCOUNT_IMPLEMENTATION()`; `<SPONSOR>` and `<USDC>` are
the values logged by `01_Deploy` (Step 1).

### Accounts (anchor one, Similar Match covers the rest)

Pick any one deployed account and verify it. Basescan then shows every other
account as a Similar Match automatically:

```bash
ACCOUNT=0x<account> IMPL=0x<impl> SPENDING=0x<spending> RECOVERY=0x<recovery> \
  make verify-account-sepolia
```

`SPENDING` / `RECOVERY` are the account's signer pair (from its `AccountCreated`
event or the app's wallet record).

### When to repeat

- Core contracts: once per deployed address, or automatically via `--verify` on
  future deploys.
- Accounts: once per factory version. A new factory changes the proxy bytecode,
  so re-anchor one account from the new factory to refresh Similar Match.

## Output Summary

After deployment, record these values for the API and mobile configuration:

| Value                  | Used By                                                          | Example                               |
|------------------------|------------------------------------------------------------------|---------------------------------------|
| Factory address        | API (`MOZAIK_ACCOUNT_FACTORY`)                                   | `0xABC...`                            |
| Paymaster address      | API (`MOZAIK_PAYMASTER_ADDRESS`)                                 | `0xDEF...`                            |
| MozaikPaylinks address | API (`MOZAIK_PAYLINKS_ADDR`)                                     | `0x123...`                            |
| Sponsor private key    | API (`MOZAIK_PAYMASTER_SPONSOR_KEY`)                             | 64-char hex, no `0x` prefix           |
| USDC address           | API (`MOZAIK_USDC_ADDRESS`), Mobile (`EXPO_PUBLIC_USDC_ADDRESS`) | See chain reference table above       |
| Chain ID               | API (`MOZAIK_CHAIN_ID`)                                          | `84532` (Sepolia) or `8453` (mainnet) |

## Continuous Integration

Every push to `main` and every pull request touching `contracts/**` runs these required checks (one workflow each under
`.github/workflows/contracts-*.yaml`):

| Check    | Command                        | Gates                                                      |
|----------|--------------------------------|------------------------------------------------------------|
| Test     | `make test` + `make test-fork` | Unit, fuzz, invariant, and Base Sepolia fork tests         |
| Lint     | `forge lint src/ --deny notes` | Solidity lint on production code                           |
| Echidna  | `make echidna`                 | Property-based fuzzing (paymaster, account, paylinks)      |
| E2E      | `make test-e2e`                | Full lifecycle against a local anvil node                  |
| Slither  | `make slither`                 | Static analysis; fails on new High-severity findings       |
| Coverage | `make coverage-check`          | `src/` line coverage must stay at or above the floor (99%) |

Mutation testing (`make mutate`) runs on a **weekly schedule and on demand only** (`contracts-mutation.yaml`), never as
a PR gate. It reruns the suite once per generated mutant, so it is slow; surviving (uncaught) mutants are uploaded as an
artifact for review rather than blocking merges. Because `slither-mutate` rewrites `src/` in place, `make mutate` runs the
campaign inside a throwaway `git worktree` at HEAD, so an interrupted run can never leave a mutant in the working tree.

### Static analysis (Slither)

`make slither` runs `slither src/ --fail-high` (`lib/` is excluded via `slither.config.json`). The gate blocks only
**High**-severity findings; the full report is still printed to the CI log for reviewers. The current output is 12
results, all reviewed and accepted as benign:

| Detector            | Severity | Count | Why it is safe                                                                                                                                                                           |
|---------------------|----------|-------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `unused-return`     | Medium   | 5     | `ECDSA.tryRecover` returns `(address, RecoverError, bytes32)`; call sites bind the address and error and check the error, intentionally ignoring the third element (the error argument). |
| `timestamp`         | Low      | 3     | `MozaikPaylinks` compares `block.timestamp` for payment-link expiry over day/week windows where validator drift is irrelevant and there is no EVM alternative.                           |
| `assembly`          | Info     | 1     | `MozaikAccount` uses inline assembly only for its ERC-7201 namespaced storage slot (standard pattern).                                                                                   |
| `naming-convention` | Info     | 3     | `ACCOUNT_IMPLEMENTATION`, `SENDER_CREATOR`, and `USDC` are `immutable`/`constant`, conventionally `SCREAMING_SNAKE_CASE`.                                                                |

Slither also prints IR-generation errors for OpenZeppelin's `EIP712` constructor (`_EIP712Name` / `_EIP712Version`);
these are a limitation of Slither parsing OZ's `ShortStrings` assembly, affect only `lib/` code, and do not change the
exit code. Because every finding tops out at Medium and is reviewed-benign, `--fail-high` keeps the gate low-noise while
still blocking the severity that maps to a must-fix issue. Re-run `make slither` locally after changing `src/` and
review any new finding before merging.

### Coverage

`make coverage-check` regenerates `lcov.info` (`forge coverage`, excluding fork and e2e tests) and fails if `src/` line
coverage drops below `COVERAGE_MIN` (99%, set in the `Makefile`). `no_match_coverage` in `foundry.toml` keeps the report
scoped to production code (tests, scripts, `lib`, e2e, and mocks are excluded).

Current coverage is 99.47% (189/190 lines). The single uncovered line is the `MozaikVerifyingPaymaster` constructor's
`BasePaymaster(...)` base-initializer line: the constructor provably runs (its body lines are covered), but
`forge coverage` does not attribute a hit to the base-initializer line. This is a coverage-instrumentation artifact, not
a missing test, so 100% is not reachable and the floor sits just below.
