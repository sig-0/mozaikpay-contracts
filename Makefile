# Default RPC endpoints for Base Sepolia and Base mainnet.
# Override by exporting BASE_SEPOLIA_RPC / BASE_MAINNET_RPC in the shell
BASE_SEPOLIA_RPC ?= https://sepolia.base.org
BASE_MAINNET_RPC ?= https://mainnet.base.org
export BASE_SEPOLIA_RPC
export BASE_MAINNET_RPC

# Forge build commands

.PHONY: build
build:
	forge build

.PHONY: clean
clean:
	forge clean

.PHONY: lint
lint:
	forge lint src/ --deny notes --force

.PHONY: format
format:
	forge fmt

.PHONY: remappings
remappings:
	forge remappings > remappings.txt

# Forge test commands

# Runs unit / fuzz / invariant tests without the RPC
.PHONY: test
test:
	forge test --no-match-contract "UserOpFlow|Fork" --no-match-path "e2e/*"

# Runs fork integration tests against Base Sepolia.
# Uses BASE_SEPOLIA_RPC (defaults to https://sepolia.base.org).
.PHONY: test-fork
test-fork:
	forge test --match-contract "UserOpFlow|Fork"

# Runs invariant tests only
.PHONY: test-invariant
test-invariant:
	forge test --match-contract "Invariant"

# Runs the full testing suite.
# RPC-required tests are skipped unless the env is set
.PHONY: test-all
test-all:
	forge test --no-match-path "e2e/*"

# E2E lifecycle test against a local anvil node
.PHONY: test-e2e
test-e2e:
	./e2e/run.sh

# Verbose output for a specific test or pattern
# Usage: make test-match PATTERN=test_Execute
.PHONY: test-match
test-match:
	forge test --match-test "$(PATTERN)" -vvv

.PHONY: coverage
coverage:
	forge coverage --no-match-test "Fork\|fork" --no-match-path "e2e/*"

.PHONY: snapshot
snapshot:
	forge snapshot --no-match-test "Fork\|fork" --no-match-path "e2e/*"

# Static analysis

.PHONY: slither
slither:
	slither src/

# Echidna suite
# https://github.com/crytic/echidna

.PHONY: echidna
echidna: echidna-paymaster echidna-account echidna-paylinks

.PHONY: echidna-paymaster
echidna-paymaster:
	echidna test/echidna/PaymasterEchidna.sol --contract PaymasterEchidna --config echidna-paymaster.yaml

.PHONY: echidna-account
echidna-account:
	echidna test/echidna/AccountEchidna.sol --contract AccountEchidna --config echidna.yaml

.PHONY: echidna-paylinks
echidna-paylinks:
	echidna test/echidna/PaylinksEchidna.sol --contract PaylinksEchidna --config echidna.yaml

# Local node (Anvil)

# Plain local node (no fork) — useful for manual cast interactions
.PHONY: anvil
anvil:
	anvil

# Fork of Base Sepolia, serves at localhost:8545
.PHONY: anvil-fork
anvil-fork:
	anvil --fork-url "$(BASE_SEPOLIA_RPC)"

# Fork of Base mainnet, serves at localhost:8545
.PHONY: anvil-fork-mainnet
anvil-fork-mainnet:
	anvil --fork-url "$(BASE_MAINNET_RPC)"

# Deployment (factory + paymaster + paylinks)
# Add --broadcast to send (dry-run by default).
# Requires SPONSOR_ADDRESS in the env. The paylinks token defaults to the canonical
# USDC for the target chain (Base mainnet/sepolia); export USDC_ADDRESS to override.
# The broadcaster is determined by the --account keystore flag or PRIVATE_KEY.

.PHONY: deploy-sepolia
deploy-sepolia:
	forge script script/01_Deploy.s.sol \
		--rpc-url base_sepolia \
		$(EXTRA)

.PHONY: deploy-mainnet
deploy-mainnet:
	forge script script/01_Deploy.s.sol \
		--rpc-url base_mainnet \
		$(EXTRA)

# Funding
# Requires PAYMASTER_ADDRESS and DEPOSIT_AMOUNT_WEI in the env.

.PHONY: fund-paymaster-sepolia
fund-paymaster-sepolia:
	forge script script/02_FundPaymaster.s.sol \
		--rpc-url base_sepolia \
		$(EXTRA)

.PHONY: fund-paymaster-mainnet
fund-paymaster-mainnet:
	forge script script/02_FundPaymaster.s.sol \
		--rpc-url base_mainnet \
		$(EXTRA)

# Ownership transfer
# Requires PAYMASTER_ADDRESS and NEW_OWNER_ADDRESS in the env.

.PHONY: transfer-ownership-sepolia
transfer-ownership-sepolia:
	forge script script/03_TransferOwnership.s.sol \
		--rpc-url base_sepolia \
		$(EXTRA)

.PHONY: transfer-ownership-mainnet
transfer-ownership-mainnet:
	forge script script/03_TransferOwnership.s.sol \
		--rpc-url base_mainnet \
		$(EXTRA)

# Dev: fund a wallet with mock USDC (transfers from pre-funded deployer)
# Requires TO and AMOUNT (in whole USDC, e.g. 1000) in the env.
# Uses Anvil account #0 as the sender.
#
# Usage: TO=0x... AMOUNT=1000 make dev-fund

ANVIL_DEPLOYER_KEY := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

.PHONY: dev-fund
dev-fund:
	forge script script/DevFundUSDC.s.sol \
		--rpc-url http://localhost:8545 \
		--private-key $(ANVIL_DEPLOYER_KEY) \
		--broadcast

# Post-deploy verification
# Requires FACTORY_ADDRESS, PAYMASTER_ADDRESS, and PAYLINKS_ADDRESS in the env.

.PHONY: verify-sepolia
verify-sepolia:
	forge script script/VerifyDeploy.s.sol \
		--rpc-url base_sepolia

.PHONY: verify-mainnet
verify-mainnet:
	forge script script/VerifyDeploy.s.sol \
		--rpc-url base_mainnet

# Basescan source verification for a single deployed account proxy. Basescan
# then shows every account with matching bytecode via Similar Match, so this
# runs once per factory version, not once per account.
# Requires ACCOUNT, IMPL, SPENDING, and RECOVERY in the env.

.PHONY: verify-account-sepolia
verify-account-sepolia:
	forge verify-contract $(ACCOUNT) \
		lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
		--chain 84532 \
		--constructor-args $$(cast abi-encode "constructor(address,bytes)" $(IMPL) $$(cast calldata "initialize(address,address)" $(SPENDING) $(RECOVERY))) \
		--watch

.PHONY: verify-account-mainnet
verify-account-mainnet:
	forge verify-contract $(ACCOUNT) \
		lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
		--chain 8453 \
		--constructor-args $$(cast abi-encode "constructor(address,bytes)" $(IMPL) $$(cast calldata "initialize(address,address)" $(SPENDING) $(RECOVERY))) \
		--watch
