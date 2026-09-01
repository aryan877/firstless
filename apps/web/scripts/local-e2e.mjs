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

function invariant(condition, message) {
  if (!condition) throw new Error(`E2E invariant failed: ${message}`);
}

async function writeContract(address, abi, functionName, args = []) {
  const { request } = await publicClient.simulateContract({ account, address, abi, functionName, args });
  const hash = await walletClient.writeContract(request);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  invariant(receipt.status === "success", `${functionName} transaction reverted`);
  return hash;
}

invariant(await publicClient.getChainId() === deployment.chainId, "deployment and RPC chain IDs differ");
for (const address of [deployment.poolManager, deployment.hook, deployment.router, deployment.redeemer]) {
  invariant((await publicClient.getCode({ address })) !== "0x", `no bytecode at ${address}`);
}

const outputAmount = parseEther("10");
const tokenOut0 = false;
const inputToken = deployment.token0;
const outputToken = deployment.token1;
const inputBefore = await publicClient.readContract({ address: inputToken, abi: tokenAbi, functionName: "balanceOf", args: [account.address] });
const outputBefore = await publicClient.readContract({ address: outputToken, abi: tokenAbi, functionName: "balanceOf", args: [account.address] });
const maximumInput = await publicClient.readContract({
  address: deployment.hook,
  abi: hookAbi,
  functionName: "requiredMaximumInput",
  args: [tokenOut0, outputAmount],
});

await writeContract(inputToken, tokenAbi, "approve", [deployment.router, maximumInput]);
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
  zeroForOne: true,
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
const orderHash = await writeContract(deployment.router, routerAbi, "execute", [poolKey, order, signature, "0x"]);
const outputAfterExecution = await publicClient.readContract({ address: outputToken, abi: tokenAbi, functionName: "balanceOf", args: [account.address] });
invariant(outputAfterExecution - outputBefore === outputAmount, "exact output was not delivered in the execution transaction");

await testClient.mine({ blocks: 1 });
const settleHash = await writeContract(deployment.hook, hookAbi, "settleExpiredEpoch");
const claimSimulation = await publicClient.simulateContract({
  account,
  address: deployment.hook,
  abi: hookAbi,
  functionName: "claimRefund",
  args: [0n],
});
const refund = claimSimulation.result;
invariant(refund > 0n && refund < maximumInput, "settled refund must be positive and smaller than escrow");
await writeContract(deployment.hook, hookAbi, "claimRefund", [0n]);
await writeContract(deployment.poolManager, managerAbi, "setOperator", [deployment.redeemer, true]);
const inputCurrencyId = BigInt(inputToken);
const backedClaim = await publicClient.readContract({
  address: deployment.poolManager,
  abi: managerAbi,
  functionName: "balanceOf",
  args: [account.address, inputCurrencyId],
});
invariant(backedClaim === refund, "claimed refund does not equal PoolManager backing");
const redeemHash = await writeContract(deployment.redeemer, redeemerAbi, "redeem", [inputToken, backedClaim, account.address]);
const inputAfterRefund = await publicClient.readContract({ address: inputToken, abi: tokenAbi, functionName: "balanceOf", args: [account.address] });
const finalBill = maximumInput - refund;
invariant(inputBefore - inputAfterRefund === finalBill, "underlying balance does not match final marginal bill");

const deposit0 = parseEther("25");
const deposit1 = parseEther("25");
await writeContract(deployment.token0, tokenAbi, "approve", [deployment.hook, deposit0]);
await writeContract(deployment.token1, tokenAbi, "approve", [deployment.hook, deposit1]);
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
}]);
const lpWhilePending = await publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "balanceOf", args: [account.address] });
invariant(lpWhilePending === lpBefore, "pending deposit received active shares early");
await testClient.mine({ blocks: 1 });
const preview = await publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "previewPendingLiquidity", args: [depositId] });
await writeContract(deployment.hook, hookAbi, "activatePendingLiquidity", [depositId, preview[0]]);
const lpAfterActivation = await publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "balanceOf", args: [account.address] });
invariant(lpAfterActivation === lpBefore + preview[0], "activation did not mint the previewed shares");
const burnAmount = preview[0] / 2n;
await writeContract(deployment.hook, hookAbi, "removeLiquidity", [{
  liquidity: burnAmount,
  amount0Min: 0n,
  amount1Min: 0n,
  deadline,
  tickLower: deployment.minimumTick,
  tickUpper: deployment.maximumTick,
  userInputSalt: zeroHash,
}]);
const lpAfterRemoval = await publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "balanceOf", args: [account.address] });
invariant(lpAfterRemoval === lpAfterActivation - burnAmount, "active LP withdrawal burned the wrong share amount");

const accounted = await publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "accountedMarginalClaims" });
const managerClaim0 = await publicClient.readContract({ address: deployment.poolManager, abi: managerAbi, functionName: "balanceOf", args: [deployment.hook, BigInt(deployment.token0)] });
const managerClaim1 = await publicClient.readContract({ address: deployment.poolManager, abi: managerAbi, functionName: "balanceOf", args: [deployment.hook, BigInt(deployment.token1)] });
invariant(accounted[0] === managerClaim0 && accounted[1] === managerClaim1, "final hook buckets do not equal PoolManager custody");

console.log(JSON.stringify({
  result: "pass",
  chainId: deployment.chainId,
  orderHash,
  settleHash,
  redeemHash,
  exactOutput: formatUnits(outputAmount, 18),
  maximumInput: formatUnits(maximumInput, 18),
  finalBill: formatUnits(finalBill, 18),
  refund: formatUnits(refund, 18),
  pendingSharesActivated: formatUnits(preview[0], 18),
  lpSharesBurned: formatUnits(burnAmount, 18),
}, null, 2));
