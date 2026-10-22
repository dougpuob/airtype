import CloseRoundedIcon from "@mui/icons-material/CloseRounded";
import { Box, Button, Chip, IconButton, LinearProgress, Typography } from "@mui/material";
import { useLocation, useNavigate } from "react-router-dom";
import { useCancelClipRequestMutation, useDeleteClipRequestMutation, type ClipRequest } from "../../api/clipRequests";
import { useSettingsQuery } from "../../api/settings";
import { openObsidianDraft } from "../../utils/obsidian";
import { useSaveClipRequestMutation } from "../../api/clipRequests";
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

export function TaskQueue({ onOpenRequest }: { onOpenRequest?: () => void } = {}) {
  const { requests, selectedId, select } = useClipRequestSelection();
  const cancelClip = useCancelClipRequestMutation();
  const deleteClip = useDeleteClipRequestMutation();
  const saveClip = useSaveClipRequestMutation();
  const settingsQuery = useSettingsQuery();
  const navigate = useNavigate();
  const location = useLocation();

  function openRequest(id: string) {
    select(id);
    if (location.pathname !== "/v-to-text") navigate("/v-to-text");
    onOpenRequest?.();
  }

  async function saveRequest(request: ClipRequest) {
    if (request.status !== "completed" || !request.note) return;
    await openObsidianDraft(
      { noteTitle: request.note_title || request.title || "Untitled", note: request.note },
      {
        defaultFolder: settingsQuery.data?.obsidian?.default_folder,
        vaultName: settingsQuery.data?.obsidian?.vault_name
      }
    );
    await saveClip.mutateAsync(request.id);
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
                    <Chip
                      size="small"
                      color={clipOrigin(task) === "watching" ? "secondary" : "primary"}
                      label={clipOriginLabel(clipOrigin(task))}
                      sx={{ height: 18, "& .MuiChip-label": { px: 0.75, fontSize: 10 } }}
                    />
                    <Chip
                      size="small"
                      variant="outlined"
                      label={clipKindLabel(task.kind)}
                      sx={{ height: 18, "& .MuiChip-label": { px: 0.75, fontSize: 10 } }}
                    />
                    <Typography variant="caption" fontWeight={600} noWrap>
                      {formatClipTime(task.id)}
                    </Typography>
                  </Box>
                  <Typography variant="caption" fontWeight={600} noWrap sx={{ color: statusColor[task.status] || "#647084" }}>
                    {statusLabel[task.status] || task.status}
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
                    disabled={!task.note || saveClip.isPending}
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
