import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { WagmiProvider } from "wagmi";
import { DashboardPage } from "@/components/DashboardPage";
import { TooltipProvider } from "@/components/ui/tooltip";
import { wagmiConfig } from "@/lib/wagmi";

const queryClient = new QueryClient();

export function DashboardShell({ onBack }: { onBack: () => void }) {
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <TooltipProvider>
          <DashboardPage onBack={onBack} />
        </TooltipProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
