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
        gridColumn: { xs: 1, md: 1 },
        gridRow: { xs: 3, md: 2 },
        minHeight: 0,
        display: "flex",
        flexDirection: { xs: "row", md: "column" },
        alignItems: { xs: "center", md: "stretch" },
        borderRight: { xs: 0, md: 1 },
        borderTop: { xs: 1, md: 0 },
        borderColor: "divider",
        bgcolor: "background.paper",
        px: { xs: 0.75, md: 1.5 },
        py: { xs: 0.75, md: 2 },
        mt: 0,
        overflowX: { xs: "auto", md: "visible" },
        overflowY: "hidden"
      }}
    >
      <Typography
        variant="overline"
        sx={{
          display: { xs: "none", md: "block" },
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
      <List
        dense
        disablePadding
        sx={{
          display: { xs: "flex", md: "grid" },
          gap: { xs: 0.5, md: 0.5 },
          width: "100%",
          minWidth: { xs: "max-content", md: 0 }
        }}
      >
        {navItems.map((item) => (
          <ListItemButton
            key={item.path}
            component={NavLink}
            to={item.path}
            end={item.path === "/"}
            sx={{
              color: "text.secondary",
              flexDirection: { xs: "column", md: "row" },
              justifyContent: "center",
              minWidth: { xs: 72, md: 0 },
              minHeight: { xs: 56, md: 42 },
              px: { xs: 1, md: 2 },
              py: { xs: 0.5, md: 1 },
              "&.active": {
                bgcolor: "primary.light",
                color: "primary.dark",
                "& .MuiListItemIcon-root": {
                  color: "primary.dark"
                }
              }
            }}
          >
            <ListItemIcon
              sx={{
                minWidth: { xs: 0, md: 36 },
                color: "text.secondary",
                mb: { xs: 0.25, md: 0 }
              }}
            >
              {item.icon}
            </ListItemIcon>
            <ListItemText
              primary={item.label}
              primaryTypographyProps={{
                fontSize: { xs: 10, md: 13 },
                fontWeight: 750,
                textAlign: { xs: "center", md: "left" },
                noWrap: true
              }}
            />
          </ListItemButton>
        ))}
      </List>
      <Box sx={{ flex: 1, display: { xs: "none", md: "block" } }} />
      <Typography variant="caption" sx={{ display: { xs: "none", md: "block" }, color: "text.secondary", px: 1.5 }}>
        Local workspace
      </Typography>
      <Box sx={{ display: "none", height: topBarHeight * 0 }} />
    </Box>
  );
}
