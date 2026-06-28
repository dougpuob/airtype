import {
  Alert,
  Button,
  Divider,
  FormControlLabel,
  Grid,
  LinearProgress,
  MenuItem,
  Snackbar,
  Stack,
  Switch,
  TextField,
  Typography
} from "@mui/material";
import { useEffect, useMemo, useState } from "react";
import { useSettingsQuery, useUpdateSettingsMutation } from "../api/settings";
import type { AppSettings } from "../types/settings";
import { PageScaffold, WorkspacePanel } from "./PageScaffold";

const languageOptions = [
  { value: "zh-tw", label: "Traditional Chinese" },
  { value: "zh-cn", label: "Simplified Chinese" },
  { value: "en", label: "English" },
  { value: "ja", label: "Japanese" },
  { value: "ko", label: "Korean" }
];

const providerOptions = ["llama.cpp", "ollama", "openai"];

export function SettingsPage() {
  const settingsQuery = useSettingsQuery();
  const updateSettings = useUpdateSettingsMutation();
  const [draft, setDraft] = useState<AppSettings | null>(null);
  const [toast, setToast] = useState("");

  useEffect(() => {
    if (settingsQuery.data) setDraft(settingsQuery.data);
  }, [settingsQuery.data]);

  const selectedModels = useMemo(() => draft?.llm?.models || [], [draft?.llm?.models]);
  const canSave = Boolean(draft) && !settingsQuery.isLoading && !updateSettings.isPending;

  function updateSection<K extends keyof AppSettings>(section: K, values: NonNullable<AppSettings[K]>) {
    setDraft((current) => ({
      ...(current || {}),
      [section]: {
        ...((current?.[section] as object) || {}),
        ...(values as object)
      }
    }));
  }

  async function saveSettings() {
    if (!draft) return;
    const saved = await updateSettings.mutateAsync(draft);
    setDraft(saved);
    setToast("Settings saved");
  }

  return (
    <PageScaffold
      title="Settings"
      eyebrow="Configuration"
      actions={
        <Button variant="contained" disabled={!canSave} onClick={() => void saveSettings()}>
          {updateSettings.isPending ? "Saving..." : "Save settings"}
        </Button>
      }
    >
      <Stack spacing={2}>
        {settingsQuery.isLoading ? <LinearProgress /> : null}
        {settingsQuery.isError ? <Alert severity="error">Could not load settings.</Alert> : null}
        {updateSettings.isError ? <Alert severity="error">{errorMessage(updateSettings.error)}</Alert> : null}

        <Grid container spacing={2}>
          <Grid size={{ xs: 12, lg: 6 }}>
            <WorkspacePanel>
              <Stack spacing={1.5}>
                <Typography variant="h3">Web UI Access</Typography>
                <Typography color="text.secondary">HTTP Basic authentication for the browser UI and API.</Typography>
                <Divider />
                <FormControlLabel
                  control={
                    <Switch
                      checked={Boolean(draft?.auth?.enabled)}
                      onChange={(event) => updateSection("auth", { enabled: event.target.checked })}
                    />
                  }
                  label="Require username and password"
                />
                <TextField
                  size="small"
                  label="Username"
                  value={draft?.auth?.username || ""}
                  onChange={(event) => updateSection("auth", { username: event.target.value })}
                />
                <TextField
                  size="small"
                  label="Password"
                  type="password"
                  value={draft?.auth?.password || ""}
                  onChange={(event) => updateSection("auth", { password: event.target.value })}
                />
              </Stack>
            </WorkspacePanel>
          </Grid>

          <Grid size={{ xs: 12, lg: 6 }}>
            <WorkspacePanel>
              <Stack spacing={1.5}>
                <Typography variant="h3">Whisper Server</Typography>
                <Typography color="text.secondary">Speech recognition model, server, and language defaults.</Typography>
                <Divider />
                <TextField
                  select
                  size="small"
                  label="Language"
                  value={draft?.whisper?.language || "zh-tw"}
                  onChange={(event) => updateSection("whisper", { language: event.target.value })}
                >
                  {languageOptions.map((option) => (
                    <MenuItem key={option.value} value={option.value}>
                      {option.label}
                    </MenuItem>
                  ))}
                </TextField>
                <TextField
                  size="small"
                  label="Remote endpoint"
                  value={draft?.whisper?.remote_endpoint || ""}
                  onChange={(event) => updateSection("whisper", { remote_endpoint: event.target.value })}
                />
                <TextField
                  size="small"
                  label="Model directory"
                  value={draft?.whisper?.model_dir || ""}
                  onChange={(event) => updateSection("whisper", { model_dir: event.target.value })}
                />
                <TextField
                  size="small"
                  label="Model filename"
                  value={draft?.whisper?.model_filename || ""}
                  onChange={(event) => updateSection("whisper", { model_filename: event.target.value })}
                />
                <TextField
                  size="small"
                  label="Server binary"
                  value={draft?.whisper?.server_bin || ""}
                  onChange={(event) => updateSection("whisper", { server_bin: event.target.value })}
                />
                <TextField
                  size="small"
                  label="Server args"
                  value={draft?.whisper?.server_args || ""}
                  onChange={(event) => updateSection("whisper", { server_args: event.target.value })}
                />
              </Stack>
            </WorkspacePanel>
          </Grid>

          <Grid size={{ xs: 12, lg: 6 }}>
            <WorkspacePanel>
              <Stack spacing={1.5}>
                <Typography variant="h3">Local LLM Model</Typography>
                <Typography color="text.secondary">Default model used for transcript polishing, tags, and IME correction.</Typography>
                <Divider />
                <TextField
                  size="small"
                  label="Server name"
                  value={draft?.llm?.name || "default"}
                  onChange={(event) => updateSection("llm", { name: event.target.value })}
                />
                <TextField
                  select
                  size="small"
                  label="Provider"
                  value={draft?.llm?.provider || "llama.cpp"}
                  onChange={(event) => updateSection("llm", { provider: event.target.value })}
                >
                  {providerOptions.map((provider) => (
                    <MenuItem key={provider} value={provider}>
                      {provider}
                    </MenuItem>
                  ))}
                </TextField>
                <TextField
                  size="small"
                  label="Endpoint"
                  value={draft?.llm?.endpoint || ""}
                  onChange={(event) => updateSection("llm", { endpoint: event.target.value })}
                />
                <TextField
                  size="small"
                  label="API key"
                  type="password"
                  value={draft?.llm?.api_key || ""}
                  onChange={(event) => updateSection("llm", { api_key: event.target.value })}
                />
                <TextField
                  select={selectedModels.length > 0}
                  size="small"
                  label="Selected model"
                  value={draft?.llm?.selected_model || draft?.llm?.model || ""}
                  onChange={(event) => updateSection("llm", { selected_model: event.target.value, model: event.target.value })}
                >
                  {selectedModels.map((model) => (
                    <MenuItem key={model} value={model}>
                      {model}
                    </MenuItem>
                  ))}
                </TextField>
                <TextField
                  size="small"
                  label="Context length"
                  type="number"
                  value={draft?.llm?.contextLength ?? 8192}
                  onChange={(event) => updateSection("llm", { contextLength: Number(event.target.value) || 8192 })}
                />
                <TextField
                  size="small"
                  label="Temperature"
                  type="number"
                  value={draft?.llm?.temperature ?? 0.4}
                  onChange={(event) => updateSection("llm", { temperature: Number(event.target.value) })}
                  inputProps={{ min: 0, max: 2, step: 0.1 }}
                />
                <FormControlLabel
                  control={
                    <Switch
                      checked={Boolean(draft?.llm?.disable_thinking)}
                      onChange={(event) => updateSection("llm", { disable_thinking: event.target.checked })}
                    />
                  }
                  label="Disable thinking for faster responses"
                />
                <TextField
                  size="small"
                  label="Default system prompt"
                  multiline
                  minRows={4}
                  value={draft?.llm?.system || ""}
                  onChange={(event) => updateSection("llm", { system: event.target.value })}
                />
              </Stack>
            </WorkspacePanel>
          </Grid>

          <Grid size={{ xs: 12, lg: 6 }}>
            <WorkspacePanel>
              <Stack spacing={1.5}>
                <Typography variant="h3">Obsidian and Downloads</Typography>
                <Typography color="text.secondary">Note export uses Obsidian URI links; media URL imports use yt-dlp.</Typography>
                <Divider />
                <TextField
                  size="small"
                  label="Obsidian default folder"
                  placeholder="Inbox/AirType"
                  value={draft?.obsidian?.default_folder || ""}
                  onChange={(event) => updateSection("obsidian", { default_folder: event.target.value })}
                />
                <TextField
                  size="small"
                  label="yt-dlp cookies file"
                  value={draft?.ytdlp?.cookies || ""}
                  onChange={(event) => updateSection("ytdlp", { cookies: event.target.value })}
                />
                <TextField
                  size="small"
                  label="yt-dlp cookies from browser"
                  value={draft?.ytdlp?.cookies_from_browser || ""}
                  onChange={(event) => updateSection("ytdlp", { cookies_from_browser: event.target.value })}
                />
                <Alert severity="info">
                  Obsidian notes are opened with the local Obsidian app using the generated note title and Markdown body.
                </Alert>
              </Stack>
            </WorkspacePanel>
          </Grid>
        </Grid>
      </Stack>

      <Snackbar
        open={Boolean(toast)}
        autoHideDuration={2200}
        onClose={() => setToast("")}
        message={toast}
        anchorOrigin={{ vertical: "bottom", horizontal: "center" }}
      />
    </PageScaffold>
  );
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : "Could not save settings.";
}
