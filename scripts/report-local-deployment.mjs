import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const deploymentPath = process.env.FIRSTLESS_DEPLOYMENT_PATH
  || resolve(repoRoot, "apps/web/public/deployments/local.json");
const broadcastPath = process.env.FIRSTLESS_BROADCAST_PATH
  || resolve(repoRoot, "packages/contracts/broadcast/LocalDeploy.s.sol/31337/run-latest.json");

const [deployment, broadcast] = await Promise.all([
  readFile(deploymentPath, "utf8").then(JSON.parse),
  readFile(broadcastPath, "utf8").then(JSON.parse),
]);

const receipts = new Map(
  broadcast.receipts.map((receipt) => [receipt.transactionHash.toLowerCase(), receipt]),
);

function confirmed(transaction) {
  const receipt = receipts.get(transaction.hash.toLowerCase());
  if (!receipt || BigInt(receipt.status) !== 1n) {
    throw new Error(`Deployment transaction did not confirm: ${transaction.hash}`);
  }
  return receipt;
}

function printTransaction(label, transaction) {
  const receipt = confirmed(transaction);
  console.log(`  ${label}`);
  console.log(`  tx ${transaction.hash}`);
  console.log(`  confirmed in block ${BigInt(receipt.blockNumber)}`);
}

function contract(name, occurrence = 0) {
  const matches = broadcast.transactions.filter(
    (transaction) => transaction.contractName === name && transaction.transactionType.startsWith("CREATE"),
  );
  const transaction = matches[occurrence];
  if (!transaction) throw new Error(`Missing ${name} deployment transaction`);
  return transaction;
}

function call(functionPrefix, occurrence = 0) {
  const matches = broadcast.transactions.filter(
    (transaction) => transaction.function?.startsWith(functionPrefix),
  );
  const transaction = matches[occurrence];
  if (!transaction) throw new Error(`Missing ${functionPrefix} deployment call`);
  return transaction;
}

const poolManager = contract("PoolManager");
const testUsd = contract("FirstlessDevToken", 0);
const testEth = contract("FirstlessDevToken", 1);
const router = contract("FirstlessRouter");
const redeemer = contract("FirstlessRefundRedeemer");
const hook = contract("FirstlessHook");

function symbolFor(transaction) {
  if (transaction.contractAddress.toLowerCase() === deployment.token0.toLowerCase()) return deployment.token0Symbol;
  if (transaction.contractAddress.toLowerCase() === deployment.token1.toLowerCase()) return deployment.token1Symbol;
  throw new Error(`Unknown local test token: ${transaction.contractAddress}`);
}

const expectedAddresses = new Map([
  [poolManager.contractAddress.toLowerCase(), deployment.poolManager.toLowerCase()],
  [router.contractAddress.toLowerCase(), deployment.router.toLowerCase()],
  [redeemer.contractAddress.toLowerCase(), deployment.redeemer.toLowerCase()],
  [hook.contractAddress.toLowerCase(), deployment.hook.toLowerCase()],
]);
for (const [actual, expected] of expectedAddresses) {
  if (actual !== expected) throw new Error(`Manifest address mismatch: expected ${expected}, received ${actual}`);
}

console.log("\nFresh chain, fresh contracts");
console.log("This is a new in-memory Anvil chain. We are not reusing an earlier deployment or transaction history.");

printTransaction(`Deploy Uniswap v4 PoolManager at ${deployment.poolManager}`, poolManager);
printTransaction(`Deploy our Firstless USD test token (fUSD) at ${testUsd.contractAddress}`, testUsd);
printTransaction(`Deploy our Firstless Ether test token (fETH) at ${testEth.contractAddress}`, testEth);
printTransaction(`Deploy the signed-order router at ${deployment.router}`, router);
printTransaction(`Deploy the refund redeemer at ${deployment.redeemer}`, redeemer);
printTransaction(`Deploy the flag-valid Firstless hook at ${deployment.hook}`, hook);

console.log("\nBuild the local market");
printTransaction("Initialize the fETH/fUSD v4 pool at a 1:1 opening price", call("initialize("));
const initialMint0 = call("faucet(", 0);
const initialMint1 = call("faucet(", 1);
const approval0 = call("approve(", 0);
const approval1 = call("approve(", 1);
const walletMint0 = call("faucet(", 2);
const walletMint1 = call("faucet(", 3);
printTransaction(`Mint 1,000 ${symbolFor(initialMint0)} for initial liquidity`, initialMint0);
printTransaction(`Mint 1,000 ${symbolFor(initialMint1)} for initial liquidity`, initialMint1);
printTransaction(`Approve ${symbolFor(approval0)} for the hook`, approval0);
printTransaction(`Approve ${symbolFor(approval1)} for the hook`, approval1);
printTransaction("Seed the pool with 1,000 fETH and 1,000 fUSD", call("addLiquidity("));
printTransaction(`Mint 10,000 ${symbolFor(walletMint0)} for the demo wallet`, walletMint0);
printTransaction(`Mint 10,000 ${symbolFor(walletMint1)} for the demo wallet`, walletMint1);

console.log(`\nDeployment manifest written to ${deploymentPath}`);
console.log(`All ${broadcast.transactions.length} deployment and setup transactions confirmed.`);
