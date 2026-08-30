import { useCallback, useEffect, useMemo, useState } from "react";
import ArrowLeft from "lucide-react/dist/esm/icons/arrow-left.mjs";
import ArrowRight from "lucide-react/dist/esm/icons/arrow-right.mjs";
import Check from "lucide-react/dist/esm/icons/check.mjs";
import CircleDollarSign from "lucide-react/dist/esm/icons/circle-dollar-sign.mjs";
import Clock3 from "lucide-react/dist/esm/icons/clock-3.mjs";
import Droplets from "lucide-react/dist/esm/icons/droplets.mjs";
import ExternalLink from "lucide-react/dist/esm/icons/external-link.mjs";
import History from "lucide-react/dist/esm/icons/history.mjs";
import LayoutDashboard from "lucide-react/dist/esm/icons/layout-dashboard.mjs";
import LoaderCircle from "lucide-react/dist/esm/icons/loader-circle.mjs";
import RefreshCcw from "lucide-react/dist/esm/icons/refresh-ccw.mjs";
import Wallet from "lucide-react/dist/esm/icons/wallet.mjs";
import {
  formatUnits,
  keccak256,
  parseUnits,
  zeroAddress,
  zeroHash,
  type Address,
  type Hex,
} from "viem";
import {
  useConnect,
  useConnection,
  useConnectors,
  useDisconnect,
  useSwitchChain,
  useWalletClient,
  type Connector,
} from "wagmi";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Separator } from "@/components/ui/separator";
import { Brand } from "@/components/Brand";
import { ClearingStation } from "@/components/ClearingStation";
import {
  currencyId,
  erc20Abi,
  errorMessage,
  hookAbi,
  loadRuntime,
  poolManagerAbi,
  redeemerAbi,
  routerAbi,
  sendFunction,
  shortAddress,
  type ConnectedWallet,
  type Runtime,
} from "@/lib/firstless";

type DashboardPageProps = {
  onBack: () => void;
};

type Section = "trade" | "liquidity" | "refunds" | "activity";

type UserOrder = {
  id: bigint;
  epochId: bigint;
  amountOut: bigint;
  maximumInput: bigint;
  tokenOut0: boolean;
  settled: boolean;
  claimed: boolean;
  refund: bigint;
};

type PendingDeposit = {
  id: bigint;
  queuedAt: bigint;
  amount0: bigint;
  amount1: bigint;
};

type Activity = {
  key: string;
  block: bigint;
  title: string;
  detail: string;
  hash?: Hex;
};

type Snapshot = {
  blockNumber: bigint;
  reserve0: bigint;
  reserve1: bigint;
  fee0: bigint;
  fee1: bigint;
  liability0: bigint;
  liability1: bigint;
  pending0: bigint;
  pending1: bigint;
  epochId: bigint;
  openedAt: bigint;
  ordersInSet: bigint;
  wallet0: bigint;
  wallet1: bigint;
  lpBalance: bigint;
  lpSupply: bigint;
  claim0: bigint;
  claim1: bigint;
  orders: UserOrder[];
  deposits: PendingDeposit[];
  activities: Activity[];
};

const emptySnapshot: Snapshot = {
  blockNumber: 0n,
  reserve0: 0n,
  reserve1: 0n,
  fee0: 0n,
  fee1: 0n,
  liability0: 0n,
  liability1: 0n,
  pending0: 0n,
  pending1: 0n,
  epochId: 0n,
  openedAt: 0n,
  ordersInSet: 0n,
  wallet0: 0n,
  wallet1: 0n,
  lpBalance: 0n,
  lpSupply: 0n,
  claim0: 0n,
  claim1: 0n,
  orders: [],
  deposits: [],
  activities: [],
};

const creditOrderTypes = {
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
} as const;

function amount(value: bigint, decimals = 18, maximumFractionDigits = 4): string {
  const parsed = Number(formatUnits(value, decimals));
  if (!Number.isFinite(parsed)) return formatUnits(value, decimals);
  return new Intl.NumberFormat("en-US", { maximumFractionDigits }).format(parsed);
}

function shortHash(hash: Hex): string {
  return `${hash.slice(0, 8)}…${hash.slice(-6)}`;
}

