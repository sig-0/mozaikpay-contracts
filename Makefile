# Forge build commands

.PHONY: build
build:
	forge build

.PHONY: clean
clean:
	forge clean

.PHONY: lint
lint:
	forge lint src/ --deny notes

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
	forge test --no-match-test "Fork\|fork"

# Runs integration tests.
# Requires BASE_SEPOLIA_RPC in the env to be set
.PHONY: test-fork
test-fork:
	forge test --match-test "Fork\|fork"

# Runs invariant tests only
.PHONY: test-invariant
test-invariant:
	forge test --match-contract "Invariant"

# Runs the full testing suite.
# RPC-required tests are skipped unless the env is set
.PHONY: test-all
test-all:
	forge test

# Verbose output for a specific test or pattern
# Usage: make test-match PATTERN=test_Execute
.PHONY: test-match
test-match:
	forge test --match-test "$(PATTERN)" -vvv

.PHONY: coverage
coverage:
	forge coverage --no-match-test "Fork\|fork"

.PHONY: snapshot
snapshot:
	forge snapshot --no-match-test "Fork\|fork"

# Static analysis

.PHONY: slither
slither:
	slither src/ --filter-paths "lib/"

# Echidna suite
# https://github.com/crytic/echidna

.PHONY: echidna
echidna: echidna-paymaster echidna-account

.PHONY: echidna-paymaster
echidna-paymaster:
	echidna test/echidna/PaymasterEchidna.sol --contract PaymasterEchidna --config echidna.yaml

.PHONY: echidna-account
echidna-account:
	echidna test/echidna/AccountEchidna.sol --contract AccountEchidna --config echidna.yaml

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

# Deployment commands.
# add --broadcast to send (it's a dry-run by default)
.PHONY: deploy-sepolia
deploy-sepolia:
	forge script script/01_Deploy.s.sol \
		--rpc-url base_sepolia \
		--account deployer \
		$(EXTRA)

.PHONY: fund-paymaster-sepolia
fund-paymaster-sepolia:
	forge script script/02_FundPaymaster.s.sol \
		--rpc-url base_sepolia \
		--account deployer \
		$(EXTRA)

.PHONY: transfer-ownership-sepolia
transfer-ownership-sepolia:
	forge script script/03_TransferOwnership.s.sol \
		--rpc-url base_sepolia \
		--account deployer \
		$(EXTRA)
