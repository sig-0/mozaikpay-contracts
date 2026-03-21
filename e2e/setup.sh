#!/bin/sh
set -e

RPC="http://localhost:8545"
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

# Anvil account #2 - used as the paymaster sponsor signer.
SPONSOR_ADDRESS="0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"

# Canonical addresses - match production on Base mainnet.
CANONICAL_EP="0x433709009B8330FDa32311DF1C2AFA402eD8D009"
CANONICAL_SC="0x0A630a99Df908A81115A3022927Be82f9299987e"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# === Place EntryPoint v0.9 + SenderCreator at canonical addresses ===
echo "Etching EntryPoint v0.9 and SenderCreator..."

EP_BYTECODE=$(cat "$SCRIPT_DIR/testdata/entrypoint_v09.bytecode")
SC_BYTECODE=$(cat "$SCRIPT_DIR/testdata/sendercreator.bytecode")

cast rpc anvil_setCode "$CANONICAL_EP" "\"$EP_BYTECODE\"" --rpc-url $RPC > /dev/null
cast rpc anvil_setCode "$CANONICAL_SC" "\"$SC_BYTECODE\"" --rpc-url $RPC > /dev/null

# Verify cross-references
VERIFY_SC=$(cast call $CANONICAL_EP "senderCreator()(address)" --rpc-url $RPC)
VERIFY_EP=$(cast call $CANONICAL_SC "entryPoint()(address)" --rpc-url $RPC)
echo "EntryPoint etched at $CANONICAL_EP (senderCreator: $VERIFY_SC)"
echo "SenderCreator etched at $CANONICAL_SC (entryPoint: $VERIFY_EP)"

if [ "$VERIFY_SC" != "$CANONICAL_SC" ]; then
  echo "ERROR: senderCreator() returned $VERIFY_SC, expected $CANONICAL_SC"
  exit 1
fi

if [ "$VERIFY_EP" != "$CANONICAL_EP" ]; then
  echo "ERROR: entryPoint() returned $VERIFY_EP, expected $CANONICAL_EP"
  exit 1
fi

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