async function readSnapshot(runtime: Runtime, account?: Address): Promise<Snapshot> {
  const { deployment: d, publicClient } = runtime;
  const blockNumber = await publicClient.getBlockNumber();
  const accountOrZero = account || zeroAddress;
  const [
    reserve0,
    reserve1,
    fee0,
    fee1,
    liability0,
    liability1,
    pending0,
    pending1,
    epochId,
    epoch,
    wallet0,
    wallet1,
    lpBalance,
    lpSupply,
    claim0,
    claim1,
  ] = await Promise.all([
    publicClient.readContract({ address: d.hook, abi: hookAbi, functionName: "logicalReserve0" }),
    publicClient.readContract({ address: d.hook, abi: hookAbi, functionName: "logicalReserve1" }),
    publicClient.readContract({ address: d.hook, abi: hookAbi, functionName: "feeBucket0" }),
    publicClient.readContract({ address: d.hook, abi: hookAbi, functionName: "feeBucket1" }),
    publicClient.readContract({ address: d.hook, abi: hookAbi, functionName: "refundLiability0" }),
    publicClient.readContract({ address: d.hook, abi: hookAbi, functionName: "refundLiability1" }),
    publicClient.readContract({ address: d.hook, abi: hookAbi, functionName: "pendingDeposit0" }),
    publicClient.readContract({ address: d.hook, abi: hookAbi, functionName: "pendingDeposit1" }),
    publicClient.readContract({ address: d.hook, abi: hookAbi, functionName: "currentEpochId" }),
    publicClient.readContract({ address: d.hook, abi: hookAbi, functionName: "currentEpoch" }),
    publicClient.readContract({ address: d.token0, abi: erc20Abi, functionName: "balanceOf", args: [accountOrZero] }),
    publicClient.readContract({ address: d.token1, abi: erc20Abi, functionName: "balanceOf", args: [accountOrZero] }),
    publicClient.readContract({ address: d.hook, abi: hookAbi, functionName: "balanceOf", args: [accountOrZero] }),
    publicClient.readContract({ address: d.hook, abi: hookAbi, functionName: "totalSupply" }),
    publicClient.readContract({
      address: d.poolManager,
      abi: poolManagerAbi,
      functionName: "balanceOf",
      args: [accountOrZero, currencyId(d.token0)],
    }),
    publicClient.readContract({
      address: d.poolManager,
      abi: poolManagerAbi,
      functionName: "balanceOf",
      args: [accountOrZero, currencyId(d.token1)],
    }),
  ]);

  let orders: UserOrder[] = [];
  let deposits: PendingDeposit[] = [];
  const activities: Activity[] = [];

  if (account) {
    const [orderLogs, depositLogs, settledLogs, refundLogs, activationLogs, cancellationLogs, burnLogs] = await Promise.all([
      publicClient.getContractEvents({
        address: d.hook,
        abi: hookAbi,
        eventName: "CreditOrderPlaced",
        args: { refundOwner: account },
        fromBlock: BigInt(d.deploymentBlock),
        toBlock: "latest",
      }),
      publicClient.getContractEvents({
        address: d.hook,
        abi: hookAbi,
        eventName: "DepositQueued",
        args: { provider: account },
        fromBlock: BigInt(d.deploymentBlock),
        toBlock: "latest",
      }),
      publicClient.getContractEvents({
        address: d.hook,
        abi: hookAbi,
        eventName: "EpochSettled",
        fromBlock: BigInt(d.deploymentBlock),
        toBlock: "latest",
      }),
      publicClient.getContractEvents({
        address: d.hook,
        abi: hookAbi,
        eventName: "RefundClaimed",
        args: { owner: account },
        fromBlock: BigInt(d.deploymentBlock),
        toBlock: "latest",
      }),
      publicClient.getContractEvents({
        address: d.hook,
        abi: hookAbi,
        eventName: "DepositActivated",
        args: { provider: account },
        fromBlock: BigInt(d.deploymentBlock),
        toBlock: "latest",
      }),
      publicClient.getContractEvents({
        address: d.hook,
        abi: hookAbi,
        eventName: "DepositCancelled",
        args: { provider: account },
        fromBlock: BigInt(d.deploymentBlock),
        toBlock: "latest",
      }),
      publicClient.getContractEvents({
        address: d.hook,
        abi: hookAbi,
        eventName: "Transfer",
        args: { from: account, to: zeroAddress },
        fromBlock: BigInt(d.deploymentBlock),
        toBlock: "latest",
      }),
    ]);

    orders = await Promise.all(orderLogs.map(async (log) => {
      const id = log.args.orderId!;
      const stored = await publicClient.readContract({ address: d.hook, abi: hookAbi, functionName: "orders", args: [id] });
      const settlement = await publicClient.readContract({
        address: d.hook,
        abi: hookAbi,
        functionName: "settlements",
        args: [stored[1]],
      });
      let refund = 0n;
      if (settlement[8] && !stored[5]) {
        try {
          const simulation = await publicClient.simulateContract({
            account,
            address: d.hook,
            abi: hookAbi,
            functionName: "claimRefund",
            args: [id],
          });
          refund = simulation.result;
        } catch {
          refund = 0n;
        }
      }
      activities.push({
        key: `order-${id}`,
        block: log.blockNumber,
        title: `Order #${id}`,
        detail: `${amount(stored[2], stored[4] ? d.token0Decimals : d.token1Decimals)} ${stored[4] ? d.token0Symbol : d.token1Symbol} delivered`,
        hash: log.transactionHash,
      });
      return {
        id,
        epochId: stored[1],
        amountOut: stored[2],
        maximumInput: stored[3],
        tokenOut0: stored[4],
        settled: settlement[8],
        claimed: stored[5],
        refund,
      };
    }));

    const pendingRows = await Promise.all(depositLogs.map(async (log) => {
      const id = log.args.depositId!;
      const stored = await publicClient.readContract({
        address: d.hook,
        abi: hookAbi,
        functionName: "pendingLiquidity",
        args: [id],
      });
      activities.push({
        key: `deposit-${id}`,
        block: log.blockNumber,
        title: `Deposit #${id} queued`,
        detail: `${amount(log.args.amount0!, d.token0Decimals)} ${d.token0Symbol} + ${amount(log.args.amount1!, d.token1Decimals)} ${d.token1Symbol}`,
        hash: log.transactionHash,
      });
      return stored[0] === zeroAddress ? null : { id, queuedAt: stored[1], amount0: stored[2], amount1: stored[3] };
    }));
    deposits = pendingRows.filter((row): row is PendingDeposit => row !== null);

    settledLogs.forEach((log) => activities.push({
      key: `settled-${log.args.epochId}-${log.logIndex}`,
      block: log.blockNumber,
      title: `Set #${log.args.epochId} settled`,
      detail: `${amount(log.args.output0!, d.token0Decimals)} ${d.token0Symbol} / ${amount(log.args.output1!, d.token1Decimals)} ${d.token1Symbol} output`,
      hash: log.transactionHash,
    }));
    refundLogs.forEach((log) => {
      const order = orders.find((candidate) => candidate.id === log.args.orderId);
      const tokenOut0 = order?.tokenOut0 ?? false;
      const decimals = tokenOut0 ? d.token1Decimals : d.token0Decimals;
      const symbol = tokenOut0 ? d.token1Symbol : d.token0Symbol;
      activities.push({
        key: `refund-${log.args.orderId}-${log.logIndex}`,
        block: log.blockNumber,
        title: `Order #${log.args.orderId} refund claimed`,
        detail: `${amount(log.args.refund!, decimals)} ${symbol} in PoolManager claims`,
        hash: log.transactionHash,
      });
    });
    activationLogs.forEach((log) => activities.push({
      key: `activated-${log.args.depositId}-${log.logIndex}`,
      block: log.blockNumber,
      title: `Deposit #${log.args.depositId} activated`,
      detail: `${amount(log.args.shares!)} FIRST-LP minted`,
      hash: log.transactionHash,
    }));
    cancellationLogs.forEach((log) => activities.push({
      key: `cancelled-${log.args.depositId}-${log.logIndex}`,
      block: log.blockNumber,
      title: `Deposit #${log.args.depositId} cancelled`,
      detail: `${amount(log.args.amount0!, d.token0Decimals)} ${d.token0Symbol} + ${amount(log.args.amount1!, d.token1Decimals)} ${d.token1Symbol} returned`,
      hash: log.transactionHash,
    }));
    burnLogs.forEach((log) => activities.push({
      key: `burn-${log.transactionHash}-${log.logIndex}`,
      block: log.blockNumber,
      title: "Active liquidity withdrawn",
      detail: `${amount(log.args.value!)} FIRST-LP burned`,
      hash: log.transactionHash,
    }));
  }

  activities.sort((a, b) => Number(b.block - a.block));
  return {
    blockNumber,
    reserve0,
    reserve1,
    fee0,
    fee1,
    liability0,
    liability1,
    pending0,
    pending1,
    epochId,
    openedAt: epoch[0],
    ordersInSet: epoch[1] + epoch[2],
    wallet0,
    wallet1,
    lpBalance,
    lpSupply,
    claim0,
    claim1,
    orders: orders.sort((a, b) => Number(b.id - a.id)),
    deposits,
    activities: activities.slice(0, 16),
  };
}

