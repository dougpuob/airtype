import AddCircleOutlineIcon from "@mui/icons-material/AddCircleOutline";
import RefreshIcon from "@mui/icons-material/Refresh";
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Grid,
  IconButton,
  LinearProgress,
  Link,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  Tooltip,
  Typography
} from "@mui/material";
import type { ReactNode } from "react";
import { Link as RouterLink } from "react-router-dom";
import { useUsageStatsQuery, type UsageStats } from "../api/stats";
import { formatDateTime } from "../utils/format";
import { PageScaffold, WorkspacePanel } from "./PageScaffold";

const numberFormat = new Intl.NumberFormat("zh-TW");

function formatNumber(value?: number | null) {
  return typeof value === "number" ? numberFormat.format(value) : "--";
}

function formatCompact(value?: number | null) {
  if (typeof value !== "number") return "--";
  if (value >= 100_000_000) return `${(value / 100_000_000).toFixed(1)} 億`;
  if (value >= 10_000) return `${(value / 10_000).toFixed(1)} 萬`;
  return numberFormat.format(value);
}

function formatPercent(value?: number | null) {
  return typeof value === "number" ? `${Math.round(value * 100)}%` : "--";
}

function formatHours(seconds: number) {
  const hours = seconds / 3600;
  return hours >= 1 ? `${hours.toFixed(1)} 小時` : `${Math.round(seconds / 60)} 分鐘`;
}

const statusLabel: Record<string, { label: string; color: "success" | "error" | "default" | "info" }> = {
  completed: { label: "完成", color: "success" },
  failed: { label: "失敗", color: "error" },
  cancelled: { label: "取消", color: "default" },
  running: { label: "處理中", color: "info" },
  queued: { label: "排隊中", color: "info" }
};

function SummaryCard({ label, value, hint }: { label: string; value: ReactNode; hint?: ReactNode }) {
  return (
    <WorkspacePanel>
      <Stack spacing={0.75}>
        <Typography variant="body2" color="text.secondary" fontWeight={700}>
          {label}
        </Typography>
        <Typography variant="h2" sx={{ fontSize: 26 }}>
          {value}
        </Typography>
        {hint ? (
          <Typography variant="caption" color="text.secondary">
            {hint}
          </Typography>
        ) : null}
      </Stack>
    </WorkspacePanel>
  );
}

function DailyBars({ data, color = "primary.main" }: { data: { date: string; count: number }[]; color?: string }) {
  const max = Math.max(1, ...data.map((item) => item.count));
  return (
    <Stack spacing={0.5}>
      <Stack direction="row" alignItems="flex-end" spacing={0.25} sx={{ height: 96 }}>
        {data.map((item) => (
          <Tooltip key={item.date} title={`${item.date}：${item.count}`} placement="top">
            <Box
              sx={{
                flex: 1,
                minWidth: 2,
                height: `${Math.max(item.count ? 6 : 2, (item.count / max) * 100)}%`,
                bgcolor: item.count ? color : "divider",
                borderRadius: 0.5
              }}
            />
          </Tooltip>
        ))}
      </Stack>
      <Stack direction="row" justifyContent="space-between">
        <Typography variant="caption" color="text.secondary">
          {data[0]?.date.slice(5)}
        </Typography>
        <Typography variant="caption" color="text.secondary">
          {data[data.length - 1]?.date.slice(5)}
        </Typography>
      </Stack>
    </Stack>
  );
}

