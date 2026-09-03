import { lazy, Suspense, useEffect, useLayoutEffect, useState } from "react";
import { LandingPage } from "@/components/LandingPage";

const DashboardShell = lazy(() => import("@/components/DashboardShell").then((module) => ({ default: module.DashboardShell })));
const DocsPage = lazy(() => import("@/components/DocsPage").then((module) => ({ default: module.DocsPage })));

type View = "story" | "dashboard" | "docs";

function viewFromUrl(): View {
  const view = new URLSearchParams(window.location.search).get("view");
  if (view === "dashboard" || view === "docs") return view;
  return "story";
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

  useEffect(() => {
    document.title = view === "docs"
      ? "Firstless docs — how same-block clearing works"
      : view === "dashboard"
        ? "Firstless dashboard"
        : "Firstless — output now, fair bill later";
  }, [view]);

  const navigate = (next: View) => {
    const url = next === "story" ? window.location.pathname : `?view=${next}`;
    window.history.pushState({}, "", url);
    setView(next);
  };

  if (view === "dashboard") return (
    <Suspense fallback={<main className="dashboard-loading" aria-label="Loading Firstless dashboard" />}>
      <DashboardShell onBack={() => navigate("story")} />
    </Suspense>
  );

  if (view === "docs") return (
    <Suspense fallback={<main className="dashboard-loading" aria-label="Loading Firstless documentation" />}>
      <DocsPage onOpenStory={() => navigate("story")} onOpenDashboard={() => navigate("dashboard")} />
    </Suspense>
  );

  return <LandingPage onOpenDashboard={() => navigate("dashboard")} onOpenDocs={() => navigate("docs")} />;
}
