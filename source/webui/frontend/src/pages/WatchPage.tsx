import AddIcon from "@mui/icons-material/Add";
import DeleteOutlineIcon from "@mui/icons-material/DeleteOutline";
import EditOutlinedIcon from "@mui/icons-material/EditOutlined";
import ExpandLessIcon from "@mui/icons-material/ExpandLess";
import ExpandMoreIcon from "@mui/icons-material/ExpandMore";
import PlayArrowOutlinedIcon from "@mui/icons-material/PlayArrowOutlined";
import ScienceOutlinedIcon from "@mui/icons-material/ScienceOutlined";
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Collapse,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  FormControlLabel,
  Grid,
  IconButton,
  Link,
  Stack,
  Switch,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Tooltip,
  Typography
} from "@mui/material";
import { useState } from "react";
import {
  useCreateWatchMutation,
  useDeleteWatchMutation,
  useProbeWatchMutation,
  useRunWatchMutation,
  useUpdateWatchMutation,
  useWatchesQuery,
  type WatchCheckResult,
  type WatchPostLog,
  type WatchTarget
} from "../api/watches";
import { formatDateTime } from "../utils/format";
import { PageScaffold, WorkspacePanel } from "./PageScaffold";

const statusChip: Record<string, { label: string; color: "default" | "info" | "success" | "error" | "warning" }> = {
  baseline: { label: "Baseline (not queued)", color: "default" },
  pending: { label: "Pending", color: "warning" },
  queued: { label: "Queued", color: "info" },
  running: { label: "Processing", color: "info" },
  completed: { label: "Ready to save", color: "success" },
  saved: { label: "Saved to Obsidian", color: "success" },
  failed: { label: "Failed", color: "error" },
  queue_failed: { label: "Queue failed", color: "error" }
};

function errorText(error: unknown) {
  return error instanceof Error ? error.message : String(error ?? "");
}

function mediaText(post: { text_length: number; image_count: number; video_count: number }) {
  const parts = [`${post.text_length} chars`];
  if (post.image_count) parts.push(`${post.image_count} images`);
  if (post.video_count) parts.push(`${post.video_count} videos`);
  return parts.join(" · ");
}

