#!/usr/bin/env bash
set -euo pipefail

CONTRACTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$CONTRACTS_ROOT/../.." && pwd)"
RPC_PORT="${FIRSTLESS_E2E_PORT:-8547}"
RPC_URL="http://127.0.0.1:${RPC_PORT}"
DEPLOYMENT_PATH="$CONTRACTS_ROOT/.local/e2e-deployment.json"
# Public Anvil account 0 key. It is test-only and must never fund a public chain.
PRIVATE_KEY="${FIRSTLESS_E2E_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

cd "$CONTRACTS_ROOT"
mkdir -p "$(dirname "$DEPLOYMENT_PATH")"
if lsof -nP -iTCP:"$RPC_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $RPC_PORT is already in use; refusing to disturb it." >&2
  exit 1
fi

anvil --host 127.0.0.1 --port "$RPC_PORT" --chain-id 31337 --gas-limit 200000000 --silent &
anvil_pid=$!
trap 'kill "$anvil_pid" 2>/dev/null || true' EXIT

for _ in {1..40}; do
  if cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

forge build --quiet
PRIVATE_KEY="$PRIVATE_KEY" \
FIRSTLESS_RPC_URL="$RPC_URL" \
FIRSTLESS_DEPLOYMENT_PATH="$DEPLOYMENT_PATH" \
forge script script/LocalDeploy.s.sol:LocalDeployFirstless --rpc-url "$RPC_URL" --broadcast --slow -q

FIRSTLESS_E2E_RPC_URL="$RPC_URL" \
FIRSTLESS_E2E_DEPLOYMENT="$DEPLOYMENT_PATH" \
FIRSTLESS_E2E_PRIVATE_KEY="$PRIVATE_KEY" \
npm --prefix "$REPO_ROOT" run test:local-e2e --workspace @firstless/web
