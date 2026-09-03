# Firstless web

The React/Vite app explains the mechanism and drives the real local, Unichain Sepolia, or Ethereum Sepolia contracts through Wagmi and Viem.

Contract interfaces are generated from `packages/contracts/out` by `wagmi.config.ts`; handwritten ABI fragments are not used.

Run from the repository root:

```bash
npm run contracts:dev
npm run dev
```

The app starts at `http://127.0.0.1:5173` and reads its local deployment from `public/deployments/local.json`.

For the full walkthrough, run `npm run demo` from the repository root. It deploys a blank Anvil environment, executes the signed order through refund redemption and LP activation, then starts this app against that exact transaction history.

The landing story is `/`. The contract dashboard is `/?view=dashboard`, and the public mechanism reference is `/?view=docs`.
