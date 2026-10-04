# Security Policy

MozaikPay smart contracts custody and move real value (USDC escrow, ERC-4337 smart accounts, and a gas-sponsoring
paymaster on Base, and per-account USDC deposit forwarders on every supported CCTP V2 chain). We take security seriously
and appreciate the work of researchers who help keep users' funds safe.
This document explains what is in scope, how to report a vulnerability privately, and what to expect from us in return.

## Reporting a Vulnerability

**Please do not open a public issue, pull request, or discussion for a security vulnerability.** Public disclosure
before a fix is deployed puts user funds at risk.

Report privately through **GitHub's private vulnerability reporting**:

1. Go to the [**Security** tab](https://github.com/sig-0/mozaikpay-contracts/security)
   of this repository.
2. Click **Report a vulnerability** to open a private advisory visible only to you and the maintainers.

If you cannot use GitHub private reporting for any reason, contact the maintainer listed in [
`.github/CODEOWNERS`](.github/CODEOWNERS) and request a secure channel before sharing any details.

### What to include

A good report lets us reproduce and assess impact quickly. Please include:

- **Affected contract (s)** and the version/commit (Git commit hash or deployed address and chain).
- **A description of the vulnerability** and the security property it breaks.
- **Impact**: what an attacker can achieve (e.g. steal escrowed USDC, drain the paymaster deposit, take over an account,
  bypass a signature check).
- **A proof of concept** where possible, a Foundry test (`forge test`), a transaction trace, or step-by-step
  reproduction. PoCs against a local fork or Base **Sepolia** are strongly preferred over mainnet (see Safe Harbor).
- **Suggested remediation**, if you have one.

We can review reports in English.

## Scope

### In scope

The production Solidity in this repository (`src/`) and the contracts deployed from it:

| Contract                     | Path                                         | Role                                                         |
|------------------------------|----------------------------------------------|--------------------------------------------------------------|
| `MozaikAccount`              | `src/account/MozaikAccount.sol`              | ERC-4337 smart account (proxy implementation)                |
| `MozaikAccountFactory`       | `src/account/MozaikAccountFactory.sol`       | CREATE2 factory for accounts                                 |
| `MozaikVerifyingPaymaster`   | `src/paymaster/MozaikVerifyingPaymaster.sol` | Gas sponsorship for UserOperations                           |
| `MozaikPaylinks`             | `src/paylinks/MozaikPaylinks.sol`            | Non-upgradeable USDC escrow for payment links                |
| `MozaikCCTPForwarder`        | `src/cctp/MozaikCCTPForwarder.sol`           | Per-account CCTP V2 deposit forwarder (clone implementation) |
| `MozaikCCTPForwarderFactory` | `src/cctp/MozaikCCTPForwarderFactory.sol`    | Deterministic factory for forwarder clones                   |

**Networks:** Base Mainnet (chain ID `8453`) and Base Sepolia (chain ID
`84532`). The CCTP forwarder contracts also run on Ethereum (`1`), Arbitrum One (`42161`) and Polygon PoS (`137`),
and on Sepolia (`11155111`), Arbitrum Sepolia (`421614`) and Polygon Amoy (`80002`). They have the same addresses on
every chain of one environment, recorded in `script/cctp/forwarder-v1.json` and
`script/cctp/forwarder-v1-sepolia.json`. The canonical deployment addresses are published in the project's deployment
records; verify any address
against those before reporting.

Examples of in-scope issues:

- Theft, freezing, or loss of escrowed USDC (`MozaikPaylinks` create / claim / reclaim flows, EIP-712 claim-signature
  handling, expiry logic).
- Unauthorized access to or takeover of a `MozaikAccount` (signature validation, spending/recovery signer logic, upgrade
  authorization, storage collision).
- Draining or griefing the paymaster's EntryPoint deposit, or bypassing sponsor approval in `MozaikVerifyingPaymaster`.
- Factory issues that let an attacker deploy a malicious or hijackable account at a victim's counterfactual address.
- Any path that moves value out of a `MozaikCCTPForwarder` other than a CCTP burn with its account as the mint
  recipient, a transfer to its account on Base, or a rescue that its account authorized. Also any way to deploy
  other code at a forwarder's address.
- Broken access control, replay, or signature-malleability affecting any of the above.

### Out of scope

- **Dependencies under `lib/`**: OpenZeppelin, `account-abstraction`
  (EntryPoint v0.9), etc. Report those upstream. (In-scope if we use them in an unsafe or incorrect way.)
- **The canonical EntryPoint and USDC contracts**: these are external, already audited, and not under our control.
- **Off-chain and operational infrastructure**: the backend API, the paymaster sponsor hot-wallet key management, RPC
  providers, and the mobile app. These live in other repositories.
- **Findings already documented as reviewed-benign**: see the accepted Slither results table in
  the [README](README.md#static-analysis-slither) (e.g. the
  `unused-return` on `ECDSA.tryRecover`, `block.timestamp` use for paylink expiry). If you believe one of these is
  actually exploitable, we want to hear it. Include a concrete exploit path.
- **Testnet-only issues** with no mainnet impact, gas-optimization suggestions, and best-practice/style recommendations
  without a demonstrated security impact.
- Automated scanner output submitted without analysis or a plausible exploit.

## Supported Versions

The security-supported code is:

- The **`main`** branch of this repository, and
- The contracts **currently deployed** on Base Mainnet at the canonical addresses in our deployment records.

`MozaikPaylinks` is non-upgradeable and immutable once deployed; a fix there means deploying a new instance and
migrating. `MozaikCCTPForwarder` and its factory are immutable per version; a fix ships as a new version at new
addresses, and funds already at an older forwarder leave only through that version's own paths. `MozaikAccount` is a
UUPS-style proxy implementation. Because on-chain contracts cannot be silently patched,
remediation for a live issue may involve pausing intake, deploying replacement contracts, and/or migrating funds,
coordinated with you under embargo.

## Our Commitment / Response Process

When you report through GitHub private reporting, you can expect:

| Stage                                                        | Target                                                |
|--------------------------------------------------------------|-------------------------------------------------------|
| **Acknowledgement** of your report                           | within **3 business days**                            |
| **Initial assessment** (severity + whether we can reproduce) | within **7 business days**                            |
| **Status updates** while we work a confirmed issue           | at least every **7 days**                             |
| **Fix / mitigation** for confirmed Critical & High issues    | as quickly as practical, prioritized above other work |

We will keep you informed through the advisory, credit you in the published advisory unless you prefer to remain
anonymous, and coordinate public disclosure timing with you.

## Severity

We assess severity by realistic impact on funds and users, roughly:

- **Critical**: direct theft or permanent loss/freezing of user funds or the paymaster deposit; account takeover;
  unauthorized draining of escrow.
- **High**: theft/loss under specific but attainable conditions; griefing that locks funds; signature or access-control
  bypass with meaningful impact.
- **Medium**: limited-value loss, or an exploit requiring unlikely preconditions or privileged missteps.
- **Low**: minimal impact, or issues that are defense-in-depth improvements.

## Coordinated Disclosure

We follow coordinated disclosure. Please give us a reasonable window to investigate and remediate before any public
disclosure. **90 days** from the acknowledgement is our default, but for a live, actively-exploitable issue that
threatens funds we may ask for an extension while a fix or migration is rolled out. We will publish a GitHub Security
Advisory once a fix is deployed and agree disclosure timing with you.

## Safe Harbor

We will not pursue or support legal action against researchers who, in good faith:

- Report vulnerabilities through the private channel above and give us reasonable time to respond before disclosure;
- Make a good-faith effort to avoid privacy violations, data destruction, and interruption or degradation of our
  services;
- Test against **local forks or Base Sepolia**, not against mainnet user funds, and do **not** exploit an issue beyond
  the minimum needed to demonstrate it;
- Do not access, modify, or exfiltrate data that is not their own.

If in doubt about whether an action is authorized, contact us and ask first.

## Rewards

We do not currently run a formal bug bounty program. Rewards may be offered at the maintainers' discretion for
high-impact reports, and we will publicly credit researchers (with your consent) in the resulting advisory. We genuinely
appreciate responsible disclosure and the time you invest.

## Security Posture

For context on the assurances already in place, the codebase is continuously tested with Foundry unit/fuzz/invariant and
Base Sepolia fork tests, Echidna property fuzzing, Slither static analysis (High-severity gate), mutation testing, and a
≥99% coverage floor. See the
[Continuous Integration](README.md#continuous-integration) section of the README. These reduce, but do not eliminate,
risk; independent findings are always welcome.

---

Thank you for helping keep MozaikPay users safe.