export function DashboardPage({ onBack }: DashboardPageProps) {
  const [section, setSection] = useState<Section>("trade");
  const [runtime, setRuntime] = useState<Runtime>();
  const [runtimeError, setRuntimeError] = useState<string>();
  const [snapshot, setSnapshot] = useState<Snapshot>(emptySnapshot);
  const [amountOut, setAmountOut] = useState("10");
  const [tokenOut0, setTokenOut0] = useState(false);
  const [maximumInput, setMaximumInput] = useState<bigint>();
  const [lp0, setLp0] = useState("100");
  const [lp1, setLp1] = useState("100");
  const [removeAmount, setRemoveAmount] = useState("10");
  const [busy, setBusy] = useState<string>();
  const [notice, setNotice] = useState<string>();
  const [actionError, setActionError] = useState<string>();
  const [showWallets, setShowWallets] = useState(false);

  const connection = useConnection();
  const connectors = useConnectors();
  const connect = useConnect();
  const disconnect = useDisconnect();
  const switchChain = useSwitchChain();
  const desiredChainId = runtime?.deployment.chainId as 31_337 | 11_155_111 | undefined;
  const walletQuery = useWalletClient({ chainId: desiredChainId });

  const refresh = useCallback(async (nextRuntime = runtime) => {
    if (!nextRuntime) return;
    try {
      setSnapshot(await readSnapshot(nextRuntime, connection.address));
      setRuntimeError(undefined);
    } catch (error) {
      setRuntimeError(errorMessage(error));
    }
  }, [connection.address, runtime]);

  useEffect(() => {
    let cancelled = false;
    loadRuntime()
      .then((loaded) => {
        if (cancelled) return;
        setRuntime(loaded);
        return readSnapshot(loaded, connection.address);
      })
      .then((next) => {
        if (!cancelled && next) setSnapshot(next);
      })
      .catch((error) => {
        if (!cancelled) setRuntimeError(errorMessage(error));
      });
    return () => { cancelled = true; };
  }, [connection.address]);

  useEffect(() => {
    if (!runtime) return;
    const interval = window.setInterval(() => void refresh(runtime), 4_000);
    return () => window.clearInterval(interval);
  }, [refresh, runtime]);

  useEffect(() => {
    if (!runtime) return;
    let cancelled = false;
    const parsed = (() => {
      try {
        return parseUnits(amountOut || "0", tokenOut0 ? runtime.deployment.token0Decimals : runtime.deployment.token1Decimals);
      } catch {
        return 0n;
      }
    })();
    if (parsed === 0n) {
      setMaximumInput(undefined);
      return;
    }
    runtime.publicClient.readContract({
      address: runtime.deployment.hook,
      abi: hookAbi,
      functionName: "requiredMaximumInput",
      args: [tokenOut0, parsed],
    }).then((quote) => {
      if (!cancelled) setMaximumInput(quote);
    }).catch(() => {
      if (!cancelled) setMaximumInput(undefined);
    });
    return () => { cancelled = true; };
  }, [amountOut, runtime, tokenOut0, snapshot.reserve0, snapshot.reserve1]);

  const deployment = runtime?.deployment;
  const connectedOnTarget = Boolean(connection.address && desiredChainId && connection.chainId === desiredChainId);
  const wallet = useMemo<ConnectedWallet | undefined>(() => {
    if (!connection.address || !walletQuery.data || !connectedOnTarget) return undefined;
    return { address: connection.address, client: walletQuery.data };
  }, [connectedOnTarget, connection.address, walletQuery.data]);

  const runAction = async (label: string, task: () => Promise<void>) => {
    setBusy(label);
    setActionError(undefined);
    setNotice(undefined);
    try {
      await task();
      setNotice(`${label} confirmed onchain.`);
      await refresh();
    } catch (error) {
      setActionError(errorMessage(error));
    } finally {
      setBusy(undefined);
    }
  };

  const requireWallet = (): [Runtime, ConnectedWallet] => {
    if (!runtime) throw new Error("The deployment is not ready.");
    if (!wallet) throw new Error("Connect a wallet on the configured chain first.");
    return [runtime, wallet];
  };

  const approveIfNeeded = async (token: Address, spender: Address, needed: bigint) => {
    const [activeRuntime, activeWallet] = requireWallet();
    const allowance = await activeRuntime.publicClient.readContract({
      address: token,
      abi: erc20Abi,
      functionName: "allowance",
      args: [activeWallet.address, spender],
    });
    if (allowance < needed) {
      await sendFunction(activeRuntime, activeWallet, token, erc20Abi, "approve", [spender, needed]);
    }
  };

  const connectWith = async (connector: Connector) => {
    if (!desiredChainId) return;
    setActionError(undefined);
    try {
      await connect.mutateAsync({ connector, chainId: desiredChainId });
      setShowWallets(false);
    } catch (error) {
      setActionError(errorMessage(error));
    }
  };

  const submitTrade = () => runAction("Exact-output order", async () => {
    const [activeRuntime, activeWallet] = requireWallet();
    const d = activeRuntime.deployment;
    const outputDecimals = tokenOut0 ? d.token0Decimals : d.token1Decimals;
    const parsedOut = parseUnits(amountOut, outputDecimals);
    if (parsedOut <= 0n || !maximumInput) throw new Error("Enter an output amount inside the pool cap.");
    const inputToken = tokenOut0 ? d.token1 : d.token0;
    await approveIfNeeded(inputToken, d.router, maximumInput);

    const [nonce, currentBlock] = await Promise.all([
      activeRuntime.publicClient.readContract({ address: d.router, abi: routerAbi, functionName: "nonces", args: [activeWallet.address] }),
      activeRuntime.publicClient.getBlockNumber(),
    ]);
    const zeroForOne = !tokenOut0;
    const deadline = BigInt(Math.floor(Date.now() / 1_000) + 20 * 60);
    const order = {
      poolId: d.poolId,
      payer: activeWallet.address,
      recipient: activeWallet.address,
      callTarget: zeroAddress,
      callDataHash: keccak256("0x"),
      zeroForOne,
      amountOut: parsedOut,
      maximumInput,
      validAfter: currentBlock + 1n,
      validBefore: currentBlock + 30n,
      nonce,
      deadline,
    } as const;
    const signature = await activeWallet.client.signTypedData({
      account: activeWallet.address,
      domain: { name: "Firstless", version: "1", chainId: d.chainId, verifyingContract: d.router },
      primaryType: "CreditOrder",
      types: creditOrderTypes,
      message: order,
    });
    const key = { currency0: d.token0, currency1: d.token1, fee: d.poolFee, tickSpacing: d.tickSpacing, hooks: d.hook } as const;
    await sendFunction(activeRuntime, activeWallet, d.router, routerAbi, "execute", [key, order, signature, "0x"]);
  });

  const settle = () => runAction("Set settlement", async () => {
    const [activeRuntime, activeWallet] = requireWallet();
    await sendFunction(activeRuntime, activeWallet, activeRuntime.deployment.hook, hookAbi, "settleExpiredEpoch");
  });

  const redeemCurrencyClaims = async (activeRuntime: Runtime, activeWallet: ConnectedWallet, currency: Address) => {
    const d = activeRuntime.deployment;
    const approved = await activeRuntime.publicClient.readContract({
      address: d.poolManager,
      abi: poolManagerAbi,
      functionName: "isOperator",
      args: [activeWallet.address, d.redeemer],
    });
    if (!approved) {
      await sendFunction(activeRuntime, activeWallet, d.poolManager, poolManagerAbi, "setOperator", [d.redeemer, true]);
    }
    const claimBalance = await activeRuntime.publicClient.readContract({
      address: d.poolManager,
      abi: poolManagerAbi,
      functionName: "balanceOf",
      args: [activeWallet.address, currencyId(currency)],
    });
    if (claimBalance > 0n) {
      await sendFunction(activeRuntime, activeWallet, d.redeemer, redeemerAbi, "redeem", [currency, claimBalance, activeWallet.address]);
    }
    return claimBalance;
  };

  const claimAndRedeem = (order: UserOrder) => runAction(`Refund for order #${order.id}`, async () => {
    const [activeRuntime, activeWallet] = requireWallet();
    const d = activeRuntime.deployment;
    const currency = order.tokenOut0 ? d.token1 : d.token0;
    await sendFunction(activeRuntime, activeWallet, d.hook, hookAbi, "claimRefund", [order.id]);
    await redeemCurrencyClaims(activeRuntime, activeWallet, currency);
  });

  const redeemOutstanding = (currency: Address, symbol: string) => runAction(`${symbol} claim redemption`, async () => {
    const [activeRuntime, activeWallet] = requireWallet();
    const redeemed = await redeemCurrencyClaims(activeRuntime, activeWallet, currency);
    if (redeemed === 0n) throw new Error(`No backed ${symbol} claim remains to redeem.`);
  });

  const faucet = () => runAction("Demo tokens", async () => {
    const [activeRuntime, activeWallet] = requireWallet();
    if (activeRuntime.deployment.mode !== "local") throw new Error("The faucet exists only in the local demo.");
    const d = activeRuntime.deployment;
    await sendFunction(activeRuntime, activeWallet, d.token0, erc20Abi, "faucet", [activeWallet.address, parseUnits("1000", d.token0Decimals)]);
    await sendFunction(activeRuntime, activeWallet, d.token1, erc20Abi, "faucet", [activeWallet.address, parseUnits("1000", d.token1Decimals)]);
  });

  const addLiquidity = () => runAction("Pending liquidity deposit", async () => {
    const [activeRuntime, activeWallet] = requireWallet();
    const d = activeRuntime.deployment;
    const value0 = parseUnits(lp0, d.token0Decimals);
    const value1 = parseUnits(lp1, d.token1Decimals);
    if (value0 <= 0n || value1 <= 0n) throw new Error("Both deposit amounts must be above zero.");
    await approveIfNeeded(d.token0, d.hook, value0);
    await approveIfNeeded(d.token1, d.hook, value1);
    await sendFunction(activeRuntime, activeWallet, d.hook, hookAbi, "addLiquidity", [{
      amount0Desired: value0,
      amount1Desired: value1,
      amount0Min: 0n,
      amount1Min: 0n,
      deadline: BigInt(Math.floor(Date.now() / 1_000) + 20 * 60),
      tickLower: d.minimumTick,
      tickUpper: d.maximumTick,
      userInputSalt: zeroHash,
    }]);
  });

  const activateDeposit = (deposit: PendingDeposit) => runAction(`Deposit #${deposit.id} activation`, async () => {
    const [activeRuntime, activeWallet] = requireWallet();
    const preview = await activeRuntime.publicClient.readContract({
      address: activeRuntime.deployment.hook,
      abi: hookAbi,
      functionName: "previewPendingLiquidity",
      args: [deposit.id],
    });
    const minimumShares = preview[0] * 99n / 100n;
    await sendFunction(activeRuntime, activeWallet, activeRuntime.deployment.hook, hookAbi, "activatePendingLiquidity", [deposit.id, minimumShares]);
  });

  const cancelDeposit = (deposit: PendingDeposit) => runAction(`Deposit #${deposit.id} cancellation`, async () => {
    const [activeRuntime, activeWallet] = requireWallet();
    await sendFunction(activeRuntime, activeWallet, activeRuntime.deployment.hook, hookAbi, "cancelPendingLiquidity", [deposit.id]);
  });

  const removeLiquidity = () => runAction("LP withdrawal", async () => {
    const [activeRuntime, activeWallet] = requireWallet();
    const d = activeRuntime.deployment;
    const liquidity = parseUnits(removeAmount, 18);
    if (liquidity <= 0n || liquidity > snapshot.lpBalance) throw new Error("Enter an LP amount within your active balance.");
    if (snapshot.lpSupply === 0n) throw new Error("The active LP supply is zero.");
    const expected0 = liquidity * (snapshot.reserve0 + snapshot.fee0) / snapshot.lpSupply;
    const expected1 = liquidity * (snapshot.reserve1 + snapshot.fee1) / snapshot.lpSupply;
    await sendFunction(activeRuntime, activeWallet, d.hook, hookAbi, "removeLiquidity", [{
      liquidity,
      amount0Min: expected0 * 99n / 100n,
      amount1Min: expected1 * 99n / 100n,
      deadline: BigInt(Math.floor(Date.now() / 1_000) + 20 * 60),
      tickLower: d.minimumTick,
      tickUpper: d.maximumTick,
      userInputSalt: zeroHash,
    }]);
  });

  const inputSymbol = deployment ? (tokenOut0 ? deployment.token1Symbol : deployment.token0Symbol) : "input";
  const outputSymbol = deployment ? (tokenOut0 ? deployment.token0Symbol : deployment.token1Symbol) : "output";
  const inputDecimals = deployment ? (tokenOut0 ? deployment.token1Decimals : deployment.token0Decimals) : 18;
  const claimable = snapshot.orders.filter((order) => order.settled && !order.claimed);
  const isEpochOpen = snapshot.openedAt !== 0n;
  const canSettle = isEpochOpen && snapshot.blockNumber > snapshot.openedAt;
  const visibleConnectors = connectors.filter((connector) => deployment?.mode === "local" ? connector.type === "mock" || connector.type === "injected" : connector.type !== "mock");
  const stages = [
    ["Signed", "Limits locked"],
    ["Output sent", "Immediately usable"],
    ["Set open", "Same-block orders join"],
    ["Settlement", "Marginal bills computed"],
    ["Refund", "Unused maximum returns"],
  ];

  if (!runtime && runtimeError) {
    return (
      <main className="backend-state">
        <Brand />
        <p>Backend not running</p>
        <h1>Start the isolated Firstless local chain.</h1>
        <code>npm run contracts:dev</code>
        <span>{runtimeError}</span>
        <Button variant="outline" onClick={onBack}><ArrowLeft aria-hidden="true" /> Back to the story</Button>
      </main>
    );
  }

  return (
    <main className="dashboard-page">
      <aside className="dash-sidebar">
        <Brand />
        <nav aria-label="Dashboard navigation">
          <button className={section === "trade" ? "is-active" : ""} onClick={() => setSection("trade")}><LayoutDashboard aria-hidden="true" /><span>Trade</span></button>
          <button className={section === "liquidity" ? "is-active" : ""} onClick={() => setSection("liquidity")}><Droplets aria-hidden="true" /><span>Liquidity</span></button>
          <button className={section === "refunds" ? "is-active" : ""} onClick={() => setSection("refunds")}><CircleDollarSign aria-hidden="true" /><span>Refunds</span></button>
          <button className={section === "activity" ? "is-active" : ""} onClick={() => setSection("activity")}><History aria-hidden="true" /><span>Activity</span></button>
        </nav>
        <button className="dash-sidebar__back" onClick={onBack}><ArrowLeft aria-hidden="true" /> Back to the story</button>
      </aside>

      <section className="dash-workspace">
        <header className="dash-topbar">
          <div>
            <p>Firstless control room</p>
            <span>{deployment ? `${deployment.chainName} · block ${snapshot.blockNumber}` : "Loading deployment…"}</span>
          </div>
          <div className="dash-topbar__actions">
            {runtimeError ? <Badge className="badge-error">RPC error</Badge> : <Badge className="badge-live"><i /> Live contract state</Badge>}
            {connection.address ? (
              <div className="wallet-cluster">
                {!connectedOnTarget && desiredChainId ? <Button variant="outline" onClick={() => void switchChain.mutateAsync({ chainId: desiredChainId })}>Switch network</Button> : null}
                <Button variant="outline" onClick={() => disconnect.mutate()}><Wallet aria-hidden="true" /> {shortAddress(connection.address)}</Button>
              </div>
            ) : (
              <Button variant="outline" onClick={() => setShowWallets((value) => !value)}><Wallet aria-hidden="true" /> Connect wallet</Button>
            )}
            {showWallets && (
              <div className="wallet-menu" role="dialog" aria-label="Choose a wallet">
                {visibleConnectors.map((connector) => (
                  <button key={connector.uid} onClick={() => void connectWith(connector)}>
                    <strong>{connector.type === "mock" ? "Local demo wallet" : connector.name}</strong>
                    <span>{connector.type === "mock" ? "Unlocked Anvil account" : "Wagmi connector"}</span>
                  </button>
                ))}
              </div>
            )}
          </div>
        </header>

        <div className="dash-canvas">
          {(actionError || runtimeError) && <Alert className="dash-alert dash-alert--error"><AlertTitle>Action needs attention</AlertTitle><AlertDescription>{actionError || runtimeError}</AlertDescription></Alert>}
          {notice && <Alert className="dash-alert dash-alert--success"><Check aria-hidden="true" /><AlertTitle>Confirmed</AlertTitle><AlertDescription>{notice}</AlertDescription></Alert>}

          <section className="dash-summary" aria-label="Pool summary">
            <article><span>Active reserves</span><strong>{amount(snapshot.reserve0, deployment?.token0Decimals)} / {amount(snapshot.reserve1, deployment?.token1Decimals)}</strong><small>{deployment?.token0Symbol || "token 0"} and {deployment?.token1Symbol || "token 1"}</small></article>
            <article><span>Current set</span><strong>{isEpochOpen ? `#${snapshot.epochId}` : "Idle"}</strong><small>{isEpochOpen ? `opened in block ${snapshot.openedAt}` : "opens with the next order"}</small></article>
            <article><span>Orders in set</span><strong>{snapshot.ordersInSet.toString()}</strong><small>real hook state</small></article>
            <article><span>Refund liabilities</span><strong>{amount(snapshot.liability0, deployment?.token0Decimals)} / {amount(snapshot.liability1, deployment?.token1Decimals)}</strong><small>kept outside LP equity</small></article>
          </section>

          <div className="dash-grid">
            <section className="dash-action-column">
              {section === "trade" && (
                <Card className="dash-card trade-card">
                  <CardHeader><CardTitle>Choose what arrives</CardTitle><CardDescription>The hook quotes the actual conservative maximum. The complete block decides the final marginal bill.</CardDescription></CardHeader>
                  <CardContent>
                    <div className="token-direction">
                      <button onClick={() => setTokenOut0(false)} className={!tokenOut0 ? "is-active" : ""}>Receive {deployment?.token1Symbol || "token 1"}</button>
                      <button onClick={() => setTokenOut0(true)} className={tokenOut0 ? "is-active" : ""}>Receive {deployment?.token0Symbol || "token 0"}</button>
                    </div>
                    <div className="trade-field">
                      <div className="trade-field__label"><Label htmlFor="pay-token">Maximum held</Label><span>Balance {amount(tokenOut0 ? snapshot.wallet1 : snapshot.wallet0, inputDecimals)}</span></div>
                      <div className="trade-field__row"><div className="token-pill"><i className="token-dot token-dot--usd" /> {inputSymbol}</div><Input id="pay-token" value={maximumInput ? amount(maximumInput, inputDecimals, 8) : "—"} readOnly /></div>
                      <small>Only the final bill remains charged after settlement.</small>
                    </div>
                    <div className="trade-switch"><ArrowRight aria-hidden="true" /></div>
                    <div className="trade-field trade-field--receive">
                      <div className="trade-field__label"><Label htmlFor="receive-token">You receive exactly</Label><span>Immediate ERC-20 output</span></div>
                      <div className="trade-field__row"><div className="token-pill"><i className="token-dot token-dot--eth" /> {outputSymbol}</div><Input id="receive-token" inputMode="decimal" value={amountOut} onChange={(event) => setAmountOut(event.target.value)} /></div>
                      <small>Usable by another contract in the same transaction.</small>
                    </div>
                    <div className="quote-breakdown">
                      <div><span>Onchain maximum quote</span><strong>{maximumInput ? `${amount(maximumInput, inputDecimals, 8)} ${inputSymbol}` : "Outside current cap"}</strong></div>
                      <div><span>Set clock</span><strong>Ethereum block</strong></div>
                      <div className="quote-breakdown__refund"><span>Refund</span><strong>Known only after the set closes</strong></div>
                    </div>
                    <Button className="trade-submit" size="lg" disabled={!wallet || !maximumInput || Boolean(busy)} onClick={() => void submitTrade()}>{busy === "Exact-output order" ? <LoaderCircle className="spin" aria-hidden="true" /> : <Wallet aria-hidden="true" />} Sign and execute order</Button>
                    {deployment?.mode === "local" && <Button className="secondary-action" variant="outline" disabled={!wallet || Boolean(busy)} onClick={() => void faucet()}>Mint local demo tokens</Button>}
                  </CardContent>
                </Card>
              )}

              {section === "liquidity" && (
                <Card className="dash-card liquidity-card">
                  <CardHeader><CardTitle>Manage active liquidity</CardTitle><CardDescription>New deposits stay provider-owned and pending until a later block. They earn no earlier-set fees.</CardDescription></CardHeader>
                  <CardContent>
                    <div className="liquidity-pair"><div><Label htmlFor="lp0">{deployment?.token0Symbol || "Token 0"}</Label><Input id="lp0" value={lp0} onChange={(event) => setLp0(event.target.value)} /></div><div><Label htmlFor="lp1">{deployment?.token1Symbol || "Token 1"}</Label><Input id="lp1" value={lp1} onChange={(event) => setLp1(event.target.value)} /></div></div>
                    <Alert className="pending-alert"><Clock3 aria-hidden="true" /><AlertTitle>Pending first</AlertTitle><AlertDescription>Activate at the current LP-equity ratio in a later block, or cancel for the original underlying tokens.</AlertDescription></Alert>
                    <Button className="trade-submit" disabled={!wallet || Boolean(busy)} onClick={() => void addLiquidity()}>{busy === "Pending liquidity deposit" ? <LoaderCircle className="spin" /> : <Droplets />} Queue deposit</Button>
                    <div className="position-box"><div><span>Active LP balance</span><strong>{amount(snapshot.lpBalance)} FIRST-LP</strong></div><div className="position-box__remove"><Input value={removeAmount} onChange={(event) => setRemoveAmount(event.target.value)} aria-label="LP shares to remove" /><Button variant="outline" disabled={!wallet || isEpochOpen || Boolean(busy)} onClick={() => void removeLiquidity()}>Remove</Button></div></div>
                    <div className="pending-list">
                      {snapshot.deposits.map((deposit) => (
                        <article key={deposit.id.toString()}><div><strong>Deposit #{deposit.id}</strong><span>{amount(deposit.amount0, deployment?.token0Decimals)} {deployment?.token0Symbol} + {amount(deposit.amount1, deployment?.token1Decimals)} {deployment?.token1Symbol} · queued block {deposit.queuedAt}</span></div><div><Button size="sm" disabled={!wallet || isEpochOpen || snapshot.blockNumber <= deposit.queuedAt || Boolean(busy)} onClick={() => void activateDeposit(deposit)}>Activate</Button><Button size="sm" variant="outline" disabled={!wallet || Boolean(busy)} onClick={() => void cancelDeposit(deposit)}>Cancel</Button></div></article>
                      ))}
                      {snapshot.deposits.length === 0 && <p>No pending deposits for this wallet.</p>}
                    </div>
                  </CardContent>
                </Card>
              )}

              {section === "refunds" && (
                <Card className="dash-card refund-card">
                  <CardHeader><CardTitle>Settled refunds</CardTitle><CardDescription>Claim creates a backed PoolManager claim, then the redeemer converts it to the underlying ERC-20.</CardDescription></CardHeader>
                  <CardContent className="refund-list">
                    {deployment && snapshot.claim0 > 0n && <article><div><strong>Backed {deployment.token0Symbol} claim</strong><span>{amount(snapshot.claim0, deployment.token0Decimals)} remains in PoolManager custody</span></div><div><Button size="sm" disabled={!wallet || Boolean(busy)} onClick={() => void redeemOutstanding(deployment.token0, deployment.token0Symbol)}>Redeem underlying</Button></div></article>}
                    {deployment && snapshot.claim1 > 0n && <article><div><strong>Backed {deployment.token1Symbol} claim</strong><span>{amount(snapshot.claim1, deployment.token1Decimals)} remains in PoolManager custody</span></div><div><Button size="sm" disabled={!wallet || Boolean(busy)} onClick={() => void redeemOutstanding(deployment.token1, deployment.token1Symbol)}>Redeem underlying</Button></div></article>}
                    {snapshot.orders.map((order) => {
                      const input = order.tokenOut0 ? deployment?.token1Symbol : deployment?.token0Symbol;
                      const decimals = order.tokenOut0 ? deployment?.token1Decimals : deployment?.token0Decimals;
                      return <article key={order.id.toString()}><div><strong>Order #{order.id}</strong><span>Set #{order.epochId} · max {amount(order.maximumInput, decimals)} {input}</span></div><div><b>{order.claimed ? "Claimed from hook" : order.settled ? `${amount(order.refund, decimals)} ${input}` : "Set open"}</b>{order.settled && !order.claimed && <Button size="sm" disabled={!wallet || Boolean(busy)} onClick={() => void claimAndRedeem(order)}>Claim + redeem</Button>}</div></article>;
                    })}
                    {snapshot.orders.length === 0 && <div className="refund-empty"><div className="refund-empty__icon"><RefreshCcw /></div><h3>No orders for this wallet</h3><p>Execute a real exact-output order, settle its set, then the refund action appears here.</p></div>}
                  </CardContent>
                </Card>
              )}

              {section === "activity" && (
                <Card className="dash-card activity-card">
                  <CardHeader><CardTitle>Onchain activity</CardTitle><CardDescription>Reconstructed from the configured hook’s emitted logs, beginning at its deployment block.</CardDescription></CardHeader>
                  <CardContent>
                    {snapshot.activities.map((item) => <article key={item.key}><div><strong>{item.title}</strong><span>{item.detail}</span></div><div><small>block {item.block}</small>{item.hash && <code>{shortHash(item.hash)} <ExternalLink /></code>}</div></article>)}
                    {snapshot.activities.length === 0 && <p className="empty-copy">Connect a wallet with Firstless history or execute the first local action.</p>}
                  </CardContent>
                </Card>
              )}
            </section>

            <aside className="round-panel">
              <div className="round-panel__heading"><div><p>Ethereum block set</p><span className="round-panel__chain">Hook clock · block.number</span></div><Badge className={isEpochOpen ? "badge-live" : "badge-idle"}>{isEpochOpen && <i />} {isEpochOpen ? "Open" : "Idle"}</Badge></div>
              <div className="round-panel__art"><ClearingStation scene={isEpochOpen ? 2 : 0} compact /></div>
              <Separator />
              <ol className="round-steps">{stages.map(([title, detail], index) => <li key={title} className={isEpochOpen ? (index < 3 ? "is-done" : index === 3 ? "is-current" : "") : ""}><span>{isEpochOpen && index < 3 ? <Check aria-hidden="true" /> : index + 1}</span><div><strong>{title}</strong><small>{detail}</small></div></li>)}</ol>
              <Alert className="round-note"><Clock3 aria-hidden="true" /><AlertTitle>{isEpochOpen ? `Set #${snapshot.epochId} opened in block ${snapshot.openedAt}` : "No set is waiting"}</AlertTitle><AlertDescription>{isEpochOpen ? "The output has already moved. Only settlement and refunds remain." : "The next signed order opens a set in its execution block."}</AlertDescription></Alert>
              <div className="round-metrics"><div><span>Fee buckets</span><strong>{amount(snapshot.fee0, deployment?.token0Decimals)} / {amount(snapshot.fee1, deployment?.token1Decimals)}</strong></div><div><span>Pending LP assets</span><strong>{amount(snapshot.pending0, deployment?.token0Decimals)} / {amount(snapshot.pending1, deployment?.token1Decimals)}</strong></div></div>
              <Button className="settle-button" disabled={!wallet || !canSettle || Boolean(busy)} onClick={() => void settle()}>{busy === "Set settlement" ? <LoaderCircle className="spin" /> : <RefreshCcw />} {canSettle ? "Settle completed set" : isEpochOpen ? "Waiting for next block" : "No set to settle"}</Button>
              {claimable.length > 0 && <p className="round-claim-note">{claimable.length} settled refund{claimable.length === 1 ? "" : "s"} ready.</p>}
            </aside>
          </div>
        </div>
      </section>
    </main>
  );
}
