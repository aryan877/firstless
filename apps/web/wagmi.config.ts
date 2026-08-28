import { defineConfig } from "@wagmi/cli";
import { foundry } from "@wagmi/cli/plugins";

export default defineConfig({
  out: "src/generated/contracts.ts",
  plugins: [
    foundry({
      project: "../../packages/contracts",
      include: [
        "FirstlessHook.sol/FirstlessHook.json",
        "FirstlessRefundRedeemer.sol/FirstlessRefundRedeemer.json",
        "FirstlessRouter.sol/FirstlessRouter.json",
        "LocalDevContracts.sol/FirstlessDevToken.json",
        "PoolManager.sol/PoolManager.json",
      ],
      forge: {
        build: true,
        clean: false,
        rebuild: false,
      },
    }),
  ],
});
