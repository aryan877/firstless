# Firstless

**Receive the output now. Let the complete clearing set decide the final input bill.**

Firstless is a Uniswap v4 hook that separates delivery order from final billing. A signed exact-output order receives its tokens immediately, while the completed same-block order set determines the final input charge and refundable remainder.

## Quick start

Prerequisites: Node.js 22+, npm 10+, and Foundry.

```bash
git submodule update --init --recursive
npm install
npm run build
npm test
```

Everything public runs from the repository root. Turbo coordinates the web app and Foundry package without mixing their source or generated files.

## Repository layout

```text
firstless/
├── apps/
│   └── web/                    # React/Vite product and generated contract client
├── packages/
│   ├── contracts/              # Foundry project
│   │   ├── src/
│   │   │   ├── core/           # Clearing and accounting invariants
│   │   │   ├── hooks/          # Deployable Ethereum hook
│   │   │   └── periphery/      # Router and refund redemption
│   │   ├── script/             # Deploy, localnet, and E2E scripts
│   │   ├── test/
│   │   │   ├── unit/
│   │   │   ├── integration/
│   │   │   ├── security/
│   │   │   ├── invariant/
│   │   │   └── fork/
│   │   └── lib/                # Pinned Uniswap/OpenZeppelin submodule
├── scripts/                    # Repository-level workflows
├── turbo.json                  # Task graph and cache boundaries
└── package.json                # Root command surface and npm workspaces
```

The dependency direction is one-way:

```text
contracts build artifacts → generated web client → web app
```

Contracts never depend on the frontend.

## Commands

| Command | Purpose |
|---|---|
| `npm run dev` | Build contract dependencies, generate ABIs, and start the web app |
| `npm run contracts:dev` | Start Anvil and deploy the complete local Firstless stack |
| `npm run contracts:stop` | Stop the recorded Firstless Anvil process |
| `npm run build` | Build every package through Turbo |
| `npm run check` | Run formatting, compilation, and static package checks |
| `npm test` | Run the contract test task |
| `npm run demo` | Run the isolated onchain lifecycle |

Focused contract suites remain available from the root:

```bash
npm run test:unit --workspace @firstless/contracts
npm run test:integration --workspace @firstless/contracts
npm run test:security --workspace @firstless/contracts
npm run test:invariant --workspace @firstless/contracts
npm run test:e2e --workspace @firstless/contracts
```

## Run the local product

Start the chain in one terminal:

```bash
npm run contracts:dev
```

Start the web app in another:

```bash
npm run dev
```

Open `http://127.0.0.1:5173`. The web app reads the deployment generated at `apps/web/public/deployments/local.json`, signs a real EIP-712 order, and sends real local transactions.

## How the mechanism works

1. A user signs an exact-output order, such as “receive 10 WETH, spend at most 25,000 USDC.”
2. `FirstlessRouter` verifies the payer, pool, recipient, nonce, deadline, call plan, and block window.
3. The hook collects a conservative input maximum and delivers the exact output in the same transaction.
4. All opted-in orders observed in the same Ethereum block join one clearing set.
5. After the block advances, opposing flow nets at the set’s opening reserve ratio and only the residual moves the curve.
6. Each order pays the gross cost that disappears when that order is removed from the complete set. The unused maximum becomes a backed PoolManager claim redeemable as the underlying token.

```text
final bill(i) = cost(complete set) - cost(set without i) + rounding buffer
refund(i)     = escrow(i) - final bill(i)
```

The hook applies the same rule to every order. It does not label addresses as attackers.

## Implemented contracts

- `FirstlessHook.sol`: judged Ethereum Sepolia hook using `block.number` as the clearing clock.
- `FirstlessRouter.sol`: EIP-712 authentication, payer settlement, and immediate output delivery.
- `MarginalClearingEpoch.sol`: set netting and leave-one-out charging.
- `FirstlessRefundRedeemer.sol`: converts backed PoolManager refund claims into underlying tokens.
- `ClearingCreditEpoch.sol`: liquidity, LP shares, escrow, refunds, and settlement liabilities.

## Verification status

The current no-RPC Foundry run reports 149 passed, 1 explicitly skipped Ethereum Sepolia fork check, and 0 failed across 150 entries. That includes 105 checks across four security suites, five stateful lifecycle invariants with 8,192 calls each, and 1,000 fuzz cases per property. The accurate production-only coverage gate reports 100% lines and functions, 93.98% statements, and 60.23% branches.

See the [security policy](.github/SECURITY.md) for exact public claims and exclusions.

## Ethereum Sepolia deployment

The judged artifact is locked to Ethereum Sepolia and the official v4 PoolManager at `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`.

```bash
cd packages/contracts
cp .env.example .env
# Fill PRIVATE_KEY and ETHEREUM_SEPOLIA_RPC_URL, then load the file.
set -a
source .env
set +a
forge script script/Deploy.s.sol:DeployFirstless \
  --rpc-url "$ETHEREUM_SEPOLIA_RPC_URL" \
  --broadcast
```

No public testnet or mainnet deployment is claimed until broadcast and verification are complete.

## Boundaries

- Exact-output conventional ERC-20 pairs only; native ETH should be wrapped as WETH.
- Protection covers orders routed through the same Firstless pool and clearing set.
- Cross-set, cross-pool, censorship, CEX-DEX LVR, and external price movement remain outside the claim.
- Direct PoolManager routers cannot bypass the signed-order boundary.
- Pending LP assets remain outside active reserves until provider-owned activation.
- The code uses OpenZeppelin’s experimental custom-accounting base and has not been independently audited.

## License

[MIT](LICENSE)
