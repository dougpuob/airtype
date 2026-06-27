import { Box, Drawer, Typography } from "@mui/material";
import type { PropsWithChildren } from "react";
import { useState } from "react";
import { NavigationList, Sidebar } from "./Sidebar";
import { TopAppBar } from "./TopAppBar";

const sidebarWidth = 236;
const topBarHeight = 58;

export function AppShell({ children }: PropsWithChildren) {
  const [mobileNavOpen, setMobileNavOpen] = useState(false);

  return (
    <Box
      sx={{
        display: "grid",
        gridTemplateColumns: { xs: "minmax(0, 1fr)", md: `${sidebarWidth}px minmax(0, 1fr)` },
        gridTemplateRows: `${topBarHeight}px minmax(0, 1fr)`,
        height: "100vh",
        minWidth: 0,
        overflow: "hidden",
        bgcolor: "background.default"
      }}
    >
      <TopAppBar sidebarWidth={sidebarWidth} onMenuClick={() => setMobileNavOpen(true)} />
      <Sidebar topBarHeight={topBarHeight} />
      <Drawer
        open={mobileNavOpen}
        onClose={() => setMobileNavOpen(false)}
        ModalProps={{ keepMounted: true }}
        sx={{ display: { xs: "block", md: "none" } }}
        PaperProps={{
          sx: {
            width: 276,
            display: "flex",
            flexDirection: "column",
            borderRight: 1,
            borderColor: "divider",
            bgcolor: "background.paper",
            p: 2
          }
        }}
      >
        <Typography
          variant="overline"
          sx={{ color: "text.secondary", fontSize: 11, fontWeight: 800, letterSpacing: 0.4, px: 1.5, mb: 1 }}
        >
          Workspace
        </Typography>
        <NavigationList onNavigate={() => setMobileNavOpen(false)} />
        <Box sx={{ flex: 1 }} />
        <Typography variant="caption" sx={{ color: "text.secondary", px: 1.5, mt: 2 }}>
          Local workspace
        </Typography>
      </Drawer>
      <Box
        component="main"
        sx={{
          gridColumn: { xs: 1, md: 2 },
          gridRow: 2,
          minWidth: 0,
          minHeight: 0,
          overflow: "auto",
          p: { xs: 1.5, md: 3 },
          pb: { xs: 2, md: 3 }
        }}
      >
        {children}
      </Box>
    </Box>
  );
}