function SiteTable({ stats }: { stats: UsageStats }) {
  const max = Math.max(1, ...stats.captures.by_site.map((site) => site.total));
  return (
    <Table size="small">
      <TableHead>
        <TableRow>
          <TableCell>網站</TableCell>
          <TableCell sx={{ width: "40%" }}>次數</TableCell>
          <TableCell align="right">完成</TableCell>
          <TableCell align="right">失敗</TableCell>
          <TableCell align="right">取消</TableCell>
          <TableCell align="right">成功率</TableCell>
        </TableRow>
      </TableHead>
      <TableBody>
        {stats.captures.by_site.map((site) => (
          <TableRow key={site.site}>
            <TableCell sx={{ fontWeight: 700 }}>{site.site}</TableCell>
            <TableCell>
              <Stack direction="row" alignItems="center" spacing={1}>
                <Box sx={{ flex: 1, display: "flex", height: 10, borderRadius: 1, overflow: "hidden", bgcolor: "action.hover" }}>
                  <Box sx={{ width: `${(site.completed / max) * 100}%`, bgcolor: "success.main" }} />
                  <Box sx={{ width: `${(site.failed / max) * 100}%`, bgcolor: "error.main" }} />
                  <Box sx={{ width: `${((site.cancelled + site.other) / max) * 100}%`, bgcolor: "grey.400" }} />
                </Box>
                <Typography variant="body2" sx={{ minWidth: 28, textAlign: "right" }}>
                  {site.total}
                </Typography>
              </Stack>
            </TableCell>
            <TableCell align="right">{site.completed}</TableCell>
            <TableCell align="right">{site.failed}</TableCell>
            <TableCell align="right">{site.cancelled}</TableCell>
            <TableCell align="right">{formatPercent(site.success_rate)}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}

function FailureList({ stats }: { stats: UsageStats }) {
  const reasons = stats.captures.failure_reasons;
  if (!reasons.length) return <Typography color="text.secondary">目前沒有失敗紀錄。</Typography>;
  const max = Math.max(1, ...reasons.map((item) => item.count));
  return (
    <Stack spacing={1.25}>
      {reasons.map((item) => (
        <Stack key={item.reason} spacing={0.5}>
          <Stack direction="row" justifyContent="space-between" spacing={1}>
            <Typography variant="body2" fontWeight={700}>
              {item.reason}
            </Typography>
            <Typography variant="body2" color="text.secondary">
              {item.count}
            </Typography>
          </Stack>
          <LinearProgress variant="determinate" color="error" value={(item.count / max) * 100} sx={{ height: 6, borderRadius: 1 }} />
          <Typography variant="caption" color="text.secondary">
            {Object.entries(item.sites)
              .map(([site, count]) => `${site} ${count}`)
              .join(" · ")}
          </Typography>
        </Stack>
      ))}
    </Stack>
  );
}

function LlmUsage({ stats }: { stats: UsageStats }) {
  const { totals, by_step, by_model, logged_since, historical_estimate } = stats.llm;
  return (
    <Stack spacing={2}>
      {totals.calls ? (
        <>
          <Typography variant="body2" color="text.secondary">
            自 {formatDateTime(logged_since ?? undefined)} 起共 {formatNumber(totals.calls)} 次呼叫，輸入{" "}
            {formatNumber(totals.prompt_tokens)} tokens、輸出 {formatNumber(totals.completion_tokens)} tokens
            {totals.failed_calls ? `，失敗 ${totals.failed_calls} 次` : ""}
            {totals.calls_without_usage ? `，${totals.calls_without_usage} 次伺服器未回傳 token 數` : ""}。
          </Typography>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>步驟</TableCell>
                <TableCell align="right">次數</TableCell>
                <TableCell align="right">輸入 tokens</TableCell>
                <TableCell align="right">輸出 tokens</TableCell>
                <TableCell align="right">輸入字數</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {by_step.map((row) => (
                <TableRow key={row.step}>
                  <TableCell sx={{ fontWeight: 700 }}>{row.step}</TableCell>
                  <TableCell align="right">{formatNumber(row.calls)}</TableCell>
                  <TableCell align="right">{formatNumber(row.prompt_tokens)}</TableCell>
                  <TableCell align="right">{formatNumber(row.completion_tokens)}</TableCell>
                  <TableCell align="right">{formatNumber(row.input_chars)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          <Stack direction="row" spacing={1} flexWrap="wrap" useFlexGap>
            {by_model.map((row) => (
              <Chip key={row.model} variant="outlined" label={`${row.model}：${formatCompact(row.total_tokens)} tokens`} />
            ))}
          </Stack>
        </>
      ) : (
        <Typography variant="body2" color="text.secondary">
          尚未有 token 紀錄。從現在起，每一次 LLM 呼叫都會記到 llm-usage.jsonl。
        </Typography>
      )}
      <Alert severity="info" variant="outlined">
        <strong>歷史估計值</strong>：開始記錄前，共有 {formatNumber(historical_estimate.captures)} 筆內容送去潤稿，約{" "}
        {formatNumber(historical_estimate.input_chars)} 字（以送出的字數估算，不含標題與標籤呼叫，並非實際 token 數）。
      </Alert>
    </Stack>
  );
}

function RecentList({ stats }: { stats: UsageStats }) {
  return (
    <Table size="small">
      <TableHead>
        <TableRow>
          <TableCell>時間</TableCell>
          <TableCell>網站</TableCell>
          <TableCell>標題</TableCell>
          <TableCell align="right">狀態</TableCell>
        </TableRow>
      </TableHead>
      <TableBody>
        {stats.captures.recent.map((item) => {
          const status = statusLabel[item.status] ?? { label: item.status, color: "default" as const };
          return (
            <TableRow key={`${item.kind}-${item.id}`}>
              <TableCell sx={{ whiteSpace: "nowrap" }}>{formatDateTime(item.created_at)}</TableCell>
              <TableCell sx={{ whiteSpace: "nowrap" }}>{item.site}</TableCell>
              <TableCell sx={{ maxWidth: 420 }}>
                <Typography variant="body2" noWrap title={item.title}>
                  {item.url ? (
                    <Link href={item.url} target="_blank" rel="noreferrer" underline="hover" color="inherit">
                      {item.title || item.url}
                    </Link>
                  ) : (
                    item.title || "--"
                  )}
                </Typography>
                {item.error ? (
                  <Typography variant="caption" color="error.main">
                    {item.error}
                  </Typography>
                ) : null}
              </TableCell>
              <TableCell align="right">
                <Chip size="small" label={status.label} color={status.color} variant="outlined" />
              </TableCell>
            </TableRow>
          );
        })}
      </TableBody>
    </Table>
  );
}

function Section({ title, subtitle, children }: { title: string; subtitle?: string; children: ReactNode }) {
  return (
    <WorkspacePanel>
      <Stack spacing={1.5}>
        <Box>
          <Typography variant="h3">{title}</Typography>
          {subtitle ? (
            <Typography variant="caption" color="text.secondary">
              {subtitle}
            </Typography>
          ) : null}
        </Box>
        {children}
      </Stack>
    </WorkspacePanel>
  );
}

export function DashboardPage() {
  const statsQuery = useUsageStatsQuery(30);
  const stats = statsQuery.data;

  return (
    <PageScaffold
      title="Dashboard"
      eyebrow="Overview"
      actions={
        <Stack direction="row" spacing={1} alignItems="center">
          <Tooltip title="重新整理">
            <span>
              <IconButton onClick={() => void statsQuery.refetch()} disabled={statsQuery.isFetching}>
                {statsQuery.isFetching ? <CircularProgress size={20} /> : <RefreshIcon />}
              </IconButton>
            </span>
          </Tooltip>
          <Button component={RouterLink} to="/v-to-text" variant="contained" startIcon={<AddCircleOutlineIcon />}>
            New Obsidian Clipper
          </Button>
        </Stack>
      }
    >
      {statsQuery.isError ? <Alert severity="error">無法讀取統計資料：{String(statsQuery.error)}</Alert> : null}
      {!stats ? (
        statsQuery.isLoading ? <LinearProgress /> : null
      ) : (
        <>
          <Grid container spacing={2}>
            <Grid size={{ xs: 12, sm: 6, lg: 3 }}>
              <SummaryCard
                label="總抓取次數"
                value={formatNumber(stats.captures.total)}
                hint={`自 ${stats.captures.first_capture_at?.slice(0, 10) ?? "--"} 起`}
              />
            </Grid>
            <Grid size={{ xs: 12, sm: 6, lg: 3 }}>
              <SummaryCard
                label="成功率"
                value={formatPercent(stats.captures.success_rate)}
                hint={`完成 ${stats.captures.completed} · 失敗 ${stats.captures.failed} · 取消 ${stats.captures.cancelled}`}
              />
            </Grid>
            <Grid size={{ xs: 12, sm: 6, lg: 3 }}>
              <SummaryCard
                label="語音輸入"
                value={`${formatNumber(stats.ime.count)} 段`}
                hint={`${formatHours(stats.ime.total_duration_seconds)} · ${formatCompact(stats.ime.total_chars)} 字`}
              />
            </Grid>
            <Grid size={{ xs: 12, sm: 6, lg: 3 }}>
              <SummaryCard
                label="送給 AI 的輸入"
                value={
                  stats.llm.totals.calls
                    ? `${formatCompact(stats.llm.totals.prompt_tokens)} tokens`
                    : `≈ ${formatCompact(stats.llm.historical_estimate.input_chars)} 字`
                }
                hint={
                  stats.llm.totals.calls
                    ? `${formatNumber(stats.llm.totals.calls)} 次呼叫；另有歷史估計 ≈ ${formatCompact(stats.llm.historical_estimate.input_chars)} 字`
                    : "歷史估計值（尚無 token 紀錄）"
                }
              />
            </Grid>
          </Grid>

          <Grid container spacing={2}>
            <Grid size={{ xs: 12, lg: 7 }}>
              <Section title="各網站抓取統計" subtitle="綠色完成、紅色失敗、灰色取消">
                <SiteTable stats={stats} />
              </Section>
            </Grid>
            <Grid size={{ xs: 12, lg: 5 }}>
              <Section title="失敗原因" subtitle="依錯誤訊息歸類">
                <FailureList stats={stats} />
              </Section>
            </Grid>
          </Grid>

          <Grid container spacing={2}>
            <Grid size={{ xs: 12, md: 6 }}>
              <Section title={`最近 ${stats.days} 天抓取`}>
                <DailyBars data={stats.captures.by_day} />
              </Section>
            </Grid>
            <Grid size={{ xs: 12, md: 6 }}>
              <Section title={`最近 ${stats.days} 天語音輸入`}>
                <DailyBars data={stats.ime.by_day} color="success.main" />
              </Section>
            </Grid>
          </Grid>

          <Section title="AI 用量" subtitle="oMLX / LLM 呼叫的 token 統計">
            <LlmUsage stats={stats} />
          </Section>

          <Section title="最近抓取">
            <RecentList stats={stats} />
          </Section>
        </>
      )}
    </PageScaffold>
  );
}