function CheckResultView({ result }: { result: WatchCheckResult }) {
  return (
    <Stack spacing={1}>
      <Alert severity={result.ok ? "success" : "error"} variant="outlined">
        {result.dry_run ? "[Test] " : ""}
        {result.message}
        {result.fetch ? ` (via ${result.fetch === "cookies" ? "signed-in cookies" : "public page"})` : ""}
      </Alert>
      {result.latest?.length ? (
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Post</TableCell>
              <TableCell sx={{ whiteSpace: "nowrap" }}>Posted</TableCell>
              <TableCell sx={{ whiteSpace: "nowrap" }}>Content</TableCell>
              <TableCell align="right">Status</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {result.latest.map((post) => (
              <TableRow key={post.code}>
                <TableCell sx={{ maxWidth: 420 }}>
                  <Typography variant="body2" noWrap>
                    <Link href={post.url} target="_blank" rel="noreferrer" underline="hover">
                      {post.title || post.code}
                    </Link>
                  </Typography>
                </TableCell>
                <TableCell sx={{ whiteSpace: "nowrap" }}>{formatDateTime(post.post_created_at ?? undefined)}</TableCell>
                <TableCell sx={{ whiteSpace: "nowrap" }}>{mediaText(post)}</TableCell>
                <TableCell align="right">
                  <Chip size="small" variant="outlined" label={post.seen ? "Seen" : "New"} color={post.seen ? "default" : "primary"} />
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      ) : null}
    </Stack>
  );
}

function AddWatchPanel({ minInterval }: { minInterval: number }) {
  const [target, setTarget] = useState("");
  const [label, setLabel] = useState("");
  const [interval, setInterval] = useState(60);
  const [queueLatest, setQueueLatest] = useState(0);
  const [enabled, setEnabled] = useState(true);
  const probe = useProbeWatchMutation();
  const create = useCreateWatchMutation();
  const intervalError = interval < minInterval;

  async function handleCreate() {
    await create.mutateAsync({ target, label, interval_minutes: interval, enabled, queue_latest: queueLatest });
    setTarget("");
    setLabel("");
    probe.reset();
  }

  return (
    <WorkspacePanel>
      <Stack spacing={2}>
        <Box>
          <Typography variant="h3">Add a watch</Typography>
          <Typography variant="caption" color="text.secondary">
            Paste a Threads username (@name) or profile URL. The first check records current posts as a baseline;
            later new posts are queued into Obsidian Clipper. You still save them yourself.
          </Typography>
        </Box>
        <Grid container spacing={2}>
          <Grid size={{ xs: 12, md: 5 }}>
            <TextField
              fullWidth
              size="small"
              label="Threads username or URL"
              placeholder="@n.ina3373 or https://www.threads.com/@n.ina3373"
              value={target}
              onChange={(event) => setTarget(event.target.value)}
            />
          </Grid>
          <Grid size={{ xs: 12, md: 3 }}>
            <TextField fullWidth size="small" label="Label (optional)" value={label} onChange={(event) => setLabel(event.target.value)} />
          </Grid>
          <Grid size={{ xs: 6, md: 2 }}>
            <TextField
              fullWidth
              size="small"
              type="number"
              label="Interval (minutes)"
              value={interval}
              error={intervalError}
              helperText={intervalError ? `Minimum ${minInterval} minutes` : " "}
              slotProps={{ htmlInput: { min: minInterval, step: 15 } }}
              onChange={(event) => setInterval(Number(event.target.value))}
            />
          </Grid>
          <Grid size={{ xs: 6, md: 2 }}>
            <TextField
              fullWidth
              size="small"
              type="number"
              label="Queue latest N posts"
              value={queueLatest}
              helperText="0 = baseline only"
              slotProps={{ htmlInput: { min: 0, max: 10 } }}
              onChange={(event) => setQueueLatest(Math.max(0, Math.min(10, Number(event.target.value) || 0)))}
            />
          </Grid>
        </Grid>
        <Stack direction="row" spacing={1} alignItems="center" flexWrap="wrap" useFlexGap>
          <FormControlLabel control={<Switch checked={enabled} onChange={(event) => setEnabled(event.target.checked)} />} label="Enable schedule" />
          <Box sx={{ flex: 1 }} />
          <Button
            variant="outlined"
            startIcon={probe.isPending ? <CircularProgress size={16} /> : <ScienceOutlinedIcon />}
            disabled={!target.trim() || probe.isPending}
            onClick={() => probe.mutate(target)}
          >
            Test
          </Button>
          <Button
            variant="contained"
            startIcon={create.isPending ? <CircularProgress size={16} color="inherit" /> : <AddIcon />}
            disabled={!target.trim() || intervalError || create.isPending}
            onClick={() => void handleCreate().catch(() => undefined)}
          >
            Add
          </Button>
        </Stack>
        {probe.isError ? <Alert severity="error">{errorText(probe.error)}</Alert> : null}
        {create.isError ? <Alert severity="error">{errorText(create.error)}</Alert> : null}
        {probe.data ? (
          <Stack spacing={1}>
            <Typography variant="body2">
              Parsed as{" "}
              <Link href={probe.data.profile_url} target="_blank" rel="noreferrer">
                @{probe.data.username}
              </Link>
            </Typography>
            <CheckResultView result={probe.data.result} />
          </Stack>
        ) : null}
      </Stack>
    </WorkspacePanel>
  );
}

function EditDialog({ target, minInterval, onClose }: { target: WatchTarget; minInterval: number; onClose: () => void }) {
  const [label, setLabel] = useState(target.label);
  const [interval, setInterval] = useState(target.interval_minutes);
  const update = useUpdateWatchMutation();
  const intervalError = interval < minInterval;
  return (
    <Dialog open onClose={onClose} fullWidth maxWidth="xs">
      <DialogTitle>Edit @{target.username}</DialogTitle>
      <DialogContent>
        <Stack spacing={2} sx={{ pt: 1 }}>
          <TextField size="small" label="Label" value={label} onChange={(event) => setLabel(event.target.value)} />
          <TextField
            size="small"
            type="number"
            label="Interval (minutes)"
            value={interval}
            error={intervalError}
            helperText={intervalError ? `Minimum ${minInterval} minutes` : " "}
            slotProps={{ htmlInput: { min: minInterval, step: 15 } }}
            onChange={(event) => setInterval(Number(event.target.value))}
          />
          {update.isError ? <Alert severity="error">{errorText(update.error)}</Alert> : null}
        </Stack>
      </DialogContent>
      <DialogActions>
        <Button onClick={onClose}>Cancel</Button>
        <Button
          variant="contained"
          disabled={intervalError || update.isPending}
          onClick={() => void update.mutateAsync({ id: target.id, label, interval_minutes: interval }).then(onClose, () => undefined)}
        >
          Save
        </Button>
      </DialogActions>
    </Dialog>
  );
}

function PostLogTable({ posts }: { posts: WatchPostLog[] }) {
  if (!posts.length) return <Typography color="text.secondary">No posts recorded yet.</Typography>;
  return (
    <Table size="small">
      <TableHead>
        <TableRow>
          <TableCell>Post</TableCell>
          <TableCell sx={{ whiteSpace: "nowrap" }}>Posted</TableCell>
          <TableCell sx={{ whiteSpace: "nowrap" }}>Found / queued</TableCell>
          <TableCell sx={{ whiteSpace: "nowrap" }}>Content</TableCell>
          <TableCell align="right">Status</TableCell>
        </TableRow>
      </TableHead>
      <TableBody>
        {posts.map((post) => {
          const chip = statusChip[post.status] ?? { label: post.status, color: "default" as const };
          return (
            <TableRow key={post.code}>
              <TableCell sx={{ maxWidth: 380 }}>
                <Typography variant="body2" noWrap>
                  <Link href={post.url} target="_blank" rel="noreferrer" underline="hover">
                    {post.title || post.code}
                  </Link>
                </Typography>
                {post.error ? (
                  <Typography variant="caption" color="error.main">
                    {post.error}
                  </Typography>
                ) : null}
              </TableCell>
              <TableCell sx={{ whiteSpace: "nowrap" }}>{formatDateTime(post.post_created_at ?? undefined)}</TableCell>
              <TableCell sx={{ whiteSpace: "nowrap" }}>
                {formatDateTime(post.discovered_at)}
                {post.queued_at ? ` / ${formatDateTime(post.queued_at)}` : ""}
              </TableCell>
              <TableCell sx={{ whiteSpace: "nowrap" }}>{mediaText(post)}</TableCell>
              <TableCell align="right">
                <Chip size="small" variant="outlined" label={chip.label} color={chip.color} />
              </TableCell>
            </TableRow>
          );
        })}
      </TableBody>
    </Table>
  );
}

function WatchCard({ target, minInterval }: { target: WatchTarget; minInterval: number }) {
  const [expanded, setExpanded] = useState(false);
  const [editing, setEditing] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [lastRun, setLastRun] = useState<WatchCheckResult | null>(null);
  const update = useUpdateWatchMutation();
  const remove = useDeleteWatchMutation();
  const run = useRunWatchMutation();
  const result = target.last_result;

  function runCheck(mode: "test" | "check") {
    run.mutate(
      { id: target.id, mode },
      {
        onSuccess: (data) => {
          setLastRun(data.result);
          setExpanded(true);
        }
      }
    );
  }

  return (
    <WorkspacePanel>
      <Stack spacing={1.5}>
        <Stack direction={{ xs: "column", md: "row" }} spacing={1.5} alignItems={{ md: "center" }}>
          <Box sx={{ flex: 1, minWidth: 0 }}>
            <Stack direction="row" spacing={1} alignItems="center" flexWrap="wrap" useFlexGap>
              <Typography variant="h3">{target.label}</Typography>
              <Link href={target.profile_url} target="_blank" rel="noreferrer" variant="body2">
                @{target.username}
              </Link>
              <Chip size="small" variant="outlined" label="Threads" />
              <Chip size="small" variant="outlined" label={`Every ${target.interval_minutes} min`} />
              {!target.enabled ? <Chip size="small" label="Disabled" /> : null}
            </Stack>
            <Typography variant="body2" color="text.secondary" sx={{ mt: 0.5 }}>
              Last check {formatDateTime(target.last_checked_at ?? undefined)} · Next check{" "}
              {target.enabled ? formatDateTime(target.next_check_at ?? undefined) : "-- (disabled)"} · {target.post_count}{" "}
              posts recorded, {target.queued_count} queued
            </Typography>
          </Box>
          <Stack direction="row" spacing={0.5} alignItems="center">
            <Tooltip title={target.enabled ? "Disable schedule" : "Enable schedule"}>
              <Switch
                checked={target.enabled}
                disabled={update.isPending}
                onChange={(event) => update.mutate({ id: target.id, enabled: event.target.checked })}
              />
            </Tooltip>
            <Button
              size="small"
              variant="outlined"
              startIcon={run.isPending && run.variables?.mode === "test" ? <CircularProgress size={14} /> : <ScienceOutlinedIcon />}
              disabled={run.isPending}
              onClick={() => runCheck("test")}
            >
              Test
            </Button>
            <Tooltip title="Check now. New posts will be queued into Obsidian Clipper.">
              <span>
                <Button
                  size="small"
                  variant="contained"
                  startIcon={run.isPending && run.variables?.mode === "check" ? <CircularProgress size={14} color="inherit" /> : <PlayArrowOutlinedIcon />}
                  disabled={run.isPending}
                  onClick={() => runCheck("check")}
                >
                  Check now
                </Button>
              </span>
            </Tooltip>
            <IconButton size="small" onClick={() => setEditing(true)}>
              <EditOutlinedIcon fontSize="small" />
            </IconButton>
            <IconButton size="small" color="error" onClick={() => setConfirmDelete(true)}>
              <DeleteOutlineIcon fontSize="small" />
            </IconButton>
            <IconButton size="small" onClick={() => setExpanded((value) => !value)}>
              {expanded ? <ExpandLessIcon /> : <ExpandMoreIcon />}
            </IconButton>
          </Stack>
        </Stack>
        {result ? (
          <Alert severity={result.ok ? "success" : "error"} variant="outlined" sx={{ py: 0 }}>
            {formatDateTime(result.checked_at)}: {result.message}
            {result.ok ? ` (${result.new_posts} new posts this run)` : ""}
          </Alert>
        ) : (
          <Alert severity="info" variant="outlined" sx={{ py: 0 }}>
            Not checked yet. {target.enabled ? "The schedule will run the first check within a minute and record a baseline." : "Enable the schedule to start checking."}
          </Alert>
        )}
        {run.isError ? <Alert severity="error">{errorText(run.error)}</Alert> : null}
        <Collapse in={expanded} unmountOnExit>
          <Stack spacing={2}>
            {lastRun ? <CheckResultView result={lastRun} /> : null}
            <Box>
              <Typography variant="body2" fontWeight={700} sx={{ mb: 0.5 }}>
                Post log
              </Typography>
              <PostLogTable posts={target.posts} />
            </Box>
          </Stack>
        </Collapse>
      </Stack>
      {editing ? <EditDialog target={target} minInterval={minInterval} onClose={() => setEditing(false)} /> : null}
      <Dialog open={confirmDelete} onClose={() => setConfirmDelete(false)}>
        <DialogTitle>Delete this watch?</DialogTitle>
        <DialogContent>
          <Typography>
            This removes @{target.username}'s settings and post log. Items already queued in Obsidian Clipper are not affected.
          </Typography>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setConfirmDelete(false)}>Cancel</Button>
          <Button color="error" variant="contained" disabled={remove.isPending} onClick={() => remove.mutate(target.id)}>
            Delete
          </Button>
        </DialogActions>
      </Dialog>
    </WorkspacePanel>
  );
}

export function WatchPage() {
  const watches = useWatchesQuery();
  const minInterval = watches.data?.min_interval_minutes ?? 15;
  return (
    <PageScaffold title="Watching" eyebrow="Scheduled checks">
      <AddWatchPanel minInterval={minInterval} />
      {watches.isError ? <Alert severity="error">Could not load watches: {errorText(watches.error)}</Alert> : null}
      {watches.data && !watches.data.scheduler_running ? (
        <Alert severity="warning">The scheduler is not running in this WebUI process. You can only check manually.</Alert>
      ) : null}
      {watches.data?.watches.length === 0 ? (
        <Typography color="text.secondary">No accounts are being watched yet.</Typography>
      ) : null}
      {watches.data?.watches.map((target) => <WatchCard key={target.id} target={target} minInterval={minInterval} />)}
    </PageScaffold>
  );
}
