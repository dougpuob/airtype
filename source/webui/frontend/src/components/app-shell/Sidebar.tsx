import ArticleOutlinedIcon from "@mui/icons-material/ArticleOutlined";
import DashboardOutlinedIcon from "@mui/icons-material/DashboardOutlined";
import GraphicEqOutlinedIcon from "@mui/icons-material/GraphicEqOutlined";
import HistoryOutlinedIcon from "@mui/icons-material/HistoryOutlined";
import SettingsOutlinedIcon from "@mui/icons-material/SettingsOutlined";
import { Box, List, ListItemButton, ListItemIcon, ListItemText, Typography } from "@mui/material";
import { NavLink } from "react-router-dom";

const navItems = [
  { label: "Dashboard", path: "/", icon: <DashboardOutlinedIcon /> },
  { label: "V to Text", path: "/v-to-text", icon: <GraphicEqOutlinedIcon /> },
  { label: "Capture Post", path: "/capture-post", icon: <ArticleOutlinedIcon /> },
  { label: "IME History", path: "/ime-history", icon: <HistoryOutlinedIcon /> },
  { label: "Settings", path: "/settings", icon: <SettingsOutlinedIcon /> }
];

type SidebarProps = {
  topBarHeight: number;
};

export function Sidebar({ topBarHeight }: SidebarProps) {
  return (
    <Box
      component="aside"
      sx={{
        gridColumn: 1,
        gridRow: 2,
        minHeight: 0,
        display: "flex",
        flexDirection: "column",
        borderRight: 1,
        borderColor: "divider",
        bgcolor: "background.paper",
        px: 1.5,
        py: 2,
        mt: 0
      }}
    >
      <Typography
        variant="overline"
        sx={{
          color: "text.secondary",
          fontSize: 11,
          fontWeight: 800,
          letterSpacing: 0.4,
          px: 1.5,
          mb: 1
        }}
      >
        Workspace
      </Typography>
      <List dense disablePadding sx={{ display: "grid", gap: 0.5 }}>
        {navItems.map((item) => (
          <ListItemButton
            key={item.path}
            component={NavLink}
            to={item.path}
            end={item.path === "/"}
            sx={{
              color: "text.secondary",
              "&.active": {
                bgcolor: "primary.light",
                color: "primary.dark",
                "& .MuiListItemIcon-root": {
                  color: "primary.dark"
                }
              }
            }}
          >
            <ListItemIcon sx={{ minWidth: 36, color: "text.secondary" }}>{item.icon}</ListItemIcon>
            <ListItemText
              primary={item.label}
              primaryTypographyProps={{
                fontSize: 13,
                fontWeight: 750
              }}
            />
          </ListItemButton>
        ))}
      </List>
      <Box sx={{ flex: 1 }} />
      <Typography variant="caption" sx={{ color: "text.secondary", px: 1.5 }}>
        Local workspace
      </Typography>
      <Box sx={{ height: topBarHeight * 0 }} />
    </Box>
  );
}
