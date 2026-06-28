import { Alert, Box, Button, CircularProgress, Stack } from "@mui/material";
import { useEffect } from "react";
import { Navigate, Route, Routes } from "react-router-dom";
import { useAuthStatusQuery } from "./api/auth";
import { AppShell } from "./components/app-shell/AppShell";
import { CapturePostPage } from "./pages/CapturePostPage";
import { DashboardPage } from "./pages/DashboardPage";
import { ImeHistoryPage } from "./pages/ImeHistoryPage";
import { LoginPage } from "./pages/LoginPage";
import { SettingsPage } from "./pages/SettingsPage";
import { VToTextPage } from "./pages/VToTextPage";

export default function App() {
  const authQuery = useAuthStatusQuery();
  const refetchAuth = authQuery.refetch;

  useEffect(() => {
    function handleUnauthorized() {
      void refetchAuth();
    }
    window.addEventListener("airtype:unauthorized", handleUnauthorized);
    return () => window.removeEventListener("airtype:unauthorized", handleUnauthorized);
  }, [refetchAuth]);

  if (authQuery.isLoading) {
    return (
      <Box sx={{ alignItems: "center", display: "flex", justifyContent: "center", minHeight: "100vh" }}>
        <CircularProgress size={32} />
      </Box>
    );
  }

  if (authQuery.isError || !authQuery.data) {
    return (
      <Stack alignItems="center" justifyContent="center" spacing={2} sx={{ minHeight: "100vh", p: 2 }}>
        <Alert severity="error">Could not check the AirType login status.</Alert>
        <Button variant="outlined" onClick={() => void authQuery.refetch()}>
          Try again
        </Button>
      </Stack>
    );
  }

  if (authQuery.data.enabled && !authQuery.data.authenticated) {
    return <LoginPage status={authQuery.data} />;
  }

  return (
    <AppShell>
      <Routes>
        <Route path="/" element={<DashboardPage />} />
        <Route path="/v-to-text" element={<VToTextPage />} />
        <Route path="/capture-post" element={<CapturePostPage />} />
        <Route path="/ime-history" element={<ImeHistoryPage />} />
        <Route path="/settings" element={<SettingsPage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </AppShell>
  );
}
