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

# Runs fork integration tests. Paylinks and account flows fork Base Sepolia
# (BASE_SEPOLIA_RPC, defaults to https://sepolia.base.org); the ENS resolver forks
# Ethereum mainnet (ETH_MAINNET_RPC) and is skipped when that variable is unset.
# The CCTP forwarder forks Ethereum, Arbitrum, Polygon, Base and Base Sepolia, through
# public RPCs unless ETH_MAINNET_RPC, ARBITRUM_MAINNET_RPC or POLYGON_MAINNET_RPC is set.
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

# Minimum src/ line coverage enforced by coverage-check (CI gate).
COVERAGE_MIN ?= 99

.PHONY: coverage
coverage:
	forge coverage --no-match-test "Fork\|fork" --no-match-path "e2e/*" --report summary --report lcov

# Regenerates coverage and fails if src/ line coverage drops below COVERAGE_MIN.
# lcov.info holds only src/ files (no_match_coverage excludes test/script/lib/e2e/mocks).
.PHONY: coverage-check
coverage-check: coverage
	@awk -F: '/^LF:/{f+=$$2} /^LH:/{h+=$$2} END{ if (f==0) { print "no coverage data in lcov.info"; exit 1 } pct=100*h/f; printf "src/ line coverage: %.2f%% (%d/%d), floor %d%%\n", pct, h, f, $(COVERAGE_MIN); if (pct+1e-9 < $(COVERAGE_MIN)) { print "FAIL: coverage below floor"; exit 1 } print "coverage OK" }' lcov.info

.PHONY: snapshot
snapshot:
	forge snapshot --no-match-test "Fork\|fork" --no-match-path "e2e/*"

# Static analysis

.PHONY: slither
slither:
	slither src/ --fail-high

# Mutation testing (Trail of Bits slither-mutate). Slow: reruns the test suite
# once per generated mutant. Informational only. Surfaces surviving (uncaught)
# mutants under mutation_campaign/ for review. Reduced fuzz runs keep it
# tractable; re-check any survivor with full fuzz before treating it as a gap.
#
# slither-mutate rewrites src/ in place and restores it after each mutant, so an
# interrupted run can leave a mutant behind. To keep the working tree pristine no
# matter how the run ends, the campaign executes inside a throwaway git worktree
# checked out at HEAD, with its own private copy of lib/ (never the real one, so a
# run can never write through to the vendored deps). The report is written back to
# ./mutation_campaign, which each run replaces. Uncommitted changes are not mutated.
# The golden test compares src/cctp with its frozen bytecode records, so it would kill every CCTP
# mutant on its own; it is excluded here.
MUTATE_TEST_CMD ?= FOUNDRY_FUZZ_RUNS=1000 forge test --no-match-contract "UserOpFlow|Fork|Golden" --no-match-path "e2e/*"

.PHONY: mutate
mutate:
	@set -e; \
	root="$$(pwd)"; \
	tmp="$$(mktemp -d)"; \
	wt="$$tmp/wt"; \
	trap 'cd "$$root"; git worktree remove --force "$$wt" >/dev/null 2>&1; rm -rf "$$tmp"; git worktree prune' EXIT; \
	trap 'exit 130' INT; \
	trap 'exit 143' TERM; \
	git worktree add --detach --quiet "$$wt" HEAD; \
	rm -rf "$$wt/lib"; \
	cp -R "$$root/lib" "$$wt/lib"; \
	rm -rf "$$root/mutation_campaign"; \
	cd "$$wt"; \
	slither-mutate src/ --test-cmd '$(MUTATE_TEST_CMD)' --timeout 300 --output-dir "$$root/mutation_campaign"

# Echidna suite
# https://github.com/crytic/echidna

.PHONY: echidna
echidna: echidna-paymaster echidna-account echidna-paylinks echidna-cctp

.PHONY: echidna-paymaster
echidna-paymaster:
	echidna test/echidna/PaymasterEchidna.sol --contract PaymasterEchidna --config echidna-paymaster.yaml

.PHONY: echidna-account
echidna-account:
	echidna test/echidna/AccountEchidna.sol --contract AccountEchidna --config echidna-account.yaml

.PHONY: echidna-paylinks
echidna-paylinks:
	echidna test/echidna/PaylinksEchidna.sol --contract PaylinksEchidna --config echidna-paylinks.yaml

.PHONY: echidna-cctp
echidna-cctp:
	echidna test/echidna/CCTPEchidna.sol --contract CCTPEchidna --config echidna-cctp.yaml

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

# ENS L1 resolver (Ethereum L1, not Base)
# Add --broadcast to send (dry-run by default).
# Requires ENS_GATEWAY_URL, ENS_SIGNER_ADDRESSES, ENS_RESOLVER_OWNER,
# ENS_ROOT_RESOLVER, and ENS_PARENT_NAME in the env. Add --verify to EXTRA
# to verify on Etherscan in the same run. The owner can later change the
# URL, the signers, and the root resolver without a redeploy.

