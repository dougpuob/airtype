import { Box } from "@mui/material";
import type { PropsWithChildren } from "react";
import { Sidebar } from "./Sidebar";
import { TopAppBar } from "./TopAppBar";

const sidebarWidth = 236;
const topBarHeight = 58;

export function AppShell({ children }: PropsWithChildren) {
  return (
    <Box
      sx={{
        display: "grid",
        gridTemplateColumns: { xs: "minmax(0, 1fr)", md: `${sidebarWidth}px minmax(0, 1fr)` },
        gridTemplateRows: { xs: `${topBarHeight}px minmax(0, 1fr) 72px`, md: `${topBarHeight}px minmax(0, 1fr)` },
        height: "100vh",
        minWidth: 0,
        overflow: "hidden",
        bgcolor: "background.default"
      }}
    >
      <TopAppBar sidebarWidth={sidebarWidth} />
      <Sidebar topBarHeight={topBarHeight} />
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
