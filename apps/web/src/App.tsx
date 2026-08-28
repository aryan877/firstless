import { lazy, Suspense, useEffect, useLayoutEffect, useState } from "react";
import { LandingPage } from "@/components/LandingPage";

const DashboardPage = lazy(() => import("@/components/DashboardPage").then((module) => ({ default: module.DashboardPage })));

type View = "story" | "dashboard";

function viewFromUrl(): View {
  return new URLSearchParams(window.location.search).get("view") === "dashboard"
    ? "dashboard"
    : "story";
}

export function App() {
  const [view, setView] = useState<View>(viewFromUrl);

  useEffect(() => {
    const onPopState = () => setView(viewFromUrl());
    window.addEventListener("popstate", onPopState);
    return () => window.removeEventListener("popstate", onPopState);
  }, []);

  useLayoutEffect(() => {
    window.scrollTo({ top: 0, left: 0, behavior: "auto" });
  }, [view]);

  const navigate = (next: View) => {
    const url = next === "dashboard" ? "?view=dashboard" : window.location.pathname;
    window.history.pushState({}, "", url);
    setView(next);
  };

  return view === "dashboard" ? (
    <Suspense fallback={<main className="dashboard-loading" aria-label="Loading Firstless dashboard" />}>
      <DashboardPage onBack={() => navigate("story")} />
    </Suspense>
  ) : (
    <LandingPage onOpenDashboard={() => navigate("dashboard")} />
  );
}
