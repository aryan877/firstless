#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

cleanup() {
  npm run contracts:stop >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "Launching a fresh Firstless local chain and web demo"
npm run contracts:dev
echo "Firstless is ready. Keep this terminal open while using the site."
npm run dev
