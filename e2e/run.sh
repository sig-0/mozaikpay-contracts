#!/bin/sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ANVIL_PID=""

cleanup() {
  if [ -n "$ANVIL_PID" ]; then
    kill "$ANVIL_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
  fi

  rm -f "$SCRIPT_DIR/.env.e2e"
}

trap cleanup EXIT

# Start anvil
echo "Starting anvil..."
anvil --chain-id 8453 --silent &
ANVIL_PID=$!

# Wait for anvil to be ready
echo "Waiting for anvil..."
until cast block-number --rpc-url http://localhost:8545 > /dev/null 2>&1; do
  sleep 0.2
done

echo "Anvil is ready (PID: $ANVIL_PID)"

# Deploy contracts
"$SCRIPT_DIR/setup.sh"

# Source .env.e2e so forge test can read the vars
set -a
. "$SCRIPT_DIR/.env.e2e"
set +a

# Run e2e tests
echo ""
echo "=== Running e2e tests ==="
cd "$PROJECT_DIR"
FOUNDRY_PROFILE=e2e forge test --fork-url http://localhost:8545
