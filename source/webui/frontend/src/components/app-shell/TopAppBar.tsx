import CircleIcon from "@mui/icons-material/Circle";
import MenuIcon from "@mui/icons-material/Menu";
import { AppBar, Box, Chip, IconButton, Stack, Toolbar, Typography, useMediaQuery, useTheme } from "@mui/material";
import { useSettingsQuery } from "../../api/settings";
import { useLocalLlmHealthQuery, useWhisperServerStatusQuery } from "../../api/serviceStatus";

type TopAppBarProps = {
  sidebarWidth: number;
  onMenuClick?: () => void;
};

export function TopAppBar({ sidebarWidth, onMenuClick }: TopAppBarProps) {
  const theme = useTheme();
  const compact = useMediaQuery(theme.breakpoints.down("sm"));
  const settingsQuery = useSettingsQuery();
  const whisperStatus = useWhisperServerStatusQuery();
  const llmHealth = useLocalLlmHealthQuery(settingsQuery.data);
  const asr = serviceChipState({
    isLoading: whisperStatus.isLoading,
    isError: whisperStatus.isError,
    online: whisperStatus.data?.running === true || Boolean(whisperStatus.data?.endpoint)
  });
  const llm = serviceChipState({
    isLoading: settingsQuery.isLoading || llmHealth.isLoading,
    isError: settingsQuery.isError || llmHealth.isError,
    online: llmHealth.data?.ok === true,
    disabled: !settingsQuery.data?.llm?.provider || !settingsQuery.data?.llm?.endpoint
  });

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
      <Toolbar sx={{ minHeight: "58px !important", px: { xs: 1.25, md: 2.5 }, gap: 1 }}>
        <IconButton
          aria-label="Open workspace navigation"
          edge="start"
          onClick={onMenuClick}
          sx={{ display: { xs: "inline-flex", md: "none" }, mr: 0.25 }}
        >
          <MenuIcon />
        </IconButton>
        <Stack
          direction="row"
          alignItems="center"
          spacing={1.25}
          sx={{ width: { xs: "auto", md: sidebarWidth - 20 }, flexShrink: 0, minWidth: 0 }}
        >
          <Box
            component="img"
            src="/app/favicon.svg"
            alt=""
            sx={{
              width: 40,
              height: 40,
              p: 0.7,
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
        <Stack direction="row" spacing={0.75} alignItems="center" sx={{ minWidth: 0, overflow: "hidden" }}>
          <ServiceChip label={compact ? "ASR" : "ASR Server"} state={asr} />
          <ServiceChip label={compact ? "LLM" : "LLM Server"} state={llm} />
        </Stack>
      </Toolbar>
    </AppBar>
  );
}

type ChipState = {
  label: "Checking" | "Ready" | "Offline";
  color: "default" | "success" | "error";
};

function ServiceChip({ label, state }: { label: string; state: ChipState }) {
  return (
    <Chip
      size="small"
      icon={<CircleIcon sx={{ fontSize: "10px !important" }} />}
      label={`${label}: ${state.label}`}
      variant="outlined"
      color={state.color}
      sx={{
        maxWidth: { xs: 96, sm: "none" },
        "& .MuiChip-label": {
          overflow: "hidden",
          textOverflow: "ellipsis",
          whiteSpace: "nowrap"
        }
      }}
    />
  );
}

function serviceChipState(input: {
  isLoading: boolean;
  isError: boolean;
  online: boolean;
  disabled?: boolean;
}): ChipState {
  if (input.isLoading) return { label: "Checking", color: "default" };
  if (input.disabled || input.isError || !input.online) return { label: "Offline", color: "error" };
  return { label: "Ready", color: "success" };
}
