import {
  createPublicClient,
  defineChain,
  encodeAbiParameters,
  encodeFunctionData,
  getAddress,
  http,
  keccak256,
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
  firstlessSepoliaTokenAbi,
  poolManagerAbi,
} from "@/generated/contracts";

export const hookAbi = firstlessHookAbi;
export const routerAbi = firstlessRouterAbi;
export const erc20Abi = firstlessDevTokenAbi;
export const testnetTokenAbi = firstlessSepoliaTokenAbi;
export const redeemerAbi = firstlessRefundRedeemerAbi;
export { poolManagerAbi };

export type Deployment = {
  schemaVersion: number;
  mode: "local" | "testnet";
  chainId: number;
  chainName: string;
  rpcUrl: string;
  explorerUrl?: string;
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
  feeNumerator: number;
  feeDenominator: number;
  outputCapBps: number;
  poolFee: number;
  tickSpacing: number;
  minimumTick: number;
  maximumTick: number;
  poolId: Hex;
  runtimeCodeHashes?: {
    hook: Hex;
    router: Hex;
    redeemer: Hex;
    token0: Hex;
    token1: Hex;
  };
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
const UNICHAIN_SEPOLIA_CHAIN_ID = 1_301;
const LOCAL_CHAIN_ID = 31_337;
const ETHEREUM_SEPOLIA_POOL_MANAGER = getAddress("0xE03A1074c86CFeDd5C142C4F04F1a1536e203543");
const ETHEREUM_SEPOLIA_EXPLORER = "https://sepolia.etherscan.io";
const UNICHAIN_SEPOLIA_POOL_MANAGER = getAddress("0x00B036B58a818B1BC34d502D3fE730Db729e62AC");
const UNICHAIN_SEPOLIA_EXPLORER = "https://sepolia.uniscan.xyz";
const DYNAMIC_FEE_FLAG = 0x80_0000;

const TESTNETS = {
  [ETHEREUM_SEPOLIA_CHAIN_ID]: {
    poolManager: ETHEREUM_SEPOLIA_POOL_MANAGER,
    explorerUrl: ETHEREUM_SEPOLIA_EXPLORER,
  },
  [UNICHAIN_SEPOLIA_CHAIN_ID]: {
    poolManager: UNICHAIN_SEPOLIA_POOL_MANAGER,
    explorerUrl: UNICHAIN_SEPOLIA_EXPLORER,
  },
} as const;

function requiredInteger(raw: Record<string, unknown>, key: string): number {
  const value = Number(raw[key]);
  if (!Number.isSafeInteger(value)) throw new Error(`Deployment field ${key} must be a safe integer.`);
  return value;
}

function requiredBytes32(value: unknown, label: string): Hex {
  const normalized = String(value);
  if (!/^0x[0-9a-fA-F]{64}$/.test(normalized)) throw new Error(`${label} must be bytes32.`);
  return normalized as Hex;
}

function normalizeDeployment(raw: Record<string, unknown>): Deployment {
  if (raw.mode !== "local" && raw.mode !== "testnet") throw new Error("Deployment mode must be local or testnet.");
  const mode = raw.mode;
  const schemaVersion = requiredInteger(raw, "schemaVersion");
  const chainId = requiredInteger(raw, "chainId");
  const deploymentBlock = requiredInteger(raw, "deploymentBlock");
  const token0Decimals = requiredInteger(raw, "token0Decimals");
  const token1Decimals = requiredInteger(raw, "token1Decimals");
  const feeNumerator = requiredInteger(raw, "feeNumerator");
  const feeDenominator = requiredInteger(raw, "feeDenominator");
  const outputCapBps = requiredInteger(raw, "outputCapBps");
  const poolFee = requiredInteger(raw, "poolFee");
  const tickSpacing = requiredInteger(raw, "tickSpacing");
  const minimumTick = requiredInteger(raw, "minimumTick");
  const maximumTick = requiredInteger(raw, "maximumTick");
  if (schemaVersion !== 1) throw new Error(`Unsupported deployment schema ${schemaVersion}.`);
  if (deploymentBlock < 0 || token0Decimals < 0 || token0Decimals > 255 || token1Decimals < 0 || token1Decimals > 255) {
    throw new Error("Deployment block or token decimals are invalid.");
  }
  if (feeNumerator <= 0 || feeNumerator > feeDenominator || outputCapBps <= 0 || outputCapBps >= 10_000) {
    throw new Error("Deployment fee or output-cap parameters are invalid.");
  }
  if (poolFee !== DYNAMIC_FEE_FLAG || tickSpacing <= 0 || minimumTick >= maximumTick) {
    throw new Error("Deployment pool parameters are invalid.");
  }
  if (mode === "local" && chainId !== LOCAL_CHAIN_ID) throw new Error("Local deployments must use chain 31337.");
  const testnet = TESTNETS[chainId as keyof typeof TESTNETS];
  if (mode === "testnet" && !testnet) {
    throw new Error(`Firstless does not recognize testnet chain ${chainId}.`);
  }
  const rpcOverride = mode === "local"
    ? import.meta.env.VITE_LOCAL_RPC_URL as string | undefined
    : chainId === UNICHAIN_SEPOLIA_CHAIN_ID
      ? import.meta.env.VITE_UNICHAIN_SEPOLIA_RPC_URL as string | undefined
      : import.meta.env.VITE_ETHEREUM_SEPOLIA_RPC_URL as string | undefined;
  const chainName = String(raw.chainName || "").trim();
  const rpcUrl = (rpcOverride || String(raw.rpcUrl || "")).trim();
  const token0Symbol = String(raw.token0Symbol || "").trim();
  const token1Symbol = String(raw.token1Symbol || "").trim();
  if (!chainName || !token0Symbol || !token1Symbol) throw new Error("Deployment names and token symbols are required.");
  if (!/^https?:\/\//.test(rpcUrl)) throw new Error("Deployment RPC URL is invalid.");
  const rawCodeHashes = raw.runtimeCodeHashes;
  const runtimeCodeHashes = mode === "testnet"
    ? (() => {
        if (!rawCodeHashes || typeof rawCodeHashes !== "object" || Array.isArray(rawCodeHashes)) {
          throw new Error("The public deployment must pin owned runtime code hashes.");
        }
        const hashes = rawCodeHashes as Record<string, unknown>;
        return {
          hook: requiredBytes32(hashes.hook, "Hook runtime code hash"),
          router: requiredBytes32(hashes.router, "Router runtime code hash"),
          redeemer: requiredBytes32(hashes.redeemer, "Redeemer runtime code hash"),
          token0: requiredBytes32(hashes.token0, "Token 0 runtime code hash"),
          token1: requiredBytes32(hashes.token1, "Token 1 runtime code hash"),
        };
      })()
    : undefined;
  const deployment = {
    schemaVersion,
    mode,
    chainId,
    chainName,
    rpcUrl,
    explorerUrl: mode === "testnet"
      ? String(raw.explorerUrl || testnet?.explorerUrl || "").replace(/\/$/, "")
      : undefined,
    deploymentBlock,
    poolManager: getAddress(String(raw.poolManager)),
    hook: getAddress(String(raw.hook)),
    router: getAddress(String(raw.router)),
    redeemer: getAddress(String(raw.redeemer)),
    token0: getAddress(String(raw.token0)),
    token1: getAddress(String(raw.token1)),
    token0Symbol,
    token1Symbol,
    token0Decimals,
    token1Decimals,
    feeNumerator,
    feeDenominator,
    outputCapBps,
    poolFee,
    tickSpacing,
    minimumTick,
    maximumTick,
    poolId: requiredBytes32(raw.poolId, "Deployment poolId"),
    runtimeCodeHashes,
  } satisfies Deployment;
  if (deployment.token0 === deployment.token1 || BigInt(deployment.token0) >= BigInt(deployment.token1)) {
    throw new Error("Deployment currencies must be distinct and sorted.");
  }
  if (mode === "testnet" && deployment.poolManager !== testnet?.poolManager) {
    throw new Error(`Deployment does not use ${deployment.chainName}'s canonical v4 PoolManager.`);
  }
  if (mode === "testnet" && deployment.explorerUrl !== testnet?.explorerUrl) {
    throw new Error(`Deployment explorer does not match ${deployment.chainName}.`);
  }
  return deployment;
}

export async function loadRuntime(): Promise<Runtime> {
  const deploymentPath = (import.meta.env.VITE_DEPLOYMENT_PATH as string | undefined) || "/deployments/local.json";
  const response = await fetch(deploymentPath, { cache: "no-store" });
  if (!response.ok) throw new Error(`Firstless deployment manifest could not be loaded (${deploymentPath}).`);
  const deployment = normalizeDeployment(await response.json() as Record<string, unknown>);
  const chain = defineChain({
    id: deployment.chainId,
    name: deployment.chainName,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [deployment.rpcUrl] } },
  });
  // Public RPCs often throttle a burst of independent browser requests. Batch
  // reads into one JSON-RPC request and retry transient failures so deployment
  // verification is reliable without weakening any of the bytecode checks.
  const publicClient = createPublicClient({
    chain,
    transport: http(deployment.rpcUrl, {
      batch: { batchSize: 50, wait: 16 },
      retryCount: 5,
      retryDelay: 500,
      timeout: 20_000,
    }),
  });
  const actualChain = await publicClient.getChainId();
  if (actualChain !== deployment.chainId) {
    throw new Error(`Deployment expects chain ${deployment.chainId}, but RPC returned ${actualChain}.`);
  }
  const codes = await Promise.all([
    publicClient.getCode({ address: deployment.poolManager }),
    publicClient.getCode({ address: deployment.hook }),
    publicClient.getCode({ address: deployment.router }),
    publicClient.getCode({ address: deployment.redeemer }),
    publicClient.getCode({ address: deployment.token0 }),
    publicClient.getCode({ address: deployment.token1 }),
  ]);
  if (codes.some((code) => !code || code === "0x")) throw new Error("Deployment file is stale: one or more contracts have no code.");
  const checkedCodes = codes as Hex[];
  if (deployment.runtimeCodeHashes) {
    const actualHashes = {
      hook: keccak256(checkedCodes[1]),
      router: keccak256(checkedCodes[2]),
      redeemer: keccak256(checkedCodes[3]),
      token0: keccak256(checkedCodes[4]),
      token1: keccak256(checkedCodes[5]),
    };
    if (Object.entries(deployment.runtimeCodeHashes).some(([name, expected]) => actualHashes[name as keyof typeof actualHashes] !== expected)) {
      throw new Error("Deployment runtime bytecode does not match the reviewed testnet release.");
    }
  }
  const [hookManager, trustedRouter, routerManager, redeemerManager, decimals0, decimals1, poolKey, feeNumerator, feeDenominator, capBps] = await Promise.all([
    publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "poolManager" }),
    publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "trustedRouter" }),
    publicClient.readContract({ address: deployment.router, abi: routerAbi, functionName: "poolManager" }),
    publicClient.readContract({ address: deployment.redeemer, abi: redeemerAbi, functionName: "poolManager" }),
    publicClient.readContract({ address: deployment.token0, abi: erc20Abi, functionName: "decimals" }),
    publicClient.readContract({ address: deployment.token1, abi: erc20Abi, functionName: "decimals" }),
    publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "poolKey" }),
    publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "feeNumerator" }),
    publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "feeDenominator" }),
    publicClient.readContract({ address: deployment.hook, abi: hookAbi, functionName: "capBps" }),
  ]);
  if (hookManager !== deployment.poolManager || routerManager !== deployment.poolManager || redeemerManager !== deployment.poolManager) {
    throw new Error("Deployment contracts disagree on the PoolManager.");
  }
  if (trustedRouter !== deployment.router) throw new Error("Deployment hook does not trust the configured router.");
  if (decimals0 !== deployment.token0Decimals || decimals1 !== deployment.token1Decimals) {
    throw new Error("Deployment token decimals do not match the onchain contracts.");
  }
  if (
    poolKey.currency0 !== deployment.token0
    || poolKey.currency1 !== deployment.token1
    || poolKey.fee !== deployment.poolFee
    || poolKey.tickSpacing !== deployment.tickSpacing
    || poolKey.hooks !== deployment.hook
  ) {
    throw new Error("Deployment pool key does not match the hook's initialized pool.");
  }
  if (
    feeNumerator !== BigInt(deployment.feeNumerator)
    || feeDenominator !== BigInt(deployment.feeDenominator)
    || capBps !== BigInt(deployment.outputCapBps)
  ) {
    throw new Error("Deployment clearing parameters do not match the hook.");
  }
  const computedPoolId = keccak256(encodeAbiParameters(
    [
      { type: "address" },
      { type: "address" },
      { type: "uint24" },
      { type: "int24" },
      { type: "address" },
    ],
    [deployment.token0, deployment.token1, deployment.poolFee, deployment.tickSpacing, deployment.hook],
  ));
  if (computedPoolId !== deployment.poolId) throw new Error("Deployment pool ID does not match its pool key.");
  return { deployment, rpcUrl: deployment.rpcUrl, chain, publicClient };
}

export async function sendFunction(
  runtime: Runtime,
  wallet: ConnectedWallet,
  address: Address,
  abi: Abi,
  functionName: string,
  args: readonly unknown[] = [],
  onSubmitted?: (hash: Hash) => void,
): Promise<Hash> {
  const data = encodeFunctionData({ abi, functionName, args } as never);
  const hash = await wallet.client.sendTransaction({
    account: wallet.address,
    chain: runtime.chain,
    to: address,
    data,
  });
  onSubmitted?.(hash);
  const receipt = await runtime.publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`Transaction ${hash} reverted.`);
  const canonicalDeadline = Date.now() + 30_000;
  while (await runtime.publicClient.getBlockNumber() < receipt.blockNumber) {
    if (Date.now() >= canonicalDeadline) {
      throw new Error(`Transaction ${hash} was preconfirmed but its canonical block did not arrive in time.`);
    }
    await new Promise((resolve) => window.setTimeout(resolve, 250));
  }
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
