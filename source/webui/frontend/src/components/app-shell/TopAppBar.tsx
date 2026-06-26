import CircleIcon from "@mui/icons-material/Circle";
import { AppBar, Box, Chip, Stack, Toolbar, Typography } from "@mui/material";

type TopAppBarProps = {
  sidebarWidth: number;
};

export function TopAppBar({ sidebarWidth }: TopAppBarProps) {
  return (
    <AppBar
      position="static"
      color="inherit"
      elevation={0}
      sx={{
        gridColumn: "1 / -1",
        gridRow: 1,
        borderBottom: 1,
        borderColor: "divider",
        bgcolor: "rgba(255, 255, 255, 0.92)",
        backdropFilter: "blur(16px)"
      }}
    >
      <Toolbar sx={{ minHeight: "58px !important", px: 2.5 }}>
        <Stack
          direction="row"
          alignItems="center"
          spacing={1.25}
          sx={{ width: sidebarWidth - 20, flexShrink: 0 }}
        >
          <Box
            component="img"
            src="/app/favicon.svg"
            alt=""
            sx={{
              width: 32,
              height: 32,
              p: 0.6,
              borderRadius: 2,
              border: 1,
              borderColor: "divider",
              bgcolor: "background.paper"
            }}
          />
          <Typography variant="h3" component="div">
            AirType
          </Typography>
        </Stack>
        <Box sx={{ flex: 1 }} />
        <Stack direction="row" spacing={1} alignItems="center">
          <Chip
            size="small"
            icon={<CircleIcon sx={{ fontSize: "10px !important" }} />}
            label="ASR Server"
            variant="outlined"
            color="default"
          />
          <Chip
            size="small"
            icon={<CircleIcon sx={{ fontSize: "10px !important" }} />}
            label="LLM Server"
            variant="outlined"
          />
        </Stack>
      </Toolbar>
    </AppBar>
  );
}
