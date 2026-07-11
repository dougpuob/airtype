import DashboardOutlinedIcon from "@mui/icons-material/DashboardOutlined";
import GraphicEqOutlinedIcon from "@mui/icons-material/GraphicEqOutlined";
import HistoryOutlinedIcon from "@mui/icons-material/HistoryOutlined";
import SettingsOutlinedIcon from "@mui/icons-material/SettingsOutlined";
import { Box, List, ListItemButton, ListItemIcon, ListItemText, Typography } from "@mui/material";
import type { MouseEvent, ReactNode } from "react";
import { NavLink, useLocation, useNavigate } from "react-router-dom";
import { useWorkGuard } from "../../hooks/useWorkGuard";

type NavItem = {
  label: string;
  path: string;
  icon: ReactNode;
};

export const navItems: NavItem[] = [
  { label: "Dashboard", path: "/", icon: <DashboardOutlinedIcon /> },
  { label: "Obsidian Clipper", path: "/v-to-text", icon: <GraphicEqOutlinedIcon /> },
  { label: "IME History", path: "/ime-history", icon: <HistoryOutlinedIcon /> }
];

export const settingsNavItem: NavItem = { label: "Settings", path: "/settings", icon: <SettingsOutlinedIcon /> };

type SidebarProps = {
  topBarHeight: number;
};

type NavigationListProps = {
  items?: NavItem[];
  orientation?: "vertical" | "horizontal";
  onNavigate?: () => void;
};

export function NavigationList({ items = navItems, orientation = "vertical", onNavigate }: NavigationListProps) {
  const horizontal = orientation === "horizontal";
  const location = useLocation();
  const navigate = useNavigate();
  const { requestLeave } = useWorkGuard();

  function handleNavigate(event: MouseEvent<HTMLAnchorElement>, path: string) {
    if (event.button !== 0 || event.metaKey || event.altKey || event.ctrlKey || event.shiftKey) return;
    if (location.pathname === path) {
      onNavigate?.();
      return;
    }

    event.preventDefault();
    requestLeave(() => {
      navigate(path);
      onNavigate?.();
    });
  }

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
      {items.map((item) => (
        <ListItemButton
          key={item.path}
          component={NavLink}
          to={item.path}
          end={item.path === "/"}
          onClick={(event) => handleNavigate(event, item.path)}
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
      <NavigationList items={[settingsNavItem]} />
      <Box sx={{ display: "none", height: topBarHeight * 0 }} />
    </Box>
  );
}
