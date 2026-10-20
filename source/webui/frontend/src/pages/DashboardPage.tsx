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

const numberFormat = new Intl.NumberFormat("en-US");

function formatNumber(value?: number | null) {
  return typeof value === "number" ? numberFormat.format(value) : "--";
}

function formatCompact(value?: number | null) {
  if (typeof value !== "number") return "--";
  if (value >= 1_000_000_000) return `${(value / 1_000_000_000).toFixed(1)}B`;
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)}K`;
  return numberFormat.format(value);
}

function formatPercent(value?: number | null) {
  return typeof value === "number" ? `${Math.round(value * 100)}%` : "--";
}

function formatHours(seconds: number) {
  const hours = seconds / 3600;
  return hours >= 1 ? `${hours.toFixed(1)} hours` : `${Math.round(seconds / 60)} min`;
}

const statusLabel: Record<string, { label: string; color: "success" | "error" | "default" | "info" }> = {
  completed: { label: "Completed", color: "success" },
  failed: { label: "Failed", color: "error" },
  cancelled: { label: "Cancelled", color: "default" },
  running: { label: "Processing", color: "info" },
  queued: { label: "Queued", color: "info" }
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
          <Tooltip key={item.date} title={`${item.date}: ${item.count}`} placement="top">
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
          <TableCell>Site</TableCell>
          <TableCell sx={{ width: "40%" }}>Count</TableCell>
          <TableCell align="right">Completed</TableCell>
          <TableCell align="right">Failed</TableCell>
          <TableCell align="right">Cancelled</TableCell>
          <TableCell align="right">Success</TableCell>
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
  if (!reasons.length) return <Typography color="text.secondary">No failures recorded.</Typography>;
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
            Since {formatDateTime(logged_since ?? undefined)}: {formatNumber(totals.calls)} calls,{" "}
            {formatNumber(totals.prompt_tokens)} input tokens, {formatNumber(totals.completion_tokens)} output tokens
            {totals.failed_calls ? `, ${totals.failed_calls} failed` : ""}
            {totals.calls_without_usage ? `, ${totals.calls_without_usage} with no token counts from the server` : ""}.
          </Typography>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Step</TableCell>
                <TableCell align="right">Calls</TableCell>
                <TableCell align="right">Input tokens</TableCell>
                <TableCell align="right">Output tokens</TableCell>
                <TableCell align="right">Input chars</TableCell>
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
              <Chip key={row.model} variant="outlined" label={`${row.model}: ${formatCompact(row.total_tokens)} tokens`} />
            ))}
          </Stack>
        </>
      ) : (
        <Typography variant="body2" color="text.secondary">
          No token records yet. From now on, every LLM call is written to llm-usage.jsonl.
        </Typography>
      )}
      <Alert severity="info" variant="outlined">
        <strong>Historical estimate</strong>: before logging started, {formatNumber(historical_estimate.captures)}{" "}
        captures were sent for polishing, about {formatNumber(historical_estimate.input_chars)} characters (based on
        submitted text, excluding title and tag calls; not actual token counts).
      </Alert>
    </Stack>
  );
}

function RecentList({ stats }: { stats: UsageStats }) {
  return (
    <Table size="small">
      <TableHead>
        <TableRow>
          <TableCell>Time</TableCell>
          <TableCell>Site</TableCell>
          <TableCell>Title</TableCell>
          <TableCell align="right">Status</TableCell>
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
          <Tooltip title="Refresh">
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
      {statsQuery.isError ? <Alert severity="error">Could not load stats: {String(statsQuery.error)}</Alert> : null}
      {!stats ? (
        statsQuery.isLoading ? <LinearProgress /> : null
      ) : (
        <>
          <Grid container spacing={2}>
            <Grid size={{ xs: 12, sm: 6, lg: 3 }}>
              <SummaryCard
                label="Total captures"
                value={formatNumber(stats.captures.total)}
                hint={`Since ${stats.captures.first_capture_at?.slice(0, 10) ?? "--"}`}
              />
            </Grid>
            <Grid size={{ xs: 12, sm: 6, lg: 3 }}>
              <SummaryCard
                label="Success rate"
                value={formatPercent(stats.captures.success_rate)}
                hint={`Completed ${stats.captures.completed} · Failed ${stats.captures.failed} · Cancelled ${stats.captures.cancelled}`}
              />
            </Grid>
            <Grid size={{ xs: 12, sm: 6, lg: 3 }}>
              <SummaryCard
                label="Voice input"
                value={`${formatNumber(stats.ime.count)} clips`}
                hint={`${formatHours(stats.ime.total_duration_seconds)} · ${formatCompact(stats.ime.total_chars)} chars`}
              />
            </Grid>
            <Grid size={{ xs: 12, sm: 6, lg: 3 }}>
              <SummaryCard
                label="Input sent to AI"
                value={
                  stats.llm.totals.calls
                    ? `${formatCompact(stats.llm.totals.prompt_tokens)} tokens`
                    : `≈ ${formatCompact(stats.llm.historical_estimate.input_chars)} chars`
                }
                hint={
                  stats.llm.totals.calls
                    ? `${formatNumber(stats.llm.totals.calls)} calls; plus historical estimate ≈ ${formatCompact(stats.llm.historical_estimate.input_chars)} chars`
                    : "Historical estimate (no token records yet)"
                }
              />
            </Grid>
          </Grid>

          <Grid container spacing={2}>
            <Grid size={{ xs: 12, lg: 7 }}>
              <Section title="Captures by site" subtitle="Green completed, red failed, gray cancelled">
                <SiteTable stats={stats} />
              </Section>
            </Grid>
            <Grid size={{ xs: 12, lg: 5 }}>
              <Section title="Failure reasons" subtitle="Grouped by error message">
                <FailureList stats={stats} />
              </Section>
            </Grid>
          </Grid>

          <Grid container spacing={2}>
            <Grid size={{ xs: 12, md: 6 }}>
              <Section title={`Last ${stats.days} days of captures`}>
                <DailyBars data={stats.captures.by_day} />
              </Section>
            </Grid>
            <Grid size={{ xs: 12, md: 6 }}>
              <Section title={`Last ${stats.days} days of voice input`}>
                <DailyBars data={stats.ime.by_day} color="success.main" />
              </Section>
            </Grid>
          </Grid>

          <Section title="AI usage" subtitle="Token stats from oMLX / LLM calls">
            <LlmUsage stats={stats} />
          </Section>

          <Section title="Recent captures">
            <RecentList stats={stats} />
          </Section>
        </>
      )}
    </PageScaffold>
  );
}
