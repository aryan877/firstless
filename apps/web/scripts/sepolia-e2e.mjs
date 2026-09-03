import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import {
  createPublicClient,
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
const deploymentPath = process.env.FIRSTLESS_TESTNET_DEPLOYMENT
  || process.env.FIRSTLESS_SEPOLIA_DEPLOYMENT
  || resolve(webRoot, "public/deployments/unichain-sepolia.json");
const rpcUrl = process.env.FIRSTLESS_TESTNET_RPC_URL
  || process.env.UNICHAIN_SEPOLIA_RPC_URL
  || process.env.ETHEREUM_SEPOLIA_RPC_URL;
const privateKey = process.env.FIRSTLESS_TESTNET_PRIVATE_KEY
  || process.env.FIRSTLESS_SEPOLIA_PRIVATE_KEY;

if (!rpcUrl) throw new Error("FIRSTLESS_TESTNET_RPC_URL is required.");
if (!privateKey) throw new Error("FIRSTLESS_TESTNET_PRIVATE_KEY is required.");

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
  artifact("FirstlessSepoliaToken.sol/FirstlessSepoliaToken.json"),
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

function invariant(condition, message) {
  if (!condition) throw new Error(`Testnet E2E invariant failed: ${message}`);
}

async function writeContract(address, abi, functionName, args = []) {
  // Unichain's Flashblocks-aware public RPC can expose a preconfirmation view
  // whose account nonce lags the canonical head. Each write waits for its
  // canonical receipt, so the latest canonical nonce is the correct next nonce.
  const nonce = await publicClient.getTransactionCount({ address: account.address, blockTag: "latest" });
  const { request } = await publicClient.simulateContract({ account, address, abi, functionName, args, nonce });
  const hash = await walletClient.writeContract({ ...request, nonce });
  const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 180_000 });
  invariant(receipt.status === "success", `${functionName} transaction reverted`);
  await waitForBlock(receipt.blockNumber);
  return { hash, receipt };
}

async function waitForBlock(targetBlock) {
  const expiresAt = Date.now() + 180_000;
  while (Date.now() < expiresAt) {
    const current = await publicClient.getBlockNumber();
    if (current >= targetBlock) return current;
    await new Promise((resolveWait) => setTimeout(resolveWait, 2_000));
  }
  throw new Error(`Timed out waiting for ${deployment.chainName} block ${targetBlock}.`);
}

async function waitForLaterBlock(blockNumber) {
  return waitForBlock(blockNumber + 1n);
}

invariant(deployment.mode === "testnet", "deployment is not marked testnet");
invariant([1_301, 11_155_111].includes(deployment.chainId), "deployment is not a supported public testnet");
invariant(await publicClient.getChainId() === deployment.chainId, "deployment and RPC chain IDs differ");
for (const address of [
  deployment.poolManager,
  deployment.hook,
  deployment.router,
  deployment.redeemer,
  deployment.token0,
  deployment.token1,
]) {
  invariant((await publicClient.getCode({ address })) !== "0x", `no bytecode at ${address}`);
}

const transactions = {};
const openEpoch = await publicClient.readContract({
  address: deployment.hook,
  abi: hookAbi,
  functionName: "currentEpoch",
});
if (openEpoch[0] !== 0n) {
  await waitForLaterBlock(openEpoch[0]);
  transactions.preflightSettlement = (
    await writeContract(deployment.hook, hookAbi, "settleExpiredEpoch")
  ).hash;
}

const tokenOut0 = deployment.token0Symbol === "fETH";
invariant(tokenOut0 || deployment.token1Symbol === "fETH", "deployment has no fETH output token");
const inputToken = tokenOut0 ? deployment.token1 : deployment.token0;
const outputToken = tokenOut0 ? deployment.token0 : deployment.token1;
const inputSymbol = tokenOut0 ? deployment.token1Symbol : deployment.token0Symbol;
const outputSymbol = tokenOut0 ? deployment.token0Symbol : deployment.token1Symbol;
invariant(inputSymbol === "fUSD" && outputSymbol === "fETH", "expected the fUSD to fETH demo direction");

