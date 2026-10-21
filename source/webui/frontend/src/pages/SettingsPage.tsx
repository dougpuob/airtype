import {
  Alert,
  Box,
  Button,
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
import type { ReactNode } from "react";
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

const settingsPanelSx = {
  "& .MuiInputBase-input": {
    fontSize: 13
  },
  "& .MuiInputLabel-root": {
    fontSize: 13
  },
  "& .MuiFormControlLabel-label": {
    fontSize: 13,
    fontWeight: 700
  },
  "& .MuiAlert-message": {
    fontSize: 13
  }
};

export function SettingsPage() {
  const settingsQuery = useSettingsQuery();
  const updateSettings = useUpdateSettingsMutation();
  const [draft, setDraft] = useState<AppSettings | null>(null);
  const [toast, setToast] = useState("");

  useEffect(() => {
    if (settingsQuery.data) {
      setDraft(settingsQuery.data);
    }
  }, [settingsQuery.data]);

  const selectedModels = useMemo(() => draft?.llm?.models || [], [draft?.llm?.models]);
  const canSave = Boolean(draft) && !settingsQuery.isLoading && !updateSettings.isPending;
  const authEnabled = Boolean(draft?.auth?.enabled);
  const thinkingSteps = draft?.capture_post?.thinking_steps ?? ["title"];
  const aiTitleEnabled = draft?.capture_post?.ai_title_enabled ?? true;

  function updateSection<K extends keyof AppSettings>(section: K, values: NonNullable<AppSettings[K]>) {
    setDraft((current) => ({
      ...(current || {}),
      [section]: {
        ...((current?.[section] as object) || {}),
        ...(values as object)
      }
    }));
  }

  function toggleThinkingStep(step: "polish" | "title" | "tags", enabled: boolean) {
    const current = draft?.capture_post?.thinking_steps ?? ["title"];
    const next = enabled ? [...new Set([...current, step])] : current.filter((item) => item !== step);
    const order = ["polish", "title", "tags"] as const;
    updateSection("capture_post", { thinking_steps: order.filter((item) => next.includes(item)) });
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
            <SettingsSection title="Access" description="Cookie login for the browser UI and API.">
              <FormControlLabel
                control={
                  <Switch
                    checked={authEnabled}
                    onChange={(event) => updateSection("auth", { enabled: event.target.checked })}
                  />
                }
                label="Require username and password"
              />
              <FieldGrid>
                <Grid size={{ xs: 12, sm: 6 }}>
                  <TextField
                    fullWidth
                    size="small"
                    label="Username"
                    disabled={!authEnabled}
                    value={draft?.auth?.username || ""}
                    onChange={(event) => updateSection("auth", { username: event.target.value })}
                  />
                </Grid>
                <Grid size={{ xs: 12, sm: 6 }}>
                  <TextField
                    fullWidth
                    size="small"
                    label="Password"
                    type="password"
                    disabled={!authEnabled}
                    value={draft?.auth?.password || ""}
                    onChange={(event) => updateSection("auth", { password: event.target.value })}
                    helperText={
                      draft?.auth?.password_configured
                        ? "A password is already set. Leave blank to keep it."
                        : "Password used on the AirType login page."
                    }
                  />
                </Grid>
                <Grid size={{ xs: 12, sm: 6 }}>
                  <TextField
                    fullWidth
                    size="small"
                    label="Stay signed in (days)"
                    type="number"
                    disabled={!authEnabled}
                    value={draft?.auth?.session_days ?? 14}
                    onChange={(event) =>
                      updateSection("auth", {
                        session_days: Math.min(90, Math.max(1, Number(event.target.value) || 14))
                      })
                    }
                    inputProps={{ min: 1, max: 90, step: 1 }}
                    helperText="New sessions last 1–90 days."
                  />
                </Grid>
              </FieldGrid>
            </SettingsSection>
          </Grid>

          <Grid size={{ xs: 12, lg: 6 }}>
            <SettingsSection title="Notes" description="Where Save to Obsidian puts the draft.">
              <FieldGrid>
                <Grid size={{ xs: 12, sm: 6 }}>
                  <TextField
                    fullWidth
                    size="small"
                    label="Vault name"
                    placeholder="Leave blank for the open vault"
                    value={draft?.obsidian?.vault_name || ""}
                    onChange={(event) => updateSection("obsidian", { vault_name: event.target.value })}
                    helperText="Must match Obsidian’s vault switcher. Leave blank unless you need to switch vaults."
                  />
                </Grid>
                <Grid size={{ xs: 12, sm: 6 }}>
                  <TextField
                    fullWidth
                    size="small"
                    label="Default folder"
                    placeholder="Inbox/AirType"
                    value={draft?.obsidian?.default_folder || ""}
                    onChange={(event) => updateSection("obsidian", { default_folder: event.target.value })}
                    helperText="Folder inside the vault, for example airtype. Do not put the vault name here."
                  />
                </Grid>
              </FieldGrid>
            </SettingsSection>
          </Grid>

          <Grid size={{ xs: 12 }}>
            <SettingsSection title="Capture" description="Cookies for logged-in media, and Immich for note photos.">
              <Grid container spacing={2.5}>
                <Grid size={{ xs: 12, md: 6 }}>
                  <Subsection title="yt-dlp">
                    <TextField
                      fullWidth
                      size="small"
                      label="Cookies file"
                      value={draft?.ytdlp?.cookies || ""}
                      onChange={(event) => updateSection("ytdlp", { cookies: event.target.value })}
                      helperText="Netscape cookies file. Also used as Threads login cookies when present."
                    />
                    <TextField
                      fullWidth
                      size="small"
                      label="Cookies from browser"
                      value={draft?.ytdlp?.cookies_from_browser || ""}
                      onChange={(event) => updateSection("ytdlp", { cookies_from_browser: event.target.value })}
                      helperText="For age-restricted or logged-in videos. YouTube also needs Deno 2.3+."
                    />
                  </Subsection>
                </Grid>
                <Grid size={{ xs: 12, md: 6 }}>
                  <Subsection title="Immich">
                    <TextField
                      fullWidth
                      size="small"
                      label="Server URL"
                      placeholder="https://immich.example.com"
                      value={draft?.immich?.server_url || ""}
                      onChange={(event) => updateSection("immich", { server_url: event.target.value })}
                      helperText="Tailscale MagicDNS names (*.ts.net) work even if Use Tailscale DNS is off."
                    />
                    <TextField
                      fullWidth
                      size="small"
                      label="API key"
                      value={draft?.immich?.api_key || ""}
                      onChange={(event) => updateSection("immich", { api_key: event.target.value })}
                      helperText="API key for the Immich account that stores note photos."
                    />
                    <FormControlLabel
                      control={
                        <Switch
                          checked={draft?.immich?.create_album ?? false}
                          onChange={(event) => updateSection("immich", { create_album: event.target.checked })}
                        />
                      }
                      label="Create one Immich album per article"
                    />
                    <Typography variant="caption" color="text.secondary">
                      Each note gets a GUID tag on its Immich images. Without Immich, original image URLs are kept.
                    </Typography>
                  </Subsection>
                </Grid>
              </Grid>
            </SettingsSection>
          </Grid>

          <Grid size={{ xs: 12 }}>
            <SettingsSection title="Speech" description="Whisper language and server used for voice clips.">
              <Grid container spacing={2.5}>
                <Grid size={{ xs: 12, md: 4 }}>
                  <Subsection title="Recognition">
                    <TextField
                      select
                      fullWidth
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
                    <Typography variant="caption" color="text.secondary">
                      IME mode pastes raw speech-to-text and does not send it to the LLM.
                    </Typography>
                  </Subsection>
                </Grid>
                <Grid size={{ xs: 12, md: 8 }}>
                  <Subsection title="Server">
                    <TextField
                      fullWidth
                      size="small"
                      label="Remote endpoint"
                      value={draft?.whisper?.remote_endpoint || ""}
                      onChange={(event) => updateSection("whisper", { remote_endpoint: event.target.value })}
                    />
                    <FieldGrid>
                      <Grid size={{ xs: 12, sm: 6 }}>
                        <TextField
                          fullWidth
                          size="small"
                          label="Model directory"
                          value={draft?.whisper?.model_dir || ""}
                          onChange={(event) => updateSection("whisper", { model_dir: event.target.value })}
                        />
                      </Grid>
                      <Grid size={{ xs: 12, sm: 6 }}>
                        <TextField
                          fullWidth
                          size="small"
                          label="Model filename"
                          value={draft?.whisper?.model_filename || ""}
                          onChange={(event) => updateSection("whisper", { model_filename: event.target.value })}
                        />
                      </Grid>
                      <Grid size={{ xs: 12, sm: 6 }}>
                        <TextField
                          fullWidth
                          size="small"
                          label="Server binary"
                          value={draft?.whisper?.server_bin || ""}
                          onChange={(event) => updateSection("whisper", { server_bin: event.target.value })}
                        />
                      </Grid>
                      <Grid size={{ xs: 12, sm: 6 }}>
                        <TextField
                          fullWidth
                          size="small"
                          label="Server args"
                          value={draft?.whisper?.server_args || ""}
                          onChange={(event) => updateSection("whisper", { server_args: event.target.value })}
                        />
                      </Grid>
                    </FieldGrid>
                  </Subsection>
                </Grid>
              </Grid>
            </SettingsSection>
          </Grid>

          <Grid size={{ xs: 12 }}>
            <SettingsSection title="AI" description="Local LLM used for polishing, titles, and tags.">
              <Subsection title="Connection">
                <FieldGrid>
                  <Grid size={{ xs: 12, sm: 6 }}>
                    <TextField
                      fullWidth
                      size="small"
                      label="Server name"
                      value={draft?.llm?.name || "default"}
                      onChange={(event) => updateSection("llm", { name: event.target.value })}
                    />
                  </Grid>
                  <Grid size={{ xs: 12, sm: 6 }}>
                    <TextField
                      select
                      fullWidth
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
                  </Grid>
                  <Grid size={{ xs: 12, sm: 6 }}>
                    <TextField
                      fullWidth
                      size="small"
                      label="Endpoint"
                      value={draft?.llm?.endpoint || ""}
                      onChange={(event) => updateSection("llm", { endpoint: event.target.value })}
                    />
                  </Grid>
                  <Grid size={{ xs: 12, sm: 6 }}>
                    <TextField
                      fullWidth
                      size="small"
                      label="API key"
                      type="password"
                      value={draft?.llm?.api_key || ""}
                      onChange={(event) => updateSection("llm", { api_key: event.target.value })}
                    />
                  </Grid>
                  <Grid size={{ xs: 12, sm: 6 }}>
                    <TextField
                      select={selectedModels.length > 0}
                      fullWidth
                      size="small"
                      label="Selected model"
                      value={draft?.llm?.selected_model || draft?.llm?.model || ""}
                      onChange={(event) =>
                        updateSection("llm", { selected_model: event.target.value, model: event.target.value })
                      }
                    >
                      {selectedModels.map((model) => (
                        <MenuItem key={model} value={model}>
                          {model}
                        </MenuItem>
                      ))}
                    </TextField>
                  </Grid>
                  <Grid size={{ xs: 12, sm: 3 }}>
                    <TextField
                      fullWidth
                      size="small"
                      label="Context length"
                      type="number"
                      value={draft?.llm?.contextLength ?? 8192}
                      onChange={(event) => updateSection("llm", { contextLength: Number(event.target.value) || 8192 })}
                    />
                  </Grid>
                  <Grid size={{ xs: 12, sm: 3 }}>
                    <TextField
                      fullWidth
                      size="small"
                      label="Temperature"
                      type="number"
                      value={draft?.llm?.temperature ?? 0.4}
                      onChange={(event) => updateSection("llm", { temperature: Number(event.target.value) })}
                      inputProps={{ min: 0, max: 2, step: 0.1 }}
                    />
                  </Grid>
                </FieldGrid>
              </Subsection>
              <Subsection title="Thinking">
                <FormControlLabel
                  control={
                    <Switch
                      checked={Boolean(draft?.llm?.disable_thinking)}
                      onChange={(event) => updateSection("llm", { disable_thinking: event.target.checked })}
                    />
                  }
                  label="Disable thinking for faster responses"
                />
                <Stack direction="row" spacing={1} flexWrap="wrap" useFlexGap>
                  <FormControlLabel
                    control={
                      <Switch
                        size="small"
                        checked={thinkingSteps.includes("polish")}
                        onChange={(event) => toggleThinkingStep("polish", event.target.checked)}
                      />
                    }
                    label="Polish"
                  />
                  <FormControlLabel
                    control={
                      <Switch
                        size="small"
                        checked={thinkingSteps.includes("title")}
                        onChange={(event) => toggleThinkingStep("title", event.target.checked)}
                      />
                    }
                    label="Titles"
                  />
                  <FormControlLabel
                    control={
                      <Switch
                        size="small"
                        checked={thinkingSteps.includes("tags")}
                        onChange={(event) => toggleThinkingStep("tags", event.target.checked)}
                      />
                    }
                    label="Tags"
                  />
                </Stack>
                <Typography variant="caption" color="text.secondary">
                  Titles use thinking by default. Turn it on for polishing and tags if you want slower, more careful steps.
                </Typography>
              </Subsection>
              <Subsection title="Writing">
                <FormControlLabel
                  control={
                    <Switch
                      checked={aiTitleEnabled}
                      onChange={(event) => updateSection("capture_post", { ai_title_enabled: event.target.checked })}
                    />
                  }
                  label="Generate note titles with AI"
                />
                <FieldGrid>
                  <Grid size={{ xs: 12, md: 6 }}>
                    <TextField
                      fullWidth
                      size="small"
                      label="Default system prompt"
                      multiline
                      minRows={4}
                      value={draft?.llm?.system || ""}
                      onChange={(event) => updateSection("llm", { system: event.target.value })}
                    />
                  </Grid>
                  <Grid size={{ xs: 12, md: 6 }}>
                    <TextField
                      fullWidth
                      size="small"
                      label="Title system prompt"
                      multiline
                      minRows={4}
                      disabled={!aiTitleEnabled}
                      value={draft?.capture_post?.title_system_prompt || ""}
                      onChange={(event) =>
                        updateSection("capture_post", { title_system_prompt: event.target.value })
                      }
                      helperText="Used when a workflow asks the LLM for a title."
                    />
                  </Grid>
                </FieldGrid>
              </Subsection>
            </SettingsSection>
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

function SettingsSection({
  title,
  description,
  children
}: {
  title: string;
  description?: string;
  children: ReactNode;
}) {
  return (
    <WorkspacePanel>
      <Stack spacing={1.75} sx={settingsPanelSx}>
        <Box>
          <Typography variant="h3">{title}</Typography>
          {description ? (
            <Typography variant="body2" color="text.secondary" sx={{ mt: 0.5 }}>
              {description}
            </Typography>
          ) : null}
        </Box>
        {children}
      </Stack>
    </WorkspacePanel>
  );
}

function Subsection({ title, children }: { title: string; children: ReactNode }) {
  return (
    <Stack spacing={1.25}>
      <Typography
        variant="overline"
        sx={{ color: "text.secondary", fontWeight: 800, letterSpacing: 0.4, lineHeight: 1.2 }}
      >
        {title}
      </Typography>
      {children}
    </Stack>
  );
}

function FieldGrid({ children }: { children: ReactNode }) {
  return (
    <Grid container spacing={1.5}>
      {children}
    </Grid>
  );
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : "Could not save settings.";
}
