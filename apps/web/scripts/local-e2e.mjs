import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  defineChain,
  formatUnits,
  http,
  keccak256,
  parseEther,
  zeroAddress,
  zeroHash,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = resolve(webRoot, "../..");
const contractsRoot = resolve(repoRoot, "packages/contracts");
const deploymentPath = process.env.FIRSTLESS_E2E_DEPLOYMENT || resolve(contractsRoot, ".local/e2e-deployment.json");
const rpcUrl = process.env.FIRSTLESS_E2E_RPC_URL || "http://127.0.0.1:8547";
// Public Anvil account 0 key. It is test-only and must never fund a public chain.
const privateKey = process.env.FIRSTLESS_E2E_PRIVATE_KEY || "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

async function json(path) {
  return JSON.parse(await readFile(path, "utf8"));
}

async function artifact(relativePath) {
  return (await json(resolve(contractsRoot, "out", relativePath))).abi;
}

const deployment = await json(deploymentPath);
const [hookAbi, routerAbi, redeemerAbi, tokenAbi, managerAbi] = await Promise.all([
  artifact("FirstlessHook.sol/FirstlessHook.json"),
  artifact("FirstlessRouter.sol/FirstlessRouter.json"),
  artifact("FirstlessRefundRedeemer.sol/FirstlessRefundRedeemer.json"),
  artifact("LocalDevContracts.sol/FirstlessDevToken.json"),
  artifact("PoolManager.sol/PoolManager.json"),
]);

const chain = defineChain({
  id: deployment.chainId,
  name: deployment.chainName,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [rpcUrl] } },
  testnet: true,
});
const account = privateKeyToAccount(privateKey);
const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });
const walletClient = createWalletClient({ account, chain, transport: http(rpcUrl) });
const testClient = createTestClient({ chain, mode: "anvil", transport: http(rpcUrl) });
const narrate = process.env.FIRSTLESS_E2E_JSON_ONLY !== "1";
const transactions = [];

function say(message = "") {
  if (narrate) console.log(message);
}

function chapter(title) {
  say(`\n${title}`);
}

function invariant(condition, message) {
  if (!condition) throw new Error(`E2E invariant failed: ${message}`);
}

async function writeContract(address, abi, functionName, args = [], label = functionName) {
  const { request } = await publicClient.simulateContract({ account, address, abi, functionName, args });
  const hash = await walletClient.writeContract(request);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  invariant(receipt.status === "success", `${functionName} transaction reverted`);
  transactions.push({ label, hash, block: receipt.blockNumber.toString() });
  say(`  ${label}`);
  say(`  tx ${hash}`);
  say(`  confirmed in block ${receipt.blockNumber}`);
  return hash;
}

invariant(await publicClient.getChainId() === deployment.chainId, "deployment and RPC chain IDs differ");
for (const address of [deployment.poolManager, deployment.hook, deployment.router, deployment.redeemer, deployment.token0, deployment.token1]) {
  invariant((await publicClient.getCode({ address })) !== "0x", `no bytecode at ${address}`);
}

const [token0Name, token1Name] = await Promise.all([
  publicClient.readContract({ address: deployment.token0, abi: tokenAbi, functionName: "name" }),
  publicClient.readContract({ address: deployment.token1, abi: tokenAbi, functionName: "name" }),
]);
const tokenOut0 = deployment.token0Symbol === "fETH";
invariant(tokenOut0 || deployment.token1Symbol === "fETH", "the local pair must include fETH");
const outputAmount = parseEther("10");
const inputToken = tokenOut0 ? deployment.token1 : deployment.token0;
const outputToken = tokenOut0 ? deployment.token0 : deployment.token1;
const inputSymbol = tokenOut0 ? deployment.token1Symbol : deployment.token0Symbol;
const outputSymbol = tokenOut0 ? deployment.token0Symbol : deployment.token1Symbol;

chapter("Now let’s use the deployment like a real user.");
say(`The pair uses our own local test tokens: ${token0Name} (${deployment.token0Symbol}) and ${token1Name} (${deployment.token1Symbol}).`);
say(`This run asks for exactly 10 ${outputSymbol}. Firstless quotes a conservative maximum in ${inputSymbol}, sends the output now, and calculates the final bill after the block closes.`);

const inputBefore = await publicClient.readContract({ address: inputToken, abi: tokenAbi, functionName: "balanceOf", args: [account.address] });
const outputBefore = await publicClient.readContract({ address: outputToken, abi: tokenAbi, functionName: "balanceOf", args: [account.address] });
const maximumInput = await publicClient.readContract({
  address: deployment.hook,
  abi: hookAbi,
  functionName: "requiredMaximumInput",
  args: [tokenOut0, outputAmount],
});