const outputAmount = parseEther("10");
const inputBefore = await publicClient.readContract({
  address: inputToken,
  abi: tokenAbi,
  functionName: "balanceOf",
  args: [account.address],
});
const outputBefore = await publicClient.readContract({
  address: outputToken,
  abi: tokenAbi,
  functionName: "balanceOf",
  args: [account.address],
});
const maximumInput = await publicClient.readContract({
  address: deployment.hook,
  abi: hookAbi,
  functionName: "requiredMaximumInput",
  args: [tokenOut0, outputAmount],
});
invariant(inputBefore >= maximumInput + parseEther("25"), "deployer lacks enough fUSD for the smoke test");

transactions.orderApproval = (
  await writeContract(inputToken, tokenAbi, "approve", [deployment.router, maximumInput])
).hash;
const [nonce, signingBlock, orderId] = await Promise.all([
  publicClient.readContract({ address: deployment.router, abi: routerAbi, functionName: "nonces", args: [account.address] }),
  publicClient.getBlockNumber(),
  publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "nextOrderId" }),
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
  validAfter: signingBlock + 1n,
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
// The router deliberately rejects an order until its signed block window opens.
// Anvil mines the simulation and transaction in separate blocks, while a public
// RPC simulates against the current head, so wait for validAfter explicitly.
await waitForBlock(order.validAfter);
const execution = await writeContract(deployment.router, routerAbi, "execute", [poolKey, order, signature, "0x"]);
transactions.exactOutputOrder = execution.hash;
const outputAfterExecution = await publicClient.readContract({
  address: outputToken,
  abi: tokenAbi,
  functionName: "balanceOf",
  args: [account.address],
});
invariant(outputAfterExecution - outputBefore === outputAmount, "exact output was not delivered in the execution transaction");

await waitForLaterBlock(execution.receipt.blockNumber);
transactions.settlement = (await writeContract(deployment.hook, hookAbi, "settleExpiredEpoch")).hash;
const claimSimulation = await publicClient.simulateContract({
  account,
  address: deployment.hook,
  abi: hookAbi,
  functionName: "claimRefund",
  args: [orderId],
});
const refund = claimSimulation.result;
invariant(refund > 0n && refund < maximumInput, "settled refund must be positive and smaller than escrow");
transactions.refundClaim = (await writeContract(deployment.hook, hookAbi, "claimRefund", [orderId])).hash;
transactions.redeemerApproval = (
  await writeContract(deployment.poolManager, managerAbi, "setOperator", [deployment.redeemer, true])
).hash;
const inputCurrencyId = BigInt(inputToken);
const backedClaim = await publicClient.readContract({
  address: deployment.poolManager,
  abi: managerAbi,
  functionName: "balanceOf",
  args: [account.address, inputCurrencyId],
});
invariant(backedClaim === refund, "claimed refund does not equal PoolManager backing");
transactions.refundRedemption = (
  await writeContract(deployment.redeemer, redeemerAbi, "redeem", [inputToken, backedClaim, account.address])
).hash;
const inputAfterRefund = await publicClient.readContract({
  address: inputToken,
  abi: tokenAbi,
  functionName: "balanceOf",
  args: [account.address],
});
const finalBill = maximumInput - refund;
invariant(inputBefore - inputAfterRefund === finalBill, "underlying balance does not match final marginal bill");