.PHONY: deploy-resolver-sepolia
deploy-resolver-sepolia:
	forge script script/04_DeployMozaikL1Resolver.s.sol \
		--rpc-url sepolia \
		$(EXTRA)

.PHONY: deploy-resolver-mainnet
deploy-resolver-mainnet:
	forge script script/04_DeployMozaikL1Resolver.s.sol \
		--rpc-url ethereum \
		$(EXTRA)

# Etherscan source verification for a resolver deployed without --verify.
# Constructor args are read from the creation transaction. Requires RESOLVER.

.PHONY: verify-resolver-sepolia
verify-resolver-sepolia:
	forge verify-contract $(RESOLVER) src/ens/MozaikL1Resolver.sol:MozaikL1Resolver \
		--chain 11155111 \
		--guess-constructor-args \
		--watch

.PHONY: verify-resolver-mainnet
verify-resolver-mainnet:
	forge verify-contract $(RESOLVER) src/ens/MozaikL1Resolver.sol:MozaikL1Resolver \
		--chain 1 \
		--guess-constructor-args \
		--watch

# CCTP forwarder (every EVM chain with CCTP V2)
# Deploys a frozen record through Nick's deployer, so the implementation, the factory and every forwarder
# have the same addresses on every chain of one environment. RECORD picks the record: mainnet
# (script/cctp/forwarder-v1.json) or sepolia (script/cctp/forwarder-v1-sepolia.json). NETWORK is an rpc_endpoints name from foundry.toml
# (sepolia, arbitrum_sepolia, amoy, base_sepolia, ethereum, arbitrum, polygon, base_mainnet).
# Add --broadcast to EXTRA to send (dry-run by default). The broadcaster is any funded wallet, set with the
# --account keystore flag or PRIVATE_KEY.
CCTP_FORWARDER_RECORD = script/cctp/forwarder-v1$(if $(filter sepolia,$(RECORD)),-sepolia).json
export CCTP_FORWARDER_RECORD

.PHONY: deploy-forwarder
deploy-forwarder:
	@$(if $(filter mainnet sepolia,$(RECORD)),,$(error RECORD=mainnet|sepolia is required))
	forge script script/05_DeployCCTPForwarder.s.sol \
		--rpc-url $(NETWORK) \
		$(EXTRA)

# Rebuilds both records from the current source: init code, addresses, code hashes and golden forwarders.
# Only for a version that is not deployed yet, because any source change moves every address. Afterwards,
# update the addresses pinned in test/cctp/MozaikCCTPForwarderGolden.t.sol.
.PHONY: forwarder-records
forwarder-records:
	@set -e; for record in script/cctp/forwarder-v1.json script/cctp/forwarder-v1-sepolia.json; do \
		FOUNDRY_PROFILE=record CCTP_FORWARDER_RECORD=$$record forge script script/cctp/GenerateForwarderRecord.s.sol; \
		[ -z "$$(tail -c1 $$record)" ] || echo >> $$record; \
	done

# Checks the deployed code hashes, the golden forwarder and Circle's contracts on NETWORK.
.PHONY: verify-forwarder
verify-forwarder:
	@$(if $(filter mainnet sepolia,$(RECORD)),,$(error RECORD=mainnet|sepolia is required))
	forge script script/VerifyDeployForwarder.s.sol \
		--rpc-url $(NETWORK)

# Etherscan source verification for the forwarder implementation and factory on NETWORK.
# Requires ETHERSCAN_API_KEY and jq.
.PHONY: verify-forwarder-source
verify-forwarder-source:
	@$(if $(filter mainnet sepolia,$(RECORD)),,$(error RECORD=mainnet|sepolia is required))
	forge verify-contract $$(jq -r .implementation.address $(CCTP_FORWARDER_RECORD)) \
		src/cctp/MozaikCCTPForwarder.sol:MozaikCCTPForwarder \
		--rpc-url $(NETWORK) \
		--constructor-args $$(cast abi-encode "constructor(address,address,uint256)" \
			$$(jq -r .config.tokenMessenger $(CCTP_FORWARDER_RECORD)) \
			$$(jq -r .config.baseUsdc $(CCTP_FORWARDER_RECORD)) \
			$$(jq -r .config.baseChainId $(CCTP_FORWARDER_RECORD))) \
		--watch
	forge verify-contract $$(jq -r .factory.address $(CCTP_FORWARDER_RECORD)) \
		src/cctp/MozaikCCTPForwarderFactory.sol:MozaikCCTPForwarderFactory \
		--rpc-url $(NETWORK) \
		--constructor-args $$(cast abi-encode "constructor(address)" $$(jq -r .implementation.address $(CCTP_FORWARDER_RECORD))) \
		--watch

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
