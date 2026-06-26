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
        gridTemplateColumns: `${sidebarWidth}px minmax(0, 1fr)`,
        gridTemplateRows: `${topBarHeight}px minmax(0, 1fr)`,
        height: "100vh",
        minWidth: 0,
        bgcolor: "background.default"
      }}
    >
      <TopAppBar sidebarWidth={sidebarWidth} />
      <Sidebar topBarHeight={topBarHeight} />
      <Box
        component="main"
        sx={{
          gridColumn: 2,
          gridRow: 2,
          minWidth: 0,
          minHeight: 0,
          overflow: "auto",
          p: 3
        }}
      >
        {children}
      </Box>
    </Box>
  );
}
