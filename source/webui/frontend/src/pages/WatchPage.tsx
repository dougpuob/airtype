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
  baseline: { label: "基準（未排入）", color: "default" },
  pending: { label: "待排入", color: "warning" },
  queued: { label: "已排入", color: "info" },
  running: { label: "處理中", color: "info" },
  completed: { label: "待存檔", color: "success" },
  saved: { label: "已存進 Obsidian", color: "success" },
  failed: { label: "失敗", color: "error" },
  queue_failed: { label: "排入失敗", color: "error" }
};

function errorText(error: unknown) {
  return error instanceof Error ? error.message : String(error ?? "");
}

function mediaText(post: { text_length: number; image_count: number; video_count: number }) {
  const parts = [`${post.text_length} 字`];
  if (post.image_count) parts.push(`${post.image_count} 圖`);
  if (post.video_count) parts.push(`${post.video_count} 影片`);
  return parts.join(" · ");
}

function CheckResultView({ result }: { result: WatchCheckResult }) {
  return (
    <Stack spacing={1}>
      <Alert severity={result.ok ? "success" : "error"} variant="outlined">
        {result.dry_run ? "【測試】" : ""}
        {result.message}
        {result.fetch ? `（讀取方式：${result.fetch === "cookies" ? "登入 cookies" : "公開頁面"}）` : ""}
      </Alert>
      {result.latest?.length ? (
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>貼文</TableCell>
              <TableCell sx={{ whiteSpace: "nowrap" }}>發文時間</TableCell>
              <TableCell sx={{ whiteSpace: "nowrap" }}>內容</TableCell>
              <TableCell align="right">狀態</TableCell>
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
                  <Chip size="small" variant="outlined" label={post.seen ? "已看過" : "新"} color={post.seen ? "default" : "primary"} />
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
          <Typography variant="h3">新增追蹤</Typography>
          <Typography variant="caption" color="text.secondary">
            貼上 Threads 帳號（@name）或個人頁網址。新增後會先記下目前的貼文當基準，之後有新貼文才排進 Obsidian Clipper，存檔仍由你手動按。
          </Typography>
        </Box>
        <Grid container spacing={2}>
          <Grid size={{ xs: 12, md: 5 }}>
            <TextField
              fullWidth
              size="small"
              label="Threads 帳號或網址"
              placeholder="@n.ina3373 或 https://www.threads.com/@n.ina3373"
              value={target}
              onChange={(event) => setTarget(event.target.value)}
            />
          </Grid>
          <Grid size={{ xs: 12, md: 3 }}>
            <TextField fullWidth size="small" label="名稱（可留空）" value={label} onChange={(event) => setLabel(event.target.value)} />
          </Grid>
          <Grid size={{ xs: 6, md: 2 }}>
            <TextField
              fullWidth
              size="small"
              type="number"
              label="檢查間隔（分鐘）"
              value={interval}
              error={intervalError}
              helperText={intervalError ? `最少 ${minInterval} 分鐘` : " "}
              slotProps={{ htmlInput: { min: minInterval, step: 15 } }}
              onChange={(event) => setInterval(Number(event.target.value))}
            />
          </Grid>
          <Grid size={{ xs: 6, md: 2 }}>
            <TextField
              fullWidth
              size="small"
              type="number"
              label="同時排入最新 N 篇"
              value={queueLatest}
              helperText="0 = 只記基準"
              slotProps={{ htmlInput: { min: 0, max: 10 } }}
              onChange={(event) => setQueueLatest(Math.max(0, Math.min(10, Number(event.target.value) || 0)))}
            />
          </Grid>
        </Grid>
        <Stack direction="row" spacing={1} alignItems="center" flexWrap="wrap" useFlexGap>
          <FormControlLabel control={<Switch checked={enabled} onChange={(event) => setEnabled(event.target.checked)} />} label="啟用排程" />
          <Box sx={{ flex: 1 }} />
          <Button
            variant="outlined"
            startIcon={probe.isPending ? <CircularProgress size={16} /> : <ScienceOutlinedIcon />}
            disabled={!target.trim() || probe.isPending}
            onClick={() => probe.mutate(target)}
          >
            測試
          </Button>
          <Button
            variant="contained"
            startIcon={create.isPending ? <CircularProgress size={16} color="inherit" /> : <AddIcon />}
            disabled={!target.trim() || intervalError || create.isPending}
            onClick={() => void handleCreate().catch(() => undefined)}
          >
            新增
          </Button>
        </Stack>
        {probe.isError ? <Alert severity="error">{errorText(probe.error)}</Alert> : null}
        {create.isError ? <Alert severity="error">{errorText(create.error)}</Alert> : null}
        {probe.data ? (
          <Stack spacing={1}>
            <Typography variant="body2">
              解析為{" "}
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
      <DialogTitle>編輯 @{target.username}</DialogTitle>
      <DialogContent>
        <Stack spacing={2} sx={{ pt: 1 }}>
          <TextField size="small" label="名稱" value={label} onChange={(event) => setLabel(event.target.value)} />
          <TextField
            size="small"
            type="number"
            label="檢查間隔（分鐘）"
            value={interval}
            error={intervalError}
            helperText={intervalError ? `最少 ${minInterval} 分鐘` : " "}
            slotProps={{ htmlInput: { min: minInterval, step: 15 } }}
            onChange={(event) => setInterval(Number(event.target.value))}
          />
          {update.isError ? <Alert severity="error">{errorText(update.error)}</Alert> : null}
        </Stack>
      </DialogContent>
      <DialogActions>
        <Button onClick={onClose}>取消</Button>
        <Button
          variant="contained"
          disabled={intervalError || update.isPending}
          onClick={() => void update.mutateAsync({ id: target.id, label, interval_minutes: interval }).then(onClose, () => undefined)}
        >
          儲存
        </Button>
      </DialogActions>
    </Dialog>
  );
}

function PostLogTable({ posts }: { posts: WatchPostLog[] }) {
  if (!posts.length) return <Typography color="text.secondary">還沒有紀錄。</Typography>;
  return (
    <Table size="small">
      <TableHead>
        <TableRow>
          <TableCell>貼文</TableCell>
          <TableCell sx={{ whiteSpace: "nowrap" }}>發文時間</TableCell>
          <TableCell sx={{ whiteSpace: "nowrap" }}>發現 / 排入</TableCell>
          <TableCell sx={{ whiteSpace: "nowrap" }}>內容</TableCell>
          <TableCell align="right">狀態</TableCell>
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
              <Chip size="small" variant="outlined" label={`每 ${target.interval_minutes} 分鐘`} />
              {!target.enabled ? <Chip size="small" label="已停用" /> : null}
            </Stack>
            <Typography variant="body2" color="text.secondary" sx={{ mt: 0.5 }}>
              上次檢查 {formatDateTime(target.last_checked_at ?? undefined)} · 下次檢查{" "}
              {target.enabled ? formatDateTime(target.next_check_at ?? undefined) : "--（已停用）"} · 共記錄 {target.post_count} 篇，已排入{" "}
              {target.queued_count} 篇
            </Typography>
          </Box>
          <Stack direction="row" spacing={0.5} alignItems="center">
            <Tooltip title={target.enabled ? "停用排程" : "啟用排程"}>
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
              測試
            </Button>
            <Tooltip title="現在就檢查一次，新貼文會排進 Obsidian Clipper">
              <span>
                <Button
                  size="small"
                  variant="contained"
                  startIcon={run.isPending && run.variables?.mode === "check" ? <CircularProgress size={14} color="inherit" /> : <PlayArrowOutlinedIcon />}
                  disabled={run.isPending}
                  onClick={() => runCheck("check")}
                >
                  立即檢查
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
            {formatDateTime(result.checked_at)}：{result.message}
            {result.ok ? `（本次新貼文 ${result.new_posts} 篇）` : ""}
          </Alert>
        ) : (
          <Alert severity="info" variant="outlined" sx={{ py: 0 }}>
            尚未檢查。{target.enabled ? "排程會在一分鐘內做第一次檢查（記為基準）。" : "啟用後才會排程檢查。"}
          </Alert>
        )}
        {run.isError ? <Alert severity="error">{errorText(run.error)}</Alert> : null}
        <Collapse in={expanded} unmountOnExit>
          <Stack spacing={2}>
            {lastRun ? <CheckResultView result={lastRun} /> : null}
            <Box>
              <Typography variant="body2" fontWeight={700} sx={{ mb: 0.5 }}>
                貼文紀錄
              </Typography>
              <PostLogTable posts={target.posts} />
            </Box>
          </Stack>
        </Collapse>
      </Stack>
      {editing ? <EditDialog target={target} minInterval={minInterval} onClose={() => setEditing(false)} /> : null}
      <Dialog open={confirmDelete} onClose={() => setConfirmDelete(false)}>
        <DialogTitle>刪除追蹤？</DialogTitle>
        <DialogContent>
          <Typography>會刪除 @{target.username} 的設定與貼文紀錄；已排進 Obsidian Clipper 的項目不受影響。</Typography>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setConfirmDelete(false)}>取消</Button>
          <Button color="error" variant="contained" disabled={remove.isPending} onClick={() => remove.mutate(target.id)}>
            刪除
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
    <PageScaffold title="Watch 追蹤" eyebrow="Scheduled checks">
      <AddWatchPanel minInterval={minInterval} />
      {watches.isError ? <Alert severity="error">無法讀取追蹤清單：{errorText(watches.error)}</Alert> : null}
      {watches.data && !watches.data.scheduler_running ? (
        <Alert severity="warning">排程目前沒有在這個 WebUI 程序裡執行，只能手動檢查。</Alert>
      ) : null}
      {watches.data?.watches.length === 0 ? (
        <Typography color="text.secondary">還沒有追蹤任何帳號。</Typography>
      ) : null}
      {watches.data?.watches.map((target) => <WatchCard key={target.id} target={target} minInterval={minInterval} />)}
    </PageScaffold>
  );
}
