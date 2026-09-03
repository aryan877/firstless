import { createConfig, http, type CreateConnectorFn } from "wagmi";
import { sepolia, unichainSepolia } from "wagmi/chains";
import { coinbaseWallet, injected, mock, safe, walletConnect } from "wagmi/connectors";
import { defineChain } from "viem";

export const firstlessLocal = defineChain({
  id: 31_337,
  name: "Firstless local",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: {
      http: [(import.meta.env.VITE_LOCAL_RPC_URL as string | undefined) || "http://127.0.0.1:8546"],
    },
  },
  testnet: true,
});

const walletConnectProjectId = import.meta.env.VITE_WALLETCONNECT_PROJECT_ID as string | undefined;
const connectors: CreateConnectorFn[] = [
  injected({ shimDisconnect: true }),
  coinbaseWallet({ appName: "Firstless" }),
  safe({ shimDisconnect: true }),
  mock({
    accounts: ["0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"],
    features: { reconnect: true },
  }),
];

if (walletConnectProjectId) {
  connectors.splice(2, 0, walletConnect({ projectId: walletConnectProjectId }));
}

export const wagmiConfig = createConfig({
  chains: [firstlessLocal, unichainSepolia, sepolia],
  connectors,
  multiInjectedProviderDiscovery: true,
  transports: {
    [firstlessLocal.id]: http(firstlessLocal.rpcUrls.default.http[0]),
    [unichainSepolia.id]: http(import.meta.env.VITE_UNICHAIN_SEPOLIA_RPC_URL as string | undefined),
    [sepolia.id]: http(import.meta.env.VITE_ETHEREUM_SEPOLIA_RPC_URL as string | undefined),
  },
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