const deposit0 = parseEther("25");
const deposit1 = parseEther("25");
transactions.lpApproval0 = (
  await writeContract(deployment.token0, tokenAbi, "approve", [deployment.hook, deposit0])
).hash;
transactions.lpApproval1 = (
  await writeContract(deployment.token1, tokenAbi, "approve", [deployment.hook, deposit1])
).hash;
const lpBefore = await publicClient.readContract({
  address: deployment.hook,
  abi: hookAbi,
  functionName: "balanceOf",
  args: [account.address],
});
const depositId = await publicClient.readContract({
  address: deployment.hook,
  abi: hookAbi,
  functionName: "nextDepositId",
});
const liquidityDeadline = BigInt(Math.floor(Date.now() / 1_000) + 1_200);
const queued = await writeContract(deployment.hook, hookAbi, "addLiquidity", [{
  amount0Desired: deposit0,
  amount1Desired: deposit1,
  amount0Min: 0n,
  amount1Min: 0n,
  deadline: liquidityDeadline,
  tickLower: deployment.minimumTick,
  tickUpper: deployment.maximumTick,
  userInputSalt: zeroHash,
}]);
transactions.pendingLiquidity = queued.hash;
const lpWhilePending = await publicClient.readContract({
  address: deployment.hook,
  abi: hookAbi,
  functionName: "balanceOf",
  args: [account.address],
});
invariant(lpWhilePending === lpBefore, "pending deposit received active shares early");

await waitForLaterBlock(queued.receipt.blockNumber);
const preview = await publicClient.readContract({
  address: deployment.hook,
  abi: hookAbi,
  functionName: "previewPendingLiquidity",
  args: [depositId],
});
transactions.liquidityActivation = (
  await writeContract(deployment.hook, hookAbi, "activatePendingLiquidity", [depositId, preview[0]])
).hash;
const lpAfterActivation = await publicClient.readContract({
  address: deployment.hook,
  abi: hookAbi,
  functionName: "balanceOf",
  args: [account.address],
});
invariant(lpAfterActivation === lpBefore + preview[0], "activation did not mint the previewed shares");

const burnAmount = preview[0] / 2n;
transactions.liquidityWithdrawal = (
  await writeContract(deployment.hook, hookAbi, "removeLiquidity", [{
    liquidity: burnAmount,
    amount0Min: 0n,
    amount1Min: 0n,
    deadline: liquidityDeadline,
    tickLower: deployment.minimumTick,
    tickUpper: deployment.maximumTick,
    userInputSalt: zeroHash,
  }])
).hash;
const lpAfterRemoval = await publicClient.readContract({
  address: deployment.hook,
  abi: hookAbi,
  functionName: "balanceOf",
  args: [account.address],
});
invariant(lpAfterRemoval === lpAfterActivation - burnAmount, "active LP withdrawal burned the wrong share amount");

const accounted = await publicClient.readContract({
  address: deployment.hook,
  abi: hookAbi,
  functionName: "accountedMarginalClaims",
});
const [managerClaim0, managerClaim1] = await Promise.all([
  publicClient.readContract({
    address: deployment.poolManager,
    abi: managerAbi,
    functionName: "balanceOf",
    args: [deployment.hook, BigInt(deployment.token0)],
  }),
  publicClient.readContract({
    address: deployment.poolManager,
    abi: managerAbi,
    functionName: "balanceOf",
    args: [deployment.hook, BigInt(deployment.token1)],
  }),
]);
invariant(accounted[0] === managerClaim0 && accounted[1] === managerClaim1, "hook buckets do not equal PoolManager custody");

console.log(JSON.stringify({
  result: "pass",
  chainId: deployment.chainId,
  account: account.address,
  contracts: {
    poolManager: deployment.poolManager,
    hook: deployment.hook,
    router: deployment.router,
    redeemer: deployment.redeemer,
    token0: deployment.token0,
    token1: deployment.token1,
    poolId: deployment.poolId,
  },
  lifecycle: {
    exactOutput: `${formatUnits(outputAmount, 18)} ${outputSymbol}`,
    maximumInput: `${formatUnits(maximumInput, 18)} ${inputSymbol}`,
    finalBill: `${formatUnits(finalBill, 18)} ${inputSymbol}`,
    refund: `${formatUnits(refund, 18)} ${inputSymbol}`,
    pendingSharesActivated: formatUnits(preview[0], 18),
    lpSharesBurned: formatUnits(burnAmount, 18),
  },
  transactions,
}, null, 2));