chapter("1. Lock the maximum and execute the signed exact-output order");
say(`The hook quotes ${formatUnits(maximumInput, 18)} ${inputSymbol} as the maximum. That is escrow, not the final price.`);
await writeContract(inputToken, tokenAbi, "approve", [deployment.router, maximumInput], `Approve ${inputSymbol} for the signed-order router`);
const [nonce, signingBlock] = await Promise.all([
  publicClient.readContract({ address: deployment.router, abi: routerAbi, functionName: "nonces", args: [account.address] }),
  publicClient.getBlockNumber(),
]);
const deadline = BigInt(Math.floor(Date.now() / 1_000) + 1_200);
const order = {
  poolId: deployment.poolId,
  payer: account.address,
  recipient: account.address,
  callTarget: zeroAddress,
  callDataHash: keccak256("0x"),
  zeroForOne: !tokenOut0,
  amountOut: outputAmount,
  maximumInput,
  validAfter: signingBlock,
  validBefore: signingBlock + 30n,
  nonce,
  deadline,
};
const signature = await walletClient.signTypedData({
  account,
  domain: { name: "Firstless", version: "1", chainId: deployment.chainId, verifyingContract: deployment.router },
  primaryType: "CreditOrder",
  types: {
    CreditOrder: [
      { name: "poolId", type: "bytes32" },
      { name: "payer", type: "address" },
      { name: "recipient", type: "address" },
      { name: "callTarget", type: "address" },
      { name: "callDataHash", type: "bytes32" },
      { name: "zeroForOne", type: "bool" },
      { name: "amountOut", type: "uint128" },
      { name: "maximumInput", type: "uint128" },
      { name: "validAfter", type: "uint64" },
      { name: "validBefore", type: "uint64" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  },
  message: order,
});
const poolKey = {
  currency0: deployment.token0,
  currency1: deployment.token1,
  fee: deployment.poolFee,
  tickSpacing: deployment.tickSpacing,
  hooks: deployment.hook,
};
say("The EIP-712 signature binds the payer, pool, recipient, amount, maximum, nonce, call plan, and validity window. Signing is offchain; execution is the transaction below.");
const orderHash = await writeContract(
  deployment.router,
  routerAbi,
  "execute",
  [poolKey, order, signature, "0x"],
  `Execute order #0 and deliver exactly 10 ${outputSymbol}`,
);
const outputAfterExecution = await publicClient.readContract({ address: outputToken, abi: tokenAbi, functionName: "balanceOf", args: [account.address] });
invariant(outputAfterExecution - outputBefore === outputAmount, "exact output was not delivered in the execution transaction");
say(`  balance check: the wallet received exactly ${formatUnits(outputAfterExecution - outputBefore, 18)} ${outputSymbol} in that transaction`);

chapter("2. Close the Ethereum block set and calculate the marginal bill");
await testClient.mine({ blocks: 1 });
say("We mine the next Anvil block so the set is complete. No order is priced from a partial set.");
const settleHash = await writeContract(deployment.hook, hookAbi, "settleExpiredEpoch", [], "Settle the completed block set");
const claimSimulation = await publicClient.simulateContract({
  account,
  address: deployment.hook,
  abi: hookAbi,
  functionName: "claimRefund",
  args: [0n],
});
const refund = claimSimulation.result;
invariant(refund > 0n && refund < maximumInput, "settled refund must be positive and smaller than escrow");
const finalBill = maximumInput - refund;
say(`The final leave-one-out bill is ${formatUnits(finalBill, 18)} ${inputSymbol}. The unused ${formatUnits(refund, 18)} ${inputSymbol} belongs to the trader.`);

chapter("3. Turn the backed refund into the underlying test token");
await writeContract(deployment.hook, hookAbi, "claimRefund", [0n], `Claim order #0 refund as a backed PoolManager claim`);
await writeContract(deployment.poolManager, managerAbi, "setOperator", [deployment.redeemer, true], "Authorize the refund redeemer");
const inputCurrencyId = BigInt(inputToken);
const backedClaim = await publicClient.readContract({
  address: deployment.poolManager,
  abi: managerAbi,
  functionName: "balanceOf",
  args: [account.address, inputCurrencyId],
});
invariant(backedClaim === refund, "claimed refund does not equal PoolManager backing");
say(`  custody check: PoolManager backs ${formatUnits(backedClaim, 18)} ${inputSymbol} before redemption`);
const redeemHash = await writeContract(
  deployment.redeemer,
  redeemerAbi,
  "redeem",
  [inputToken, backedClaim, account.address],
  `Redeem the claim for ${formatUnits(backedClaim, 18)} ${inputSymbol}`,
);
const inputAfterRefund = await publicClient.readContract({ address: inputToken, abi: tokenAbi, functionName: "balanceOf", args: [account.address] });
invariant(inputBefore - inputAfterRefund === finalBill, "underlying balance does not match final marginal bill");
say(`  balance check: the wallet's net spend is ${formatUnits(inputBefore - inputAfterRefund, 18)} ${inputSymbol}`);

chapter("4. Prove that new liquidity cannot earn from an old set");
const deposit0 = parseEther("25");
const deposit1 = parseEther("25");
await writeContract(deployment.token0, tokenAbi, "approve", [deployment.hook, deposit0], `Approve 25 ${deployment.token0Symbol} for the hook`);
await writeContract(deployment.token1, tokenAbi, "approve", [deployment.hook, deposit1], `Approve 25 ${deployment.token1Symbol} for the hook`);
const lpBefore = await publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "balanceOf", args: [account.address] });
const depositId = await publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "nextDepositId" });
await writeContract(deployment.hook, hookAbi, "addLiquidity", [{
  amount0Desired: deposit0,
  amount1Desired: deposit1,
  amount0Min: 0n,
  amount1Min: 0n,
  deadline,
  tickLower: deployment.minimumTick,
  tickUpper: deployment.maximumTick,
  userInputSalt: zeroHash,
}], `Submit a pending deposit with 25 ${deployment.token0Symbol} and 25 ${deployment.token1Symbol} desired`);
const [lpWhilePending, queuedDeposit] = await Promise.all([
  publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "balanceOf", args: [account.address] }),
  publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "pendingLiquidity", args: [depositId] }),
]);
invariant(lpWhilePending === lpBefore, "pending deposit received active shares early");
say(`  queue check: the hook accepted ${formatUnits(queuedDeposit[2], 18)} ${deployment.token0Symbol} and ${formatUnits(queuedDeposit[3], 18)} ${deployment.token1Symbol} at the live ratio`);
say("  ownership check: the pending deposit received zero active LP shares in its queue block");
await testClient.mine({ blocks: 1 });
const preview = await publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "previewPendingLiquidity", args: [depositId] });
await writeContract(
  deployment.hook,
  hookAbi,
  "activatePendingLiquidity",
  [depositId, preview[0]],
  `Activate deposit #${depositId} one block later`,
);
const lpAfterActivation = await publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "balanceOf", args: [account.address] });
invariant(lpAfterActivation === lpBefore + preview[0], "activation did not mint the previewed shares");
say(`  share check: activation minted ${formatUnits(preview[0], 18)} FIRST-LP`);
const burnAmount = preview[0] / 2n;
await writeContract(deployment.hook, hookAbi, "removeLiquidity", [{
  liquidity: burnAmount,
  amount0Min: 0n,
  amount1Min: 0n,
  deadline,
  tickLower: deployment.minimumTick,
  tickUpper: deployment.maximumTick,
  userInputSalt: zeroHash,
}], `Withdraw half of the newly activated LP position`);
const lpAfterRemoval = await publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "balanceOf", args: [account.address] });
invariant(lpAfterRemoval === lpAfterActivation - burnAmount, "active LP withdrawal burned the wrong share amount");

