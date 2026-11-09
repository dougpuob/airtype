import CloseRoundedIcon from "@mui/icons-material/CloseRounded";
import { Box, Button, Chip, Collapse, IconButton, LinearProgress, Typography, useMediaQuery, useTheme } from "@mui/material";
import { useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { useCancelClipRequestMutation, useDeleteClipRequestMutation, useObsidianExportWatch, type ClipRequest } from "../../api/clipRequests";
import { useSettingsQuery } from "../../api/settings";
import { useObsidianExportMutation } from "../../api/obsidianExports";
import { obsidianSaveStatusText, type ObsidianSaveStatus } from "../../api/obsidianExportWatch";
import { openObsidianDraft } from "../../utils/obsidian";
import { clipHasNote, loadFullClipRequest, useSaveClipRequestMutation } from "../../api/clipRequests";
import { useClipRequestSelection } from "./ClipRequestContext";

const statusLabel: Record<string, string> = {
  queued: "Queued",
  running: "In progress",
  completed: "Done",
  failed: "Failed"
};

const statusColor: Record<string, string> = {
  queued: "#647084",
  running: "#4052BA",
  completed: "#1F7A4D",
  failed: "#B42318"
};

const kindLabel: Record<string, string> = {
  voice: "Voice",
  article: "Article",
  post: "Post"
};

export function clipOrigin(request: Pick<ClipRequest, "origin">) {
  return request.origin === "watching" ? "watching" : "manual";
}

export function clipOriginLabel(origin: string) {
  return origin === "watching" ? "Watching" : "Manual";
}

export function clipKindLabel(kind: string) {
  return kindLabel[kind] || kind;
}

const platformNames: Array<[RegExp, string]> = [
  [/(^|\.)threads\.(net|com)$/, "Threads"],
  [/(^|\.)instagram\.com$/, "Instagram"],
  [/(^|\.)(x|twitter)\.com$/, "X"],
  [/(^|\.)(youtube\.com|youtu\.be)$/, "YouTube"],
  [/(^|\.)(bilibili\.com|b23\.tv)$/, "Bilibili"],
  [/(^|\.)facebook\.com$/, "Facebook"]
];

const reservedPaths = new Set(["p", "reel", "reels", "post", "watch", "shorts", "video", "status", "i", "home", "explore"]);

/** Platform and account parsed from a clip URL, e.g. "Threads @n.ina3373". */
export function clipAccount(source: string) {
  let url: URL;
  try {
    url = new URL(source);
  } catch {
    return "";
  }
  const host = url.hostname.replace(/^www\./, "").replace(/^m\./, "");
  const platform = platformNames.find(([pattern]) => pattern.test(host))?.[1] || host;
  const first = decodeURIComponent(url.pathname.split("/").filter(Boolean)[0] || "");
  let user = "";
  if (first.startsWith("@")) user = first;
  else if (["Threads", "Instagram", "X"].includes(platform) && first && !reservedPaths.has(first.toLowerCase())) user = `@${first}`;
  return user ? `${platform} ${user}` : platform;
}

export function TaskQueue({ onOpenRequest }: { onOpenRequest?: () => void } = {}) {
  const theme = useTheme();
  const isMobile = useMediaQuery(theme.breakpoints.down("sm"));
  const { requests, selectedId, select } = useClipRequestSelection();
  const cancelClip = useCancelClipRequestMutation();
  const deleteClip = useDeleteClipRequestMutation();
  const saveClip = useSaveClipRequestMutation();
  const exportObsidian = useObsidianExportMutation();
  const exportWatch = useObsidianExportWatch();
  const readyCount = requests.filter((item) => item.status === "completed" && clipHasNote(item)).length;
  const saving = saveClip.isPending || exportObsidian.isPending;
  const [notice, setNotice] = useState<ObsidianSaveStatus | null>(null);
  const noticePhase = useRef<"idle" | "opening" | "waiting" | "saved" | "error">("idle");

  function showNotice(next: ObsidianSaveStatus, phase: typeof noticePhase.current) {
    noticePhase.current = phase;
    setNotice(next);
  }

  useEffect(() => {
    const status = obsidianSaveStatusText(
      exportWatch,
      requests.map((item) => item.id),
      Date.now()
    );
    if (!status) return;
    if (status.tone === "success") showNotice(status, "saved");
    else if (status.tone === "error") showNotice(status, "error");
    else if (noticePhase.current !== "error") showNotice(status, "waiting");
  }, [exportWatch, requests]);

  useEffect(() => {
    if (!exportWatch) return;
    const delay = Math.max(0, exportWatch.untilMs - Date.now()) + 50;
    const timer = window.setTimeout(() => {
      if (noticePhase.current === "opening" || noticePhase.current === "waiting") {
        showNotice({ tone: "error", text: "AirType has not confirmed this save yet" }, "error");
      }
    }, delay);
    return () => window.clearTimeout(timer);
  }, [exportWatch]);

  async function saveAllRequests() {
    showNotice({ tone: "info", text: "Opening AirType…" }, "opening");
    try {
      await exportObsidian.mutateAsync(undefined);
    } catch (error) {
      showNotice(
        { tone: "error", text: `Save failed: ${error instanceof Error ? error.message : String(error)}` },
        "error"
      );
    }
  }
  const settingsQuery = useSettingsQuery();
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const location = useLocation();

  function openRequest(id: string) {
    select(id);
    if (location.pathname !== "/v-to-text") navigate("/v-to-text");
    onOpenRequest?.();
  }

  async function saveRequest(request: ClipRequest) {
    if (request.status !== "completed" || !clipHasNote(request)) return;
    if (!isMobile) {
      showNotice({ tone: "info", text: "Opening AirType…" }, "opening");
      try {
        await exportObsidian.mutateAsync([request.id]);
      } catch (error) {
        showNotice(
          { tone: "error", text: `Save failed: ${error instanceof Error ? error.message : String(error)}` },
          "error"
        );
      }
      return;
    }
    // Mobile: mark saved before opening Obsidian. obsidian:// switches away
    // from the browser and can cancel the mark-saved request if it runs after.
    const full = await loadFullClipRequest(queryClient, request);
    if (!full.note) return;
    await saveClip.mutateAsync(request.id);
    await openObsidianDraft(
      { noteTitle: full.note_title || full.title || "Untitled", note: full.note },
      {
        defaultFolder: settingsQuery.data?.obsidian?.default_folder,
        vaultName: settingsQuery.data?.obsidian?.vault_name
      }
    );
  }

  return (
    <Box sx={{ flex: 1, minHeight: 0, display: "flex", flexDirection: "column", mt: 2, mb: 1 }}>
      <Typography
        variant="overline"
        sx={{
          color: "text.secondary",
          fontSize: 11,
          fontWeight: 700,
          letterSpacing: 0.4,
          px: 1.5,
          mb: 1,
          textTransform: "none"
        }}
      >
        Not saved to Obsidian
      </Typography>
      <Collapse in={Boolean(notice)}>
        <Box
          role="status"
          aria-live="polite"
          sx={{
            mx: 1,
            mb: 1,
            px: 1,
            py: 0.75,
            borderRadius: 1,
            fontSize: 12,
            fontWeight: 600,
            lineHeight: 1.4,
            ...(notice?.tone === "success"
              ? { bgcolor: "#E8F6EE", color: "#1F7A4D" }
              : notice?.tone === "error"
                ? { bgcolor: "#FDECEC", color: "#B42318" }
                : { bgcolor: "#EEF1FF", color: "#4052BA" })
          }}
        >
          {notice?.text}
        </Box>
      </Collapse>
      {!isMobile && readyCount > 0 ? (
        <Button
          size="small"
          variant="contained"
          disabled={saving}
          onClick={() => void saveAllRequests()}
          sx={{ mx: 1, mb: 1, textTransform: "none" }}
        >
          {exportObsidian.isPending ? "Saving…" : `Save all to Obsidian (${readyCount})`}
        </Button>
      ) : null}
      <Box sx={{ flex: 1, minHeight: 0, overflowY: "auto", px: 0.5 }}>
        {requests.length === 0 ? (
          <Typography variant="body2" color="text.secondary" sx={{ px: 1, py: 1 }}>
            No pending requests
          </Typography>
        ) : (
          requests.map((task) => {
            const selected = task.id === selectedId;
            return (
              <Box
                key={task.id}
                onClick={() => openRequest(task.id)}
                sx={{
                  position: "relative",
                  mb: 0.75,
                  p: 1,
                  pr: 3.5,
                  border: 1,
                  borderColor: selected ? "primary.main" : "divider",
                  borderRadius: 1,
                  bgcolor: selected ? "primary.light" : "background.paper",
                  cursor: "pointer"
                }}
              >
                <IconButton
                  aria-label="Delete"
                  size="small"
                  onClick={(event) => {
                    event.stopPropagation();
                    void deleteClip.mutateAsync(task.id);
                  }}
                  sx={{
                    position: "absolute",
                    top: 2,
                    right: 2,
                    width: 22,
                    height: 22,
                    color: "text.secondary"
                  }}
                >
                  <CloseRoundedIcon sx={{ fontSize: 16 }} />
                </IconButton>
                <Box sx={{ display: "flex", justifyContent: "space-between", gap: 1, mb: 0.25, alignItems: "center" }}>
                  <Box sx={{ display: "flex", alignItems: "center", gap: 0.5, minWidth: 0, flex: 1 }}>
                    <Typography variant="caption" fontWeight={600} noWrap>
                      {formatClipTime(task.id)}
                    </Typography>
                    <Chip
                      size="small"
                      variant="outlined"
                      label={clipKindLabel(task.kind)}
                      sx={{ height: 18, "& .MuiChip-label": { px: 0.75, fontSize: 10 } }}
                    />
                  </Box>
                  <Typography variant="caption" fontWeight={600} noWrap sx={{ color: statusColor[task.status] || "#647084" }}>
                    {statusLabel[task.status] || task.status}
                  </Typography>
                </Box>
                <Box sx={{ display: "flex", alignItems: "center", gap: 0.5, minWidth: 0, mb: 0.25 }}>
                  <Chip
                    size="small"
                    color={clipOrigin(task) === "watching" ? "secondary" : "primary"}
                    label={clipOriginLabel(clipOrigin(task))}
                    sx={{ height: 18, flexShrink: 0, "& .MuiChip-label": { px: 0.75, fontSize: 10 } }}
                  />
                  <Typography variant="caption" fontWeight={600} noWrap sx={{ minWidth: 0 }}>
                    {clipAccount(task.source)}
                  </Typography>
                </Box>
                <Typography
                  variant="caption"
                  color="text.secondary"
                  sx={{ display: "block", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}
                >
                  {task.source}
                </Typography>
                {task.notes?.trim() ? (
                  <Typography
                    variant="caption"
                    color="text.primary"
                    sx={{ display: "block", mt: 0.25, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}
                  >
                    {task.notes}
                  </Typography>
                ) : null}
                {task.status === "running" ? (
                  <Box sx={{ mt: 0.75 }}>
                    <Typography variant="caption" color="text.secondary">
                      {task.message || "In progress"} {Math.round(task.progress || 0)}%
                    </Typography>
                    <LinearProgress
                      variant="determinate"
                      value={Math.max(0, Math.min(100, task.progress || 0))}
                      sx={{ mt: 0.5, height: 4, borderRadius: 99 }}
                    />
                  </Box>
                ) : null}
                {task.status === "failed" && task.error ? (
                  <Typography variant="caption" color="error" sx={{ display: "block", mt: 0.5 }}>
                    {task.error}
                  </Typography>
                ) : null}
                {task.status === "queued" || task.status === "running" ? (
                  <Button
                    size="small"
                    variant="outlined"
                    color="inherit"
                    fullWidth
                    onClick={(event) => {
                      event.stopPropagation();
                      void cancelClip.mutateAsync(task.id);
                    }}
                    sx={{ mt: 0.75, minHeight: 28, py: 0, fontSize: 12 }}
                  >
                    Stop
                  </Button>
                ) : null}
                {task.status === "completed" ? (
                  <Button
                    size="small"
                    variant="contained"
                    fullWidth
                    disabled={!clipHasNote(task) || saving}
                    onClick={(event) => {
                      event.stopPropagation();
                      void saveRequest(task);
                    }}
                    sx={{ mt: 0.75, minHeight: 28, py: 0, fontSize: 12 }}
                  >
                    Save to Obsidian
                  </Button>
                ) : null}
              </Box>
            );
          })
        )}
      </Box>
    </Box>
  );
}

export function formatClipTime(id: string) {
  const match = /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})/.exec(id);
  if (!match) return id;
  return `${match[2]}/${match[3]} ${match[4]}:${match[5]}`;
}

export function clipStatusLabel(status: string) {
  return statusLabel[status] || status;
}
