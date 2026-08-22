# Firstless contracts

This package owns the production Solidity, Foundry tests, deployment scripts, and the pinned Uniswap/OpenZeppelin hook dependency.

## Layout

```text
src/core/        invariant-bearing clearing, liquidity, escrow, and accounting
src/hooks/       deployable Ethereum Uniswap v4 hook
src/periphery/   signed-order routing and refund redemption
script/          public deploy, local deploy, localnet, and E2E workflows
test/unit/       mechanism behavior
test/integration/ signed-router product seams
test/security/   adversarial, accounting, signature, and callback matrices
test/invariant/  stateful lifecycle properties
test/fork/       opt-in Ethereum Sepolia dependency check
lib/             pinned external Solidity dependencies
```

Tests and scripts import production code through the `firstless/=src/` remapping. This keeps imports stable when test folders move and makes every contract's responsibility visible at the import site.

Run from the repository root:

```bash
npm run build --workspace @firstless/contracts
npm test --workspace @firstless/contracts
npm run test:security --workspace @firstless/contracts
npm run test:coverage --workspace @firstless/contracts
npm run test:e2e --workspace @firstless/contracts
```

Generated `out`, `cache`, `broadcast`, coverage, and local deployment files are ignored.
