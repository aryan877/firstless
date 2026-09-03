import React from "react";
import ReactDOM from "react-dom/client";
import "@fontsource-variable/geist";
import "@fontsource/dm-mono/400.css";
import { App } from "@/App";
import { Toaster } from "@/components/ui/sonner";
import "./index.css";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
    <Toaster closeButton position="bottom-right" richColors visibleToasts={5} />
  </React.StrictMode>,
);
