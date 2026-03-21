#!/bin/sh
set -e

RPC="http://localhost:8545"
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

# Anvil account #2 - used as the paymaster sponsor signer.
SPONSOR_ADDRESS="0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"

# Canonical addresses - match production on Base mainnet.
CANONICAL_EP="0x433709009B8330FDa32311DF1C2AFA402eD8D009"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# === Deploy EntryPoint v0.9 via deterministic CREATE2 proxy ===
# Reproduces the canonical deployment used on all production chains:
# https://github.com/eth-infinitism/account-abstraction/blob/develop/deploy/1_deploy_entrypoint.ts
#
# Anvil ships with the Arachnid deterministic deployment proxy pre-deployed at
# 0x4e59b44847b379578588920cA78FbF26c0B4956C. We send the canonical salt +
# initcode to it, which runs the EntryPoint constructor (including SenderCreator
# creation) and produces the same address used on all production chains.

echo "Deploying EntryPoint v0.9..."

# Arachnid's deterministic deployment proxy (pre-deployed by anvil).
CREATE2_PROXY="0x4e59b44847b379578588920cA78FbF26c0B4956C"

# Salt from the account-abstraction repo.
EP_SALT="7702864008ddeab30aa67b7adc3d2653bc8d162714b1fe8fe4582df814f3bf61"
EP_INITCODE=$(cat "$SCRIPT_DIR/testdata/entrypoint_v09_initcode.hex")

cast send "$CREATE2_PROXY" "0x${EP_SALT}${EP_INITCODE}" \
  --gas-limit 6000000 \
  --rpc-url $RPC \
  --private-key $DEPLOYER_KEY > /dev/null

# Verify canonical address and SenderCreator
EP_CODE=$(cast code "$CANONICAL_EP" --rpc-url $RPC)
if [ "$EP_CODE" = "0x" ]; then
  echo "ERROR: EntryPoint not deployed at $CANONICAL_EP"
  exit 1
fi

SENDER_CREATOR=$(cast call "$CANONICAL_EP" "senderCreator()(address)" --rpc-url $RPC)
SC_CODE=$(cast code "$SENDER_CREATOR" --rpc-url $RPC)
if [ "$SC_CODE" = "0x" ]; then
  echo "ERROR: SenderCreator not deployed at $SENDER_CREATOR"
  exit 1
fi

echo "  EntryPoint deployed at $CANONICAL_EP"
echo "  SenderCreator deployed at $SENDER_CREATOR"

# === Deploy Base L1 gas oracle mock ===
L1_GAS_ORACLE="0x420000000000000000000000000000000000000F"
cast rpc anvil_setCode "$L1_GAS_ORACLE" '"0x60206000f3"' --rpc-url $RPC > /dev/null
echo "L1 gas oracle mock deployed at $L1_GAS_ORACLE"

# === Deploy Mozaik contracts ===
echo "Deploying contracts..."
OUTPUT=$(SPONSOR_ADDRESS=$SPONSOR_ADDRESS \
  forge script script/01_Deploy.s.sol \
  --rpc-url $RPC \
  --broadcast \
  --private-key $DEPLOYER_KEY 2>&1)

echo "$OUTPUT"

# Parse addresses from forge console.log output
FACTORY=$(echo "$OUTPUT" | grep 'Factory:' | grep -oE '0x[0-9a-fA-F]{40}')
PAYMASTER=$(echo "$OUTPUT" | grep 'Paymaster:' | grep -oE '0x[0-9a-fA-F]{40}')

if [ -z "$FACTORY" ] || [ -z "$PAYMASTER" ]; then
  echo "ERROR: Failed to parse deployed addresses from forge output"
  exit 1
fi

echo "Factory:   $FACTORY"
echo "Paymaster: $PAYMASTER"

# Fund paymaster EntryPoint deposit (100 ETH)
echo "Funding paymaster deposit..."
cast send "$PAYMASTER" "deposit()" \
  --value 100ether \
  --rpc-url $RPC \
  --private-key $DEPLOYER_KEY > /dev/null

# Write addresses for the Solidity test to read via vm.envAddress
cat > "$SCRIPT_DIR/.env.e2e" <<EOF
FACTORY_ADDRESS=$FACTORY
PAYMASTER_ADDRESS=$PAYMASTER
EOF

# Verify the deployment
echo "Verifying contracts..."
OUTPUT=$(FACTORY_ADDRESS=$FACTORY PAYMASTER_ADDRESS=$PAYMASTER \
  forge script script/VerifyDeploy.s.sol \
  --rpc-url $RPC 2>&1)

echo "$OUTPUT"

echo "Deployment complete. Addresses written to e2e/.env.e2e"
