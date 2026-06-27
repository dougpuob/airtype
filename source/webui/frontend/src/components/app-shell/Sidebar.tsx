import ArticleOutlinedIcon from "@mui/icons-material/ArticleOutlined";
import DashboardOutlinedIcon from "@mui/icons-material/DashboardOutlined";
import GraphicEqOutlinedIcon from "@mui/icons-material/GraphicEqOutlined";
import HistoryOutlinedIcon from "@mui/icons-material/HistoryOutlined";
import SettingsOutlinedIcon from "@mui/icons-material/SettingsOutlined";
import { Box, List, ListItemButton, ListItemIcon, ListItemText, Typography } from "@mui/material";
import { NavLink } from "react-router-dom";

export const navItems = [
  { label: "Dashboard", path: "/", icon: <DashboardOutlinedIcon /> },
  { label: "V to Text", path: "/v-to-text", icon: <GraphicEqOutlinedIcon /> },
  { label: "Capture Post", path: "/capture-post", icon: <ArticleOutlinedIcon /> },
  { label: "IME History", path: "/ime-history", icon: <HistoryOutlinedIcon /> },
  { label: "Settings", path: "/settings", icon: <SettingsOutlinedIcon /> }
];

type SidebarProps = {
  topBarHeight: number;
};

type NavigationListProps = {
  orientation?: "vertical" | "horizontal";
  onNavigate?: () => void;
};

export function NavigationList({ orientation = "vertical", onNavigate }: NavigationListProps) {
  const horizontal = orientation === "horizontal";
  return (
    <List
      dense
      disablePadding
      sx={{
        display: horizontal ? "flex" : "grid",
        gap: 0.5,
        width: "100%",
        minWidth: horizontal ? "max-content" : 0
      }}
    >
      {navItems.map((item) => (
        <ListItemButton
          key={item.path}
          component={NavLink}
          to={item.path}
          end={item.path === "/"}
          onClick={onNavigate}
          sx={{
            color: "text.secondary",
            flexDirection: horizontal ? "column" : "row",
            justifyContent: horizontal ? "center" : "flex-start",
            minWidth: horizontal ? 72 : 0,
            minHeight: horizontal ? 56 : 42,
            px: horizontal ? 1 : 2,
            py: horizontal ? 0.5 : 1,
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
              minWidth: horizontal ? 0 : 36,
              color: "text.secondary",
              mb: horizontal ? 0.25 : 0
            }}
          >
            {item.icon}
          </ListItemIcon>
          <ListItemText
            primary={item.label}
            primaryTypographyProps={{
              fontSize: horizontal ? 10 : 13,
              fontWeight: 750,
              textAlign: horizontal ? "center" : "left",
              noWrap: true
            }}
          />
        </ListItemButton>
      ))}
    </List>
  );
}

export function Sidebar({ topBarHeight }: SidebarProps) {
  return (
    <Box
      component="aside"
      sx={{
        gridColumn: 1,
        gridRow: 2,
        minHeight: 0,
        display: { xs: "none", md: "flex" },
        flexDirection: "column",
        alignItems: "stretch",
        borderRight: 1,
        borderColor: "divider",
        bgcolor: "background.paper",
        px: 1.5,
        py: 2,
        mt: 0,
        overflowX: "visible",
        overflowY: "hidden"
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
      <NavigationList />
      <Box sx={{ flex: 1 }} />
      <Typography variant="caption" sx={{ color: "text.secondary", px: 1.5 }}>
        Local workspace
      </Typography>
      <Box sx={{ display: "none", height: topBarHeight * 0 }} />
    </Box>
  );
}
