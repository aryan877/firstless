#!/usr/bin/env bash
set -euo pipefail

RPC_PORT="${FIRSTLESS_RPC_PORT:-8546}"
PID_FILE="${TMPDIR:-/tmp}/firstless-anvil.pid"

if [[ ! -f "$PID_FILE" ]]; then
  echo "No Firstless Anvil PID file found."
  exit 0
fi

anvil_pid="$(tr -cd '0-9' < "$PID_FILE")"
if [[ -z "$anvil_pid" ]] || ! kill -0 "$anvil_pid" 2>/dev/null; then
  rm -f "$PID_FILE"
  echo "The recorded Firstless Anvil process is no longer running."
  exit 0
fi

anvil_command="$(ps -p "$anvil_pid" -o command=)"
if [[ "$anvil_command" != *anvil*"--port $RPC_PORT"* ]]; then
  echo "Refusing to stop PID $anvil_pid because it is not the recorded Firstless Anvil process." >&2
  exit 1
fi

kill "$anvil_pid"
rm -f "$PID_FILE"
echo "Stopped Firstless Anvil (PID $anvil_pid)."
