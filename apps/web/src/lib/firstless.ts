import {
  createPublicClient,
  defineChain,
  encodeFunctionData,
  getAddress,
  http,
  type Abi,
  type Address,
  type Chain,
  type Hash,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";
import {
  firstlessDevTokenAbi,
  firstlessHookAbi,
  firstlessRefundRedeemerAbi,
  firstlessRouterAbi,
  poolManagerAbi,
} from "@/generated/contracts";

export const hookAbi = firstlessHookAbi;
export const routerAbi = firstlessRouterAbi;
export const erc20Abi = firstlessDevTokenAbi;
export const redeemerAbi = firstlessRefundRedeemerAbi;
export { poolManagerAbi };

export type Deployment = {
  schemaVersion: number;
  mode: "local" | "testnet";
  chainId: number;
  chainName: string;
  rpcUrl: string;
  deploymentBlock: number;
  poolManager: Address;
  hook: Address;
  router: Address;
  redeemer: Address;
  token0: Address;
  token1: Address;
  token0Symbol: string;
  token1Symbol: string;
  token0Decimals: number;
  token1Decimals: number;
  poolFee: number;
  tickSpacing: number;
  minimumTick: number;
  maximumTick: number;
  poolId: Hex;
};

export type Runtime = {
  deployment: Deployment;
  rpcUrl: string;
  chain: Chain;
  publicClient: PublicClient;
};

export type ConnectedWallet = {
  address: Address;
  client: WalletClient;
};

const ETHEREUM_SEPOLIA_CHAIN_ID = 11_155_111;
const LOCAL_CHAIN_ID = 31_337;
const ETHEREUM_SEPOLIA_POOL_MANAGER = getAddress("0xE03A1074c86CFeDd5C142C4F04F1a1536e203543");

function requiredInteger(raw: Record<string, unknown>, key: string): number {
  const value = Number(raw[key]);
  if (!Number.isSafeInteger(value)) throw new Error(`Deployment field ${key} must be a safe integer.`);
  return value;
}

function normalizeDeployment(raw: Record<string, unknown>): Deployment {
  if (raw.mode !== "local" && raw.mode !== "testnet") throw new Error("Deployment mode must be local or testnet.");
  const mode = raw.mode;
  const schemaVersion = requiredInteger(raw, "schemaVersion");
  const chainId = requiredInteger(raw, "chainId");
  const deploymentBlock = requiredInteger(raw, "deploymentBlock");
  const token0Decimals = requiredInteger(raw, "token0Decimals");
  const token1Decimals = requiredInteger(raw, "token1Decimals");
  const poolFee = requiredInteger(raw, "poolFee");
  const tickSpacing = requiredInteger(raw, "tickSpacing");
  const minimumTick = requiredInteger(raw, "minimumTick");
  const maximumTick = requiredInteger(raw, "maximumTick");
  if (schemaVersion !== 1) throw new Error(`Unsupported deployment schema ${schemaVersion}.`);
  if (deploymentBlock < 0 || token0Decimals < 0 || token0Decimals > 255 || token1Decimals < 0 || token1Decimals > 255) {
    throw new Error("Deployment block or token decimals are invalid.");
  }
  if (mode === "local" && chainId !== LOCAL_CHAIN_ID) throw new Error("Local deployments must use chain 31337.");
  if (mode === "testnet" && chainId !== ETHEREUM_SEPOLIA_CHAIN_ID) {
    throw new Error("The judged Firstless deployment must use Ethereum Sepolia.");
  }
  const rpcOverride = mode === "testnet"
    ? import.meta.env.VITE_ETHEREUM_SEPOLIA_RPC_URL as string | undefined
    : import.meta.env.VITE_LOCAL_RPC_URL as string | undefined;
  const deployment = {
    schemaVersion,
    mode,
    chainId,
    chainName: String(raw.chainName),
    rpcUrl: rpcOverride || String(raw.rpcUrl),
    deploymentBlock,
    poolManager: getAddress(String(raw.poolManager)),
    hook: getAddress(String(raw.hook)),
    router: getAddress(String(raw.router)),
    redeemer: getAddress(String(raw.redeemer)),
    token0: getAddress(String(raw.token0)),
    token1: getAddress(String(raw.token1)),
    token0Symbol: String(raw.token0Symbol),
    token1Symbol: String(raw.token1Symbol),
    token0Decimals,
    token1Decimals,
    poolFee,
    tickSpacing,
    minimumTick,
    maximumTick,
    poolId: String(raw.poolId) as Hex,
  } satisfies Deployment;
  if (!/^0x[0-9a-fA-F]{64}$/.test(deployment.poolId)) throw new Error("Deployment poolId must be bytes32.");
  if (deployment.token0 === deployment.token1 || BigInt(deployment.token0) >= BigInt(deployment.token1)) {
    throw new Error("Deployment currencies must be distinct and sorted.");
  }
  if (mode === "testnet" && deployment.poolManager !== ETHEREUM_SEPOLIA_POOL_MANAGER) {
    throw new Error("Deployment does not use Ethereum Sepolia's canonical v4 PoolManager.");
  }
  return deployment;
}

export async function loadRuntime(): Promise<Runtime> {
  const deploymentPath = (import.meta.env.VITE_DEPLOYMENT_PATH as string | undefined) || "/deployments/local.json";
  const response = await fetch(deploymentPath, { cache: "no-store" });
  if (!response.ok) throw new Error("Firstless deployment not found. Start it with npm run contracts:dev.");
  const deployment = normalizeDeployment(await response.json() as Record<string, unknown>);
  const chain = defineChain({
    id: deployment.chainId,
    name: deployment.chainName,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [deployment.rpcUrl] } },
  });
  const publicClient = createPublicClient({ chain, transport: http(deployment.rpcUrl) });
  const actualChain = await publicClient.getChainId();
  if (actualChain !== deployment.chainId) {
    throw new Error(`Deployment expects chain ${deployment.chainId}, but RPC returned ${actualChain}.`);
  }
  const codes = await Promise.all([
    publicClient.getCode({ address: deployment.poolManager }),
    publicClient.getCode({ address: deployment.hook }),
    publicClient.getCode({ address: deployment.router }),
    publicClient.getCode({ address: deployment.redeemer }),
  ]);
  if (codes.some((code) => !code || code === "0x")) throw new Error("Deployment file is stale: one or more contracts have no code.");
  const [hookManager, trustedRouter, routerManager, redeemerManager, decimals0, decimals1] = await Promise.all([
    publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "poolManager" }),
    publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "trustedRouter" }),
    publicClient.readContract({ address: deployment.router, abi: routerAbi, functionName: "poolManager" }),
    publicClient.readContract({ address: deployment.redeemer, abi: redeemerAbi, functionName: "poolManager" }),
    publicClient.readContract({ address: deployment.token0, abi: erc20Abi, functionName: "decimals" }),
    publicClient.readContract({ address: deployment.token1, abi: erc20Abi, functionName: "decimals" }),
  ]);
  if (hookManager !== deployment.poolManager || routerManager !== deployment.poolManager || redeemerManager !== deployment.poolManager) {
    throw new Error("Deployment contracts disagree on the PoolManager.");
  }
  if (trustedRouter !== deployment.router) throw new Error("Deployment hook does not trust the configured router.");
  if (decimals0 !== deployment.token0Decimals || decimals1 !== deployment.token1Decimals) {
    throw new Error("Deployment token decimals do not match the onchain contracts.");
  }
  return { deployment, rpcUrl: deployment.rpcUrl, chain, publicClient };
}

export async function sendFunction(
  runtime: Runtime,
  wallet: ConnectedWallet,
  address: Address,
  abi: Abi,
  functionName: string,
  args: readonly unknown[] = [],
): Promise<Hash> {
  const data = encodeFunctionData({ abi, functionName, args } as never);
  const hash = await wallet.client.sendTransaction({
    account: wallet.address,
    chain: runtime.chain,
    to: address,
    data,
  });
  const receipt = await runtime.publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`Transaction ${hash} reverted.`);
  return hash;
}

export function currencyId(currency: Address): bigint {
  return BigInt(currency);
}

export function shortAddress(address: Address): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

export function errorMessage(error: unknown): string {
  if (error instanceof Error) {
    const detail = error.message.split("\n")[0];
    return detail.replace(/^.*?Details:\s*/i, "");
  }
  return String(error);
}
