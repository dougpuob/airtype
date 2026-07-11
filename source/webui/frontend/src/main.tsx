import React from "react";
import ReactDOM from "react-dom/client";
import { CssBaseline, ThemeProvider } from "@mui/material";
import { QueryClientProvider } from "@tanstack/react-query";
import { HashRouter } from "react-router-dom";
import App from "./App";
import { queryClient } from "./api/queryClient";
import { WorkGuardProvider } from "./hooks/useWorkGuard";
import { theme } from "./theme";
import "./styles.css";

const reloadScopedStateKeys = [
  "airtype:obsidian-clipper:state",
  "airtype:v-to-text:state",
  "airtype:capture-post:state",
  "airtype:ime-history:state"
];

function clearReloadScopedState() {
  if (typeof window === "undefined") return;
  for (const key of reloadScopedStateKeys) {
    window.sessionStorage.removeItem(key);
    window.localStorage.removeItem(key);
  }
}

clearReloadScopedState();

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <ThemeProvider theme={theme}>
        <CssBaseline />
        <HashRouter>
          <WorkGuardProvider>
            <App />
          </WorkGuardProvider>
        </HashRouter>
      </ThemeProvider>
    </QueryClientProvider>
  </React.StrictMode>
);
