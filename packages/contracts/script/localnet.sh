#!/usr/bin/env bash
set -euo pipefail

CONTRACTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$CONTRACTS_ROOT/../.." && pwd)"
DEPLOYMENT_PATH="$REPO_ROOT/apps/web/public/deployments/local.json"
RPC_PORT="${FIRSTLESS_RPC_PORT:-8546}"
RPC_URL="${FIRSTLESS_RPC_URL:-http://127.0.0.1:${RPC_PORT}}"
PID_FILE="${TMPDIR:-/tmp}/firstless-anvil.pid"
LOG_FILE="${TMPDIR:-/tmp}/firstless-anvil.log"
# Public Anvil account 0 key. It is test-only and must never fund a public chain.
LOCAL_PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

cd "$CONTRACTS_ROOT"

if [[ -f "$PID_FILE" ]]; then
  existing_pid="$(tr -cd '0-9' < "$PID_FILE")"
  if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
    existing_command="$(ps -p "$existing_pid" -o command=)"
    if [[ "$existing_command" == *anvil*"--port $RPC_PORT"* ]]; then
      kill "$existing_pid"
      wait "$existing_pid" 2>/dev/null || true
    else
      echo "Refusing to stop PID $existing_pid because it is not the recorded Firstless Anvil process." >&2
      exit 1
    fi
  fi
  rm -f "$PID_FILE"
fi

if lsof -nP -iTCP:"$RPC_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $RPC_PORT is already in use. Stop that process or set FIRSTLESS_RPC_PORT." >&2
  exit 1
fi

nohup anvil \
  --host 127.0.0.1 \
  --port "$RPC_PORT" \
  --chain-id 31337 \
  --block-time 1 \
  --gas-limit 200000000 \
  --silent </dev/null >"$LOG_FILE" 2>&1 &
anvil_pid=$!
echo "$anvil_pid" > "$PID_FILE"

cleanup_on_error() {
  exit_code=$?
  if [[ $exit_code -ne 0 ]] && kill -0 "$anvil_pid" 2>/dev/null; then
    kill "$anvil_pid"
  fi
  exit "$exit_code"
}
trap cleanup_on_error EXIT

for _ in {1..40}; do
  if cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

actual_chain_id="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$actual_chain_id" != "31337" ]]; then
  echo "Expected local chain ID 31337, received $actual_chain_id." >&2
  exit 1
fi

mkdir -p "$(dirname "$DEPLOYMENT_PATH")"
forge build --quiet

PRIVATE_KEY="$LOCAL_PRIVATE_KEY" FIRSTLESS_RPC_URL="$RPC_URL" FIRSTLESS_DEPLOYMENT_PATH="$DEPLOYMENT_PATH" \
  forge script script/LocalDeploy.s.sol:LocalDeployFirstless \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --slow \
  -q

trap - EXIT
echo "Firstless local chain is ready at $RPC_URL (PID $anvil_pid)."
echo "Deployment: $DEPLOYMENT_PATH"
echo "Log: $LOG_FILE"
