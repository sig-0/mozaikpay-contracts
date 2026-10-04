# MozaikPay Contracts

This document covers deploying the MozaikPay smart contracts to Base Sepolia (testnet) and Base mainnet.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed (`forge`, `cast`)
- A deployer wallet with ETH on the target chain (for gas)
- A sponsor wallet (hot wallet) whose private key signs paymaster approvals
- An RPC endpoint for the target chain. The Makefile defaults to the public Base endpoints (`https://sepolia.base.org`,
  `https://mainnet.base.org`); set `BASE_SEPOLIA_RPC` /
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

Each environment deploys four contracts on Base, one on Ethereum L1, and the CCTP forwarder and its factory on Base
and every chain that accepts USDC deposits:

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
5. **MozaikL1Resolver** (Ethereum, `src/ens/`) -- ENS resolver for `mozaikpay.eth`. Subnames resolve through a
   CCIP-read gateway; the resolver only checks the gateway's signature. Vendored
   from [Basenames](https://github.com/base-org/basenames).
6. **MozaikCCTPForwarder** (EVM chains with CCTP V2 and Cancun, `src/cctp/`) -- Per-account deposit address. Each
   account gets an ERC-1167 clone whose only immutable argument is its Base account. Anyone can call `forward`, which
   moves the requested amount or the whole balance, whichever is less. On Base, it transfers USDC to the account. On
   other chains, it burns USDC through CCTP V2 with the account as the mint recipient on Base, no destination caller and
   no hook, with `maxFee` lowered to 20 bps when above it. Only the account can move other tokens out: with a finalized
   CCTP message from Base, or with a direct `rescue` call on Base. The message body is `abi.encode(token, to, amount,
   deadline)`, and the forwarder refuses it after `deadline` (a timestamp in seconds), so a message whose delivery
   failed cannot be replayed later. Until then anyone can relay it, so send rescue messages with a short deadline and
   the relayer as destination caller. No owner, no storage, no upgrade path. The constructor takes Circle's
   TokenMessengerV2, the Base USDC and the Base chain id.
7. **MozaikCCTPForwarderFactory** -- Deploys forwarder clones at deterministic addresses (`predict`, `deploy`,
   `deployAndForward`). Both contracts deploy through Nick's deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`), so
   the implementation, the factory and every forwarder have the same address on every chain of one environment.
