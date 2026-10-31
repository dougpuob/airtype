import AddIcon from "@mui/icons-material/Add";
import CloudOutlinedIcon from "@mui/icons-material/CloudOutlined";
import DeleteOutlineIcon from "@mui/icons-material/DeleteOutline";
import EditOutlinedIcon from "@mui/icons-material/EditOutlined";
import ExpandLessIcon from "@mui/icons-material/ExpandLess";
import GraphicEqOutlinedIcon from "@mui/icons-material/GraphicEqOutlined";
import HubOutlinedIcon from "@mui/icons-material/HubOutlined";
import LinkOutlinedIcon from "@mui/icons-material/LinkOutlined";
import NetworkCheckIcon from "@mui/icons-material/NetworkCheck";
import ComputerOutlinedIcon from "@mui/icons-material/ComputerOutlined";
import PhotoLibraryOutlinedIcon from "@mui/icons-material/PhotoLibraryOutlined";
import RefreshIcon from "@mui/icons-material/Refresh";
import RouteOutlinedIcon from "@mui/icons-material/RouteOutlined";
import TuneOutlinedIcon from "@mui/icons-material/TuneOutlined";
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Collapse,
  FormControlLabel,
  Grid,
  IconButton,
  LinearProgress,
  List,
  ListItemButton,
  ListItemIcon,
  ListItemText,
  Menu,
  MenuItem,
  Paper,
  Snackbar,
  Stack,
  Switch,
  Tab,
  Tabs,
  TextField,
  Tooltip,
  Typography,
  useMediaQuery,
  useTheme
} from "@mui/material";
import type { ReactNode } from "react";
import { useEffect, useMemo, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { apiRequest } from "../api/client";
import { useSettingsQuery, useUpdateSettingsMutation } from "../api/settings";
import type { AiRoute, AiRouteType, AiStep, AppSettings } from "../types/settings";
import { AI_STEPS, API_ROUTE_TYPES, CLI_ROUTE_TYPES, isCloudRoute } from "../types/settings";
import { PageScaffold, WorkspacePanel } from "./PageScaffold";

const languageOptions = [
  { value: "zh-tw", label: "Traditional Chinese" },
  { value: "zh-cn", label: "Simplified Chinese" },
  { value: "en", label: "English" },
  { value: "ja", label: "Japanese" },
  { value: "ko", label: "Korean" }
];

const providerOptions = ["llama.cpp", "ollama", "openai"];

type CategoryId = "general" | "capture" | "speech" | "ai-routes" | "ai-steps" | "media";

const categories: Array<{ id: CategoryId; label: string; description: string; icon: ReactNode }> = [
  { id: "general", label: "General", description: "Sign-in and Obsidian notes", icon: <TuneOutlinedIcon /> },
  { id: "capture", label: "Capture", description: "Posts, IME, web pages, yt-dlp", icon: <LinkOutlinedIcon /> },
  { id: "speech", label: "Speech", description: "Whisper speech-to-text", icon: <GraphicEqOutlinedIcon /> },
  { id: "ai-routes", label: "AI routes", description: "Named models you can use", icon: <HubOutlinedIcon /> },
  { id: "ai-steps", label: "AI steps", description: "Which route each step uses", icon: <RouteOutlinedIcon /> },
  { id: "media", label: "Media", description: "Immich photo storage", icon: <PhotoLibraryOutlinedIcon /> }
];

const routeTypeLabels: Record<AiRouteType, string> = {
  "openai-compat": "Local / OpenAI-compatible",
  chatgpt: "ChatGPT",
  "chatgpt-codex": "ChatGPT Codex",
  "claude-code": "Claude Code",
  gemini: "Gemini",
  "grok-api": "Grok API",
  "grok-cli": "Grok CLI"
};

/** Defaults and help text per cloud route type. */
const routeTypeInfo: Partial<
  Record<AiRouteType, { endpoint?: string; model?: string; bin?: string; help: string; login?: string }>
> = {
  chatgpt: { endpoint: "https://api.openai.com/v1", model: "gpt-4.1-mini", help: "OpenAI API (platform.openai.com key)." },
  gemini: {
    endpoint: "https://generativelanguage.googleapis.com/v1beta/openai",
    model: "gemini-2.5-flash",
    help: "Gemini OpenAI-compatible API (Google AI Studio key)."
  },
  "grok-api": { endpoint: "https://api.x.ai", model: "grok-4", help: "xAI OpenAI-compatible API." },
  "chatgpt-codex": { bin: "codex", help: "OpenAI Codex CLI, ChatGPT plan login.", login: "codex login" },
  "claude-code": { bin: "claude", help: "Claude Code CLI, Claude plan login.", login: "claude auth login" },
  "grok-cli": { bin: "~/.grok/bin/grok", help: "Grok Build CLI.", login: "grok login" }
};

const stepInfo: Record<AiStep, { label: string; description: string; thinking: boolean }> = {
  correct: {
    label: "Correct",
    description: "Typo correction of transcripts. On failure the original text is kept (no fallback).",
    thinking: false
  },
  polish: { label: "Polish", description: "Turns a transcript or post into an article.", thinking: true },
  title: { label: "Title", description: "Generates note titles.", thinking: true },
  tags: { label: "Tags", description: "Generates Obsidian hashtags.", thinking: true }
};

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

function isCategory(value: string | null): value is CategoryId {
  return categories.some((category) => category.id === value);
}

function routesFromSettings(settings: AppSettings): AiRoute[] {
  if (settings.ai_routes?.length) return settings.ai_routes;
  const servers = settings.llm_servers?.length ? settings.llm_servers : settings.llm ? [settings.llm] : [];
  return servers
    .filter((server): server is NonNullable<AppSettings["llm"]> => Boolean(server?.name))
    .map((server) => ({ ...server, name: server.name || "default", type: "openai-compat" as const }));
}

function newRoute(type: AiRouteType, existing: AiRoute[]): AiRoute {
  const base = routeTypeLabels[type].split(" /")[0];
  let name = base;
  for (let index = 2; existing.some((route) => route.name === name); index += 1) name = `${base} ${index}`;
  const info = routeTypeInfo[type];
  if (CLI_ROUTE_TYPES.includes(type)) {
    return {
      name,
      type,
      bin: info?.bin || "",
      model: "",
      reasoning_effort: "low",
      timeout_seconds: 180,
      correct_timeout_seconds: 180,
      typo_concurrency: 4
    };
  }
  if (API_ROUTE_TYPES.includes(type)) {
    return { name, type, endpoint: info?.endpoint || "", api_key: "", model: info?.model || "", typo_concurrency: 4 };
  }
  return {
    name,
    type,
    provider: "openai",
    endpoint: "http://127.0.0.1:8000",
    api_key: "",
    models: [],
    selected_model: "",
    contextLength: 8192,
    temperature: 0.4,
    disable_thinking: false,
    system: ""
  };
}

export function SettingsPage() {
  const theme = useTheme();
  const compact = useMediaQuery(theme.breakpoints.down("md"));
  const [searchParams, setSearchParams] = useSearchParams();
  const tabParam = searchParams.get("tab");
  const category: CategoryId = isCategory(tabParam) ? tabParam : "general";
  const settingsQuery = useSettingsQuery();
  const updateSettings = useUpdateSettingsMutation();
  const [draft, setDraft] = useState<AppSettings | null>(null);
  const [toast, setToast] = useState("");

  useEffect(() => {
    if (settingsQuery.data) {
      setDraft({ ...settingsQuery.data, ai_routes: routesFromSettings(settingsQuery.data) });
    }
  }, [settingsQuery.data]);

  const routes = useMemo(() => draft?.ai_routes || [], [draft?.ai_routes]);
  const routeErrors = useMemo(() => validateRoutes(routes), [routes]);
  const hasRouteErrors = Object.keys(routeErrors).length > 0 || !routes.some((route) => route.type === "openai-compat");
  const canSave = Boolean(draft) && !settingsQuery.isLoading && !updateSettings.isPending && !hasRouteErrors;
  const authEnabled = Boolean(draft?.auth?.enabled);
  const thinkingSteps = draft?.capture_post?.thinking_steps ?? ["title"];
  const aiTitleEnabled = draft?.capture_post?.ai_title_enabled ?? true;
  const fallbackName =
    draft?.default_llm_server_name || routes.find((route) => route.type === "openai-compat")?.name || "";

  function selectCategory(next: CategoryId) {
    const params = new URLSearchParams(searchParams);
    if (next === "general") params.delete("tab");
    else params.set("tab", next);
    setSearchParams(params, { replace: true });
  }

  function updateSection<K extends keyof AppSettings>(section: K, values: NonNullable<AppSettings[K]>) {
    setDraft((current) => ({
      ...(current || {}),
      [section]: {
        ...((current?.[section] as object) || {}),
        ...(values as object)
      }
    }));
  }

  function setRoutes(update: (current: AiRoute[]) => AiRoute[]) {
    setDraft((current) => ({ ...(current || {}), ai_routes: update(current?.ai_routes || []) }));
  }

  function updateRoute(index: number, values: Partial<AiRoute>) {
    setDraft((current) => {
      const currentRoutes = current?.ai_routes || [];
      const previous = currentRoutes[index];
      if (!previous) return current;
      const next = { ...previous, ...values };
      const nextRoutes = currentRoutes.map((route, routeIndex) => (routeIndex === index ? next : route));
      let steps = current?.ai_steps || {};
      let defaultName = current?.default_llm_server_name;
      if (values.name !== undefined && values.name !== previous.name) {
        // Keep step bindings and the fallback pointing at the renamed route.
        steps = Object.fromEntries(
          Object.entries(steps).map(([step, name]) => [step, name === previous.name ? values.name : name])
        );
        if (defaultName === previous.name) defaultName = values.name;
      }
      return { ...(current || {}), ai_routes: nextRoutes, ai_steps: steps, default_llm_server_name: defaultName };
    });
  }

  function deleteRoute(index: number) {
    setDraft((current) => {
      const currentRoutes = current?.ai_routes || [];
      const removed = currentRoutes[index];
      const nextRoutes = currentRoutes.filter((_, routeIndex) => routeIndex !== index);
      const steps = Object.fromEntries(
        Object.entries(current?.ai_steps || {}).map(([step, name]) => [step, name === removed?.name ? "" : name])
      );
      return { ...(current || {}), ai_routes: nextRoutes, ai_steps: steps };
    });
  }

  function toggleThinkingStep(step: "polish" | "title" | "tags", enabled: boolean) {
    const current = draft?.capture_post?.thinking_steps ?? ["title"];
    const next = enabled ? [...new Set([...current, step])] : current.filter((item) => item !== step);
    const order = ["polish", "title", "tags"] as const;
    updateSection("capture_post", { thinking_steps: order.filter((item) => next.includes(item)) });
  }

  async function saveSettings() {
    if (!draft) return;
    const fallback = routes.find((route) => route.type === "openai-compat" && route.name === fallbackName);
    const payload: AppSettings = { ...draft, default_llm_server_name: fallbackName };
    if (fallback) {
      const { type: _type, ...llm } = fallback;
      payload.llm = llm;
    }
    const saved = await updateSettings.mutateAsync(payload);
    setDraft({ ...saved, ai_routes: routesFromSettings(saved) });
    setToast("Settings saved");
  }

  const navigation = compact ? (
    <Paper sx={{ px: 1 }}>
      <Tabs
        value={category}
        onChange={(_, value: CategoryId) => selectCategory(value)}
        variant="scrollable"
        scrollButtons="auto"
        allowScrollButtonsMobile
      >
        {categories.map((item) => (
          <Tab key={item.id} value={item.id} label={item.label} sx={{ minHeight: 48, fontSize: 13 }} />
        ))}
      </Tabs>
    </Paper>
  ) : (
    <Paper sx={{ p: 1, position: "sticky", top: 0 }}>
      <List dense disablePadding>
        {categories.map((item) => (
          <ListItemButton
            key={item.id}
            selected={item.id === category}
            onClick={() => selectCategory(item.id)}
            sx={{ borderRadius: 1.5, mb: 0.25 }}
          >
            <ListItemIcon sx={{ minWidth: 34 }}>{item.icon}</ListItemIcon>
            <ListItemText
              primary={item.label}
              secondary={item.description}
              primaryTypographyProps={{ fontSize: 13, fontWeight: 700 }}
              secondaryTypographyProps={{ fontSize: 11.5 }}
            />
          </ListItemButton>
        ))}
      </List>
    </Paper>
  );

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
        {hasRouteErrors && draft ? (
          <Alert severity="warning" action={<Button size="small" onClick={() => selectCategory("ai-routes")}>Fix</Button>}>
            AI routes need a unique name each, and at least one Local route.
          </Alert>
        ) : null}

        <Grid container spacing={2} alignItems="flex-start">
          <Grid size={{ xs: 12, md: 3, xl: 2 }}>{navigation}</Grid>
          <Grid size={{ xs: 12, md: 9, xl: 10 }}>
            {category === "general" ? (
              <Stack spacing={2}>
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
                <SettingsSection title="Obsidian" description="Where Save to Obsidian puts the draft.">
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
              </Stack>
            ) : null}

            {category === "capture" ? (
              <Stack spacing={2}>
                <SettingsSection title="Capture post" description="AI titles for captured posts and voice notes.">
                  <FormControlLabel
                    control={
                      <Switch
                        checked={aiTitleEnabled}
                        onChange={(event) => updateSection("capture_post", { ai_title_enabled: event.target.checked })}
                      />
                    }
                    label="Generate note titles with AI"
                  />
                  <TextField
                    fullWidth
                    size="small"
                    label="Title system prompt"
                    multiline
                    minRows={3}
                    disabled={!aiTitleEnabled}
                    value={draft?.capture_post?.title_system_prompt || ""}
                    onChange={(event) => updateSection("capture_post", { title_system_prompt: event.target.value })}
                    helperText="Used when a workflow asks the Title step for a title. Pick its route under AI steps."
                  />
                </SettingsSection>
                <SettingsSection title="IME" description="Voice typing from the local app.">
                  <Typography variant="body2" color="text.secondary">
                    IME mode pastes raw speech-to-text and does not send it to the LLM. Nothing to configure yet.
                  </Typography>
                </SettingsSection>
                <SettingsSection title="Web → Markdown" description="Turning web pages into notes.">
                  <FieldGrid>
                    <Grid size={{ xs: 12, sm: 6 }}>
                      <TextField
                        fullWidth
                        size="small"
                        label="API key"
                        type="password"
                        value={draft?.web_to_markdown?.api_key || ""}
                        onChange={(event) => updateSection("web_to_markdown", { api_key: event.target.value })}
                      />
                    </Grid>
                    <Grid size={{ xs: 6, sm: 3 }}>
                      <TextField
                        fullWidth
                        size="small"
                        label="Timeout (s)"
                        type="number"
                        value={draft?.web_to_markdown?.timeout_seconds ?? 60}
                        onChange={(event) =>
                          updateSection("web_to_markdown", { timeout_seconds: Number(event.target.value) || 60 })
                        }
                        inputProps={{ min: 5, max: 300 }}
                      />
                    </Grid>
                    <Grid size={{ xs: 6, sm: 3 }}>
                      <TextField
                        fullWidth
                        size="small"
                        label="Max download (MB)"
                        type="number"
                        value={draft?.web_to_markdown?.download_max_mb ?? 20}
                        onChange={(event) =>
                          updateSection("web_to_markdown", { download_max_mb: Number(event.target.value) || 20 })
                        }
                        inputProps={{ min: 1, max: 200 }}
                      />
                    </Grid>
                  </FieldGrid>
                </SettingsSection>
                <SettingsSection title="yt-dlp" description="Cookies for logged-in or age-restricted media.">
                  <FieldGrid>
                    <Grid size={{ xs: 12, sm: 6 }}>
                      <TextField
                        fullWidth
                        size="small"
                        label="Cookies file"
                        value={draft?.ytdlp?.cookies || ""}
                        onChange={(event) => updateSection("ytdlp", { cookies: event.target.value })}
                        helperText="Netscape cookies file. Also used as Threads login cookies when present."
                      />
                    </Grid>
                    <Grid size={{ xs: 12, sm: 6 }}>
                      <TextField
                        fullWidth
                        size="small"
                        label="Cookies from browser"
                        value={draft?.ytdlp?.cookies_from_browser || ""}
                        onChange={(event) => updateSection("ytdlp", { cookies_from_browser: event.target.value })}
                        helperText="For age-restricted or logged-in videos. YouTube also needs Deno 2.3+."
                      />
                    </Grid>
                  </FieldGrid>
                </SettingsSection>
              </Stack>
            ) : null}

            {category === "speech" ? (
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
            ) : null}

            {category === "ai-routes" ? (
              <AiRoutesSection
                routes={routes}
                errors={routeErrors}
                fallbackName={fallbackName}
                onAdd={(type) => setRoutes((current) => [...current, newRoute(type, current)])}
                onChange={updateRoute}
                onDelete={deleteRoute}
              />
            ) : null}

            {category === "ai-steps" ? (
              <SettingsSection
                title="AI steps"
                description="Pick a route for each step. Routes are managed under AI routes."
              >
                <Stack spacing={1.5}>
                  {AI_STEPS.map((step) => {
                    const info = stepInfo[step];
                    const bound = draft?.ai_steps?.[step] || "";
                    const boundRoute = routes.find((route) => route.name === bound);
                    return (
                      <Paper key={step} variant="outlined" sx={{ p: 1.5 }}>
                        <Grid container spacing={1.5} alignItems="center">
                          <Grid size={{ xs: 12, md: 4 }}>
                            <Typography sx={{ fontSize: 14, fontWeight: 700 }}>{info.label}</Typography>
                            <Typography variant="caption" color="text.secondary">
                              {info.description}
                            </Typography>
                          </Grid>
                          <Grid size={{ xs: 12, sm: 8, md: 5 }}>
                            <TextField
                              select
                              fullWidth
                              size="small"
                              label="Route"
                              value={boundRoute ? bound : ""}
                              onChange={(event) =>
                                setDraft((current) => ({
                                  ...(current || {}),
                                  ai_steps: { ...(current?.ai_steps || {}), [step]: event.target.value }
                                }))
                              }
                              SelectProps={{ displayEmpty: true }}
                              InputLabelProps={{ shrink: true }}
                              helperText={
                                isCloudRoute(boundRoute) && step !== "correct"
                                  ? `Falls back to ${fallbackName || "the local route"} if the cloud call fails.`
                                  : undefined
                              }
                            >
                              <MenuItem value="">
                                <em>Default local ({fallbackName || "none"})</em>
                              </MenuItem>
                              {routes.map((route) => (
                                <MenuItem key={route.name} value={route.name}>
                                  <Stack direction="row" spacing={1} alignItems="center">
                                    <RouteKindChip route={route} />
                                    <span>{route.name}</span>
                                  </Stack>
                                </MenuItem>
                              ))}
                            </TextField>
                          </Grid>
                          <Grid size={{ xs: 12, sm: 4, md: 3 }}>
                            {info.thinking ? (
                              <FormControlLabel
                                control={
                                  <Switch
                                    size="small"
                                    checked={thinkingSteps.includes(step as "polish" | "title" | "tags")}
                                    onChange={(event) =>
                                      toggleThinkingStep(step as "polish" | "title" | "tags", event.target.checked)
                                    }
                                  />
                                }
                                label="Thinking (local)"
                              />
                            ) : null}
                          </Grid>
                        </Grid>
                      </Paper>
                    );
                  })}
                </Stack>
                <Subsection title="Fallback">
                  <TextField
                    select
                    size="small"
                    label="Default local route"
                    value={routes.some((route) => route.name === fallbackName) ? fallbackName : ""}
                    onChange={(event) =>
                      setDraft((current) => ({ ...(current || {}), default_llm_server_name: event.target.value }))
                    }
                    sx={{ maxWidth: 420 }}
                    helperText="Used for unbound steps, chat, and when Polish / Title / Tags fail on a cloud route."
                  >
                    {routes
                      .filter((route) => route.type === "openai-compat")
                      .map((route) => (
                        <MenuItem key={route.name} value={route.name}>
                          {route.name}
                        </MenuItem>
                      ))}
                  </TextField>
                </Subsection>
              </SettingsSection>
            ) : null}

            {category === "media" ? (
              <SettingsSection title="Immich" description="Where note photos are stored.">
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
              </SettingsSection>
            ) : null}
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

function validateRoutes(routes: AiRoute[]): Record<number, string> {
  const errors: Record<number, string> = {};
  const seen = new Map<string, number>();
  routes.forEach((route, index) => {
    const name = (route.name || "").trim();
    if (!name) {
      errors[index] = "Name is required.";
      return;
    }
    if (seen.has(name)) errors[index] = "Name must be unique.";
    else seen.set(name, index);
  });
  return errors;
}

function RouteKindChip({ route }: { route: AiRoute }) {
  const cloud = isCloudRoute(route);
  return (
    <Chip
      size="small"
      variant="outlined"
      color={cloud ? "info" : "default"}
      icon={cloud ? <CloudOutlinedIcon /> : <ComputerOutlinedIcon />}
      label={cloud ? "Cloud" : "Local"}
      sx={{ height: 22, fontSize: 11 }}
    />
  );
}

function RouteKindBadge({ route }: { route: AiRoute }) {
  const cloud = isCloudRoute(route);
  return (
    <Stack alignItems="center" spacing={0.25} sx={{ width: 44, flexShrink: 0, pt: 0.25 }}>
      <Box
        sx={{
          width: 36,
          height: 36,
          borderRadius: 2,
          display: "grid",
          placeItems: "center",
          border: 1,
          borderColor: cloud ? "info.light" : "divider",
          color: cloud ? "info.main" : "text.secondary",
          bgcolor: cloud ? "rgba(2, 136, 209, 0.06)" : "action.hover"
        }}
      >
        {cloud ? <CloudOutlinedIcon fontSize="small" /> : <ComputerOutlinedIcon fontSize="small" />}
      </Box>
      <Typography sx={{ fontSize: 10.5, fontWeight: 700, color: cloud ? "info.main" : "text.secondary" }}>
        {cloud ? "Cloud" : "Local"}
      </Typography>
    </Stack>
  );
}

function AiRoutesSection({
  routes,
  errors,
  fallbackName,
  onAdd,
  onChange,
  onDelete
}: {
  routes: AiRoute[];
  errors: Record<number, string>;
  fallbackName: string;
  onAdd: (type: AiRouteType) => void;
  onChange: (index: number, values: Partial<AiRoute>) => void;
  onDelete: (index: number) => void;
}) {
  const [menuAnchor, setMenuAnchor] = useState<HTMLElement | null>(null);
  const [editing, setEditing] = useState<number | null>(null);
  const [tests, setTests] = useState<Record<number, RouteTestState>>({});
  const localCount = routes.filter((route) => route.type === "openai-compat").length;

  async function runTest(index: number, route: AiRoute) {
    setTests((current) => ({ ...current, [index]: { state: "testing", text: "Testing…" } }));
    try {
      const result = await apiRequest<{ ok: boolean; detail?: string; error?: string }>("/api/ai-routes/test", {
        method: "POST",
        body: JSON.stringify({ route })
      });
      setTests((current) => ({
        ...current,
        [index]: result.ok
          ? { state: "pass", text: `Connection pass${result.detail ? ` · ${result.detail}` : ""}` }
          : { state: "fail", text: `Connection failed: ${result.error || "unknown error"}` }
      }));
    } catch (testError) {
      setTests((current) => ({
        ...current,
        [index]: {
          state: "fail",
          text: `Connection failed: ${testError instanceof Error ? testError.message : "request failed"}`
        }
      }));
    }
  }

  return (
    <SettingsSection
      title="AI routes"
      description="Named ways to reach a model. AI steps pick one of these by name."
    >
      <Stack spacing={1.25}>
        {routes.map((route, index) => {
          const isFallback = route.type === "openai-compat" && route.name === fallbackName;
          const lastLocal = route.type === "openai-compat" && localCount <= 1;
          const open = editing === index || Boolean(errors[index]);
          return (
            <Paper key={index} variant="outlined" sx={{ p: 1.5 }}>
              <Stack direction="row" spacing={1.5} alignItems="flex-start">
                <RouteKindBadge route={route} />
                <Stack spacing={0.75} sx={{ minWidth: 0, flex: 1 }}>
                  <Box sx={{ minWidth: 0 }}>
                    <Stack direction="row" spacing={0.75} alignItems="center" flexWrap="wrap" useFlexGap>
                      <Typography sx={{ fontSize: 14, fontWeight: 700, wordBreak: "break-word" }}>
                        {route.name || "(unnamed)"}
                      </Typography>
                      <Chip size="small" variant="outlined" label={routeTypeLabels[route.type].split(" /")[0]} sx={{ height: 20, fontSize: 11 }} />
                      {isFallback ? <Chip size="small" color="primary" label="Fallback" sx={{ height: 20, fontSize: 11 }} /> : null}
                    </Stack>
                    <Typography variant="caption" color="text.secondary" component="div" sx={{ wordBreak: "break-word" }}>
                      {routeSummary(route)}
                    </Typography>
                  </Box>
                  <Stack direction="row" spacing={1} alignItems="center" flexWrap="wrap" useFlexGap>
                    <Button
                      size="small"
                      variant="outlined"
                      disabled={tests[index]?.state === "testing"}
                      startIcon={tests[index]?.state === "testing" ? <CircularProgress size={14} /> : <NetworkCheckIcon />}
                      onClick={() => void runTest(index, route)}
                      sx={{ flexShrink: 0, fontSize: 12, py: 0.25 }}
                    >
                      Test connection
                    </Button>
                    <RouteTestStatus test={tests[index]} />
                  </Stack>
                </Stack>
                <Stack direction={{ xs: "column", sm: "row" }} spacing={0.25} sx={{ flexShrink: 0 }}>
                  <Tooltip title={open ? "Close" : "Edit"}>
                    <IconButton size="small" onClick={() => setEditing(open ? null : index)}>
                      {open ? <ExpandLessIcon fontSize="small" /> : <EditOutlinedIcon fontSize="small" />}
                    </IconButton>
                  </Tooltip>
                  <Tooltip title={lastLocal ? "Keep at least one local route" : isFallback ? "Pick another fallback first" : "Delete"}>
                    <span>
                      <IconButton
                        size="small"
                        disabled={lastLocal || isFallback}
                        onClick={() => {
                          setEditing(null);
                          setTests({});
                          onDelete(index);
                        }}
                      >
                        <DeleteOutlineIcon fontSize="small" />
                      </IconButton>
                    </span>
                  </Tooltip>
                </Stack>
              </Stack>
              <Collapse in={open} unmountOnExit>
                <Box sx={{ pt: 1.5 }}>
                  <RouteEditor
                    route={route}
                    error={errors[index]}
                    onChange={(values) => {
                      setTests(({ [index]: _stale, ...rest }) => rest);
                      onChange(index, values);
                    }}
                  />
                </Box>
              </Collapse>
            </Paper>
          );
        })}
      </Stack>
      <Box>
        <Button startIcon={<AddIcon />} variant="outlined" size="small" onClick={(event) => setMenuAnchor(event.currentTarget)}>
          Add route
        </Button>
        <Menu anchorEl={menuAnchor} open={Boolean(menuAnchor)} onClose={() => setMenuAnchor(null)}>
          {(Object.keys(routeTypeLabels) as AiRouteType[]).map((type) => (
            <MenuItem
              key={type}
              onClick={() => {
                setMenuAnchor(null);
                onAdd(type);
                setEditing(routes.length);
              }}
            >
              {routeTypeLabels[type]}
            </MenuItem>
          ))}
        </Menu>
      </Box>
    </SettingsSection>
  );
}

type RouteTestState = { state: "testing" | "pass" | "fail"; text: string };

function RouteTestStatus({ test }: { test?: RouteTestState }) {
  if (!test) return null;
  const color = test.state === "pass" ? "success.main" : test.state === "fail" ? "error.main" : "text.secondary";
  return (
    <Typography variant="caption" component="div" sx={{ color, fontWeight: 600, wordBreak: "break-word", minWidth: 0 }}>
      {test.text}
    </Typography>
  );
}

function routeSummary(route: AiRoute) {
  if (CLI_ROUTE_TYPES.includes(route.type)) return `${route.bin || "CLI"} · ${route.model || "CLI default model"}`;
  if (API_ROUTE_TYPES.includes(route.type)) {
    return `${route.model || routeTypeInfo[route.type]?.model || "model"} · ${route.api_key ? "key set" : "no API key"}`;
  }
  return `${route.provider || "llama.cpp"} · ${route.selected_model || route.model || "no model"}`;
}

function RouteEditor({
  route,
  error,
  onChange
}: {
  route: AiRoute;
  error?: string;
  onChange: (values: Partial<AiRoute>) => void;
}) {
  const [loadingModels, setLoadingModels] = useState(false);
  const [modelError, setModelError] = useState("");
  const models = route.models || [];

  async function refreshModels() {
    setLoadingModels(true);
    setModelError("");
    try {
      const payload = await apiRequest<{ models: Array<{ name: string }> }>("/api/local-llm/models", {
        method: "POST",
        body: JSON.stringify({
          provider: route.provider || "llama.cpp",
          endpoint: route.endpoint || "",
          api_key: route.api_key || null
        })
      });
      const names = payload.models.map((model) => model.name).filter(Boolean);
      onChange({ models: names, ...(route.selected_model ? {} : { selected_model: names[0] || "", model: names[0] || "" }) });
    } catch (loadError) {
      setModelError(loadError instanceof Error ? loadError.message : "Could not load models.");
    } finally {
      setLoadingModels(false);
    }
  }

  const nameField = (
    <Grid size={{ xs: 12, sm: 6 }}>
      <TextField
        fullWidth
        size="small"
        label="Route name"
        value={route.name}
        error={Boolean(error)}
        helperText={error || "Shown in AI steps."}
        onChange={(event) => onChange({ name: event.target.value })}
      />
    </Grid>
  );

  if (CLI_ROUTE_TYPES.includes(route.type)) {
    const info = routeTypeInfo[route.type];
    return (
      <FieldGrid>
        {nameField}
        <Grid size={{ xs: 12, sm: 6 }}>
          <TextField
            fullWidth
            size="small"
            label="CLI binary"
            placeholder={info?.bin}
            value={route.bin || ""}
            onChange={(event) => onChange({ bin: event.target.value })}
            helperText={`${info?.help || ""} Uses the CLI’s own login (${info?.login || "login"}). Name or full path.`}
          />
        </Grid>
        <Grid size={{ xs: 12, sm: 6 }}>
          <TextField
            fullWidth
            size="small"
            label="Model"
            placeholder="CLI default"
            value={route.model || ""}
            onChange={(event) => onChange({ model: event.target.value })}
          />
        </Grid>
        <Grid size={{ xs: 12, sm: 6 }}>
          <TextField
            select
            fullWidth
            size="small"
            label="Reasoning effort"
            value={route.reasoning_effort || ""}
            onChange={(event) => onChange({ reasoning_effort: event.target.value })}
            SelectProps={{ displayEmpty: true }}
            InputLabelProps={{ shrink: true }}
          >
            <MenuItem value="">
              <em>CLI default</em>
            </MenuItem>
            {["low", "medium", "high"].map((effort) => (
              <MenuItem key={effort} value={effort}>
                {effort}
              </MenuItem>
            ))}
          </TextField>
        </Grid>
        <Grid size={{ xs: 6, sm: 4 }}>
          <NumberField label="Timeout (s)" value={route.timeout_seconds ?? 180} min={10} max={900} onChange={(value) => onChange({ timeout_seconds: value })} />
        </Grid>
        <Grid size={{ xs: 6, sm: 4 }}>
          <NumberField
            label="Correct timeout (s)"
            value={route.correct_timeout_seconds ?? 180}
            min={10}
            max={900}
            onChange={(value) => onChange({ correct_timeout_seconds: value })}
          />
        </Grid>
        <Grid size={{ xs: 6, sm: 4 }}>
          <NumberField
            label="Parallel typo chunks"
            value={route.typo_concurrency ?? 4}
            min={1}
            max={8}
            onChange={(value) => onChange({ typo_concurrency: value })}
          />
        </Grid>
      </FieldGrid>
    );
  }

  if (API_ROUTE_TYPES.includes(route.type)) {
    const info = routeTypeInfo[route.type];
    return (
      <FieldGrid>
        {nameField}
        <Grid size={{ xs: 12, sm: 6 }}>
          <TextField
            fullWidth
            size="small"
            label="Endpoint"
            value={route.endpoint || ""}
            onChange={(event) => onChange({ endpoint: event.target.value })}
            placeholder={info?.endpoint}
            helperText={info?.help}
          />
        </Grid>
        <Grid size={{ xs: 12, sm: 6 }}>
          <TextField
            fullWidth
            size="small"
            label="API key"
            type="password"
            value={route.api_key || ""}
            onChange={(event) => onChange({ api_key: event.target.value })}
            helperText="Leave blank to keep the saved key."
          />
        </Grid>
        <Grid size={{ xs: 12, sm: 3 }}>
          <TextField
            fullWidth
            size="small"
            label="Model"
            placeholder={info?.model}
            value={route.model || ""}
            onChange={(event) => onChange({ model: event.target.value })}
          />
        </Grid>
        <Grid size={{ xs: 12, sm: 3 }}>
          <NumberField
            label="Parallel typo chunks"
            value={route.typo_concurrency ?? 4}
            min={1}
            max={8}
            onChange={(value) => onChange({ typo_concurrency: value })}
          />
        </Grid>
      </FieldGrid>
    );
  }

  return (
    <Stack spacing={1.5}>
      <FieldGrid>
        {nameField}
        <Grid size={{ xs: 12, sm: 6 }}>
          <TextField
            select
            fullWidth
            size="small"
            label="Provider"
            value={route.provider || "llama.cpp"}
            onChange={(event) => onChange({ provider: event.target.value })}
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
            value={route.endpoint || ""}
            onChange={(event) => onChange({ endpoint: event.target.value })}
          />
        </Grid>
        <Grid size={{ xs: 12, sm: 6 }}>
          <TextField
            fullWidth
            size="small"
            label="API key"
            type="password"
            value={route.api_key || ""}
            onChange={(event) => onChange({ api_key: event.target.value })}
          />
        </Grid>
        <Grid size={{ xs: 12, sm: 6 }}>
          <Stack direction="row" spacing={1} alignItems="flex-start">
            <TextField
              select={models.length > 0}
              fullWidth
              size="small"
              label="Selected model"
              value={route.selected_model || route.model || ""}
              onChange={(event) => onChange({ selected_model: event.target.value, model: event.target.value })}
              error={Boolean(modelError)}
              helperText={modelError || undefined}
            >
              {models.map((model) => (
                <MenuItem key={model} value={model}>
                  {model}
                </MenuItem>
              ))}
            </TextField>
            <Tooltip title="Load models from the endpoint">
              <span>
                <IconButton size="small" disabled={loadingModels || !route.endpoint} onClick={() => void refreshModels()}>
                  <RefreshIcon fontSize="small" />
                </IconButton>
              </span>
            </Tooltip>
          </Stack>
        </Grid>
        <Grid size={{ xs: 6, sm: 3 }}>
          <NumberField
            label="Context length"
            value={route.contextLength ?? 8192}
            min={512}
            max={1048576}
            onChange={(value) => onChange({ contextLength: value })}
          />
        </Grid>
        <Grid size={{ xs: 6, sm: 3 }}>
          <TextField
            fullWidth
            size="small"
            label="Temperature"
            type="number"
            value={route.temperature ?? 0.4}
            onChange={(event) => onChange({ temperature: Number(event.target.value) })}
            inputProps={{ min: 0, max: 2, step: 0.1 }}
          />
        </Grid>
      </FieldGrid>
      <FormControlLabel
        control={
          <Switch
            checked={Boolean(route.disable_thinking)}
            onChange={(event) => onChange({ disable_thinking: event.target.checked })}
          />
        }
        label="Disable thinking for faster responses"
      />
      <TextField
        fullWidth
        size="small"
        label="Default system prompt"
        multiline
        minRows={3}
        value={route.system || ""}
        onChange={(event) => onChange({ system: event.target.value })}
      />
    </Stack>
  );
}

function NumberField({
  label,
  value,
  min,
  max,
  onChange
}: {
  label: string;
  value: number;
  min: number;
  max: number;
  onChange: (value: number) => void;
}) {
  return (
    <TextField
      fullWidth
      size="small"
      label={label}
      type="number"
      value={value}
      onChange={(event) => onChange(Math.min(max, Math.max(min, Number(event.target.value) || min)))}
      inputProps={{ min, max, step: 1 }}
    />
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
        sx={{ color: "text.secondary", fontWeight: 700, letterSpacing: 0.4, lineHeight: 1.2 }}
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
