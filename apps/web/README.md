# Firstless web

The React/Vite app explains the mechanism and drives the real local or Ethereum Sepolia contracts through Wagmi and Viem.

Contract interfaces are generated from `packages/contracts/out` by `wagmi.config.ts`; handwritten ABI fragments are not used.

Run from the repository root:

```bash
npm run contracts:dev
npm run dev
```

The app starts at `http://127.0.0.1:5173` and reads its local deployment from `public/deployments/local.json`.
