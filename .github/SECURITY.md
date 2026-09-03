# Security

Firstless has strong local test coverage. It has not received an independent audit or formal verification.

## Verified scope

- Foundry: 149 passed, 0 failed, 2 public-testnet RPC-only skips.
- Security suites: 105 checks across core accounting, economic behavior, signatures, callbacks and lifecycle edges.
- Fuzzing: 1,000 cases per property.
- Stateful invariants: five properties, 8,192 calls each, zero handler reverts.
- Release-depth campaign: 655,360 mixed stateful calls and 10,000 cases per fuzz property, zero failures.
- Production-only instrumentation: 100% lines and functions, 93.98% statements, and 60.23% branches.
- Slither: the focused high-risk detector set returned zero findings after fixes.
- Local integration: signed order, immediate output, settlement, refund redemption and LP lifecycle passed.
- Web: typecheck, production build and dependency audit passed.

Run the gates:

```bash
npm install
npm run check
npm test
npm run test:e2e --workspace @firstless/contracts
npm run test:coverage
npm audit --audit-level=low
```

## Enforced properties

| Area | Property |
|---|---|
| Orders | A signature binds one payer, pool, direction, output, maximum input, recipient, call plan, clock window, nonce and deadline. |
| Entry | Only the immutable router can enter the judged hook's swap path. |
| Output | Exact output is delivered during the signed transaction. A downstream failure rolls back all state and transfers. |
| Settlement | A set closes only after the canonical chain block advances. Output caps and full-precision arithmetic bound the transition. |
| Refunds | PoolManager claims back every refund. Claims are owner-bound and single-use. |
| Liquidity | Pending capital earns no prior fees. LP exits cannot consume refunds or the protection reserve. |
| Custody | PoolManager claim balances equal the tracked reserves, fees, refunds, escrow, pending deposits and protection reserves. |

## Fixed aggregate-reserve overflow

Settlement previously compared ratio products with direct `uint256` multiplication. Individual liquidity deltas are `int128`-bounded, but active reserves aggregate many deposits in `uint256`. Valid deposits could therefore push `output × reserve` beyond 256 bits and block settlement.

The fix compares both products as exact 512-bit values with OpenZeppelin `Math.mul512`. The same helper protects settlement dominance, the constant-product check and marginal billing.

`test_extremeReservesNearInt128MaxDoNotOverflow` activates 33 deposits of `type(int128).max / 2`, settles both order directions and verifies refund backing against PoolManager custody.

## Reviewed surface

Tests cover cap boundaries, one-wei rounding, order permutations, split orders, sandwich and wash patterns, trader-plus-LP coalitions, signature malleability, EIP-1271 wallets, callback authorization, refund misuse, LP share rounding, timing, external-call rollback, hostile token behavior, calldata growth and settlement gas.

The 100-order cap-fill test measures settlement below 5 million gas in the local harness. Settlement cost does not grow with order count; refund claims remain separate transactions.

The full Slither pass also reports reviewed lower-confidence patterns. Equality checks are zero sentinels or counters. Timestamps enforce signed deadlines and do not set prices. PoolManager calls revert atomically. The router's low-level call is bound by the signed target and calldata hash. Firstless production sources contain no custom assembly.

## Supported boundary

- Conventional ERC-20 pairs only. Native ETH, fee-on-transfer, rebasing and callback-bearing tokens are unsupported.
- Protection covers exact-output orders in the same Firstless pool and canonical-block set.
- Cross-block positioning, cross-pool routing, builder censorship, exact-input flow and external-price LVR are outside the mechanism.
- The immutable router can be replaced only by deploying a new hook.
- Active LP removal waits while a clearing set is open.
- Output caps limit both insolvency exposure and maximum order size.
- Refund claiming and underlying redemption are separate calls. Unredeemed claims remain backed.
- Protection reserves are nonredeemable because assigning them to current LPs reopens the tested trader-plus-LP coalition.

## Release gates

Public-testnet claims require a deployment against that network's official v4 PoolManager, a pinned runtime manifest, transaction links, and a live dependency check. The primary demo meets that bar on Unichain Sepolia; Ethereum Sepolia remains a secondary exercised deployment.

Production readiness would additionally require an independent audit or formal review. Firstless does not claim that today.

Current claim: no known failing property in the completed local scope.
