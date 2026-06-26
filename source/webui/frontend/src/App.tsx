import { Navigate, Route, Routes } from "react-router-dom";
import { AppShell } from "./components/app-shell/AppShell";
import { CapturePostPage } from "./pages/CapturePostPage";
import { DashboardPage } from "./pages/DashboardPage";
import { ImeHistoryPage } from "./pages/ImeHistoryPage";
import { SettingsPage } from "./pages/SettingsPage";
import { VToTextPage } from "./pages/VToTextPage";

export default function App() {
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
