# MozaikPay Contracts

This document covers deploying the MozaikPay smart contracts to Base Sepolia (testnet) and Base mainnet.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed (`forge`, `cast`)
- A deployer wallet with ETH on the target chain (for gas)
- A sponsor wallet (hot wallet) whose private key the API will use to sign paymaster approvals
- An Infura (or other) RPC endpoint for the target chain

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
4. **MozaikLinks** -- Non-upgradeable USDC escrow for payment links. Deployed by `01_Deploy.s.sol` alongside the account/paymaster stack, bound to the chain's USDC.
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
| `PAYLINKS_ADDRESS`   | `VerifyDeploy`                                             | Address of the deployed MozaikLinks contract (output of step 1)                                                                           |
| `USDC_ADDRESS`       | `01_Deploy` (optional)                                     | Overrides the paylinks USDC token. Defaults to the canonical USDC for the target chain (see chain reference table)                        |

## Step-by-Step Deployment

All commands below use Base Sepolia. For mainnet, replace `sepolia` with `mainnet` in make targets.

### Step 1: Deploy Factory + Paymaster + Paylinks

The paylinks escrow (`MozaikLinks`) is deployed in the same step, bound to the chain's
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
Factory:      0x...
AccountImpl:  0x...
Paymaster:    0x...
Sponsor:      0x...
Owner:        0x...
USDC:         0x...
Paylinks:     0x...
```

**Save the Factory, Paymaster, and Paylinks addresses.** You'll need them for the API config (incl. `MOZAIK_PAYLINKS_ADDR`) and the next steps.

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
- MozaikLinks has code and its bound USDC has code

### Step 5 (Optional): Transfer Paymaster Ownership

If you want a different address (e.g., a multisig) to own the paymaster:

```bash
export PAYMASTER_ADDRESS=0x<from_step_1>
export NEW_OWNER_ADDRESS=0x<multisig_or_new_owner>

make transfer-ownership-sepolia EXTRA="--broadcast --account deployer"
```

Ownership uses OpenZeppelin's `Ownable2Step` -- the new owner must call `acceptOwnership()` to finalize.

## Output Summary

After deployment, record these values for the API and mobile configuration:

| Value               | Used By                                                          | Example                               |
|---------------------|------------------------------------------------------------------|---------------------------------------|
| Factory address     | API (`MOZAIK_ACCOUNT_FACTORY`)                                   | `0xABC...`                            |
| Paymaster address   | API (`MOZAIK_PAYMASTER_ADDRESS`)                                 | `0xDEF...`                            |
| MozaikLinks address | API (`MOZAIK_PAYLINKS_ADDR`)                                     | `0x123...`                            |
| Sponsor private key | API (`MOZAIK_PAYMASTER_SPONSOR_KEY`)                             | 64-char hex, no `0x` prefix           |
| USDC address        | API (`MOZAIK_USDC_ADDRESS`), Mobile (`EXPO_PUBLIC_USDC_ADDRESS`) | See chain reference table above       |
| Chain ID            | API (`MOZAIK_CHAIN_ID`)                                          | `84532` (Sepolia) or `8453` (mainnet) |
