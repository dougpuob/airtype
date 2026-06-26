import CircleIcon from "@mui/icons-material/Circle";
import { AppBar, Box, Chip, Stack, Toolbar, Typography } from "@mui/material";
import { useSettingsQuery } from "../../api/settings";
import { useLocalLlmHealthQuery, useWhisperServerStatusQuery } from "../../api/serviceStatus";

type TopAppBarProps = {
  sidebarWidth: number;
};

export function TopAppBar({ sidebarWidth }: TopAppBarProps) {
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
          <ServiceChip label="ASR Server" state={asr} />
          <ServiceChip label="LLM Server" state={llm} />
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
