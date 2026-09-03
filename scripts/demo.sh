#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

cleanup() {
  npm run contracts:stop >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "Starting Firstless from a blank local chain"
npm run contracts:dev

node scripts/report-local-deployment.mjs

echo
echo "Running the complete transaction lifecycle on the same chain the dashboard will read"
FIRSTLESS_E2E_RPC_URL="${FIRSTLESS_RPC_URL:-http://127.0.0.1:8546}" \
FIRSTLESS_E2E_DEPLOYMENT="$repo_root/apps/web/public/deployments/local.json" \
FIRSTLESS_E2E_HUMAN_ONLY=1 \
  npm run test:local-e2e --workspace @firstless/web

echo
echo "Firstless is ready. Vite will print the exact local URL below."
echo "Connect with Start local demo, then open Activity to inspect this run's transactions."
echo "Keep this terminal open while you use the site."
npm run dev