const accounted = await publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "accountedMarginalClaims" });
const managerClaim0 = await publicClient.readContract({ address: deployment.poolManager, abi: managerAbi, functionName: "balanceOf", args: [deployment.hook, BigInt(deployment.token0)] });
const managerClaim1 = await publicClient.readContract({ address: deployment.poolManager, abi: managerAbi, functionName: "balanceOf", args: [deployment.hook, BigInt(deployment.token1)] });
invariant(accounted[0] === managerClaim0 && accounted[1] === managerClaim1, "final hook buckets do not equal PoolManager custody");

chapter("Fresh Firstless demo finished");
say(`The order delivered exactly 10 ${outputSymbol}, charged ${formatUnits(finalBill, 18)} ${inputSymbol}, and returned ${formatUnits(refund, 18)} ${inputSymbol}.`);
say(`All ${transactions.length} lifecycle transactions confirmed, and the hook's final accounting matches PoolManager custody.`);
say("Open the dashboard with the local demo wallet, then choose Activity to see the hook transactions from this same chain.");

if (process.env.FIRSTLESS_E2E_HUMAN_ONLY !== "1") {
  console.log(JSON.stringify({
    result: "pass",
    chainId: deployment.chainId,
    orderHash,
    settleHash,
    redeemHash,
    inputSymbol,
    outputSymbol,
    exactOutput: formatUnits(outputAmount, 18),
    maximumInput: formatUnits(maximumInput, 18),
    finalBill: formatUnits(finalBill, 18),
    refund: formatUnits(refund, 18),
    pendingSharesActivated: formatUnits(preview[0], 18),
    lpSharesBurned: formatUnits(burnAmount, 18),
    transactions,
  }, null, 2));
}
