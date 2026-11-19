import SearchIcon from "@mui/icons-material/Search";
import {
  Alert,
  Box,
  Chip,
  CircularProgress,
  InputAdornment,
  Link,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TablePagination,
  TableRow,
  TextField,
  Typography
} from "@mui/material";
import { useEffect, useRef, useState } from "react";
import { useHistoryQuery, type HistoryItem } from "../api/history";
import { PageScaffold, WorkspacePanel } from "./PageScaffold";

const statusLabel: Record<string, string> = {
  completed: "Completed",
  failed: "Failed",
  duplicate_cancelled: "Duplicate cancelled"
};

const kindLabel: Record<string, string> = {
  article: "Article",
  post: "Post",
  voice: "Voice"
};

function formatWhen(value?: string) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat(undefined, {
    year: "numeric",
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit"
  }).format(date);
}

function HistoryRow({ item }: { item: HistoryItem }) {
  const url = item.url || "";
  const linked = url.startsWith("http://") || url.startsWith("https://");
  return (
    <TableRow hover>
      <TableCell sx={{ fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", fontSize: 12, overflowWrap: "anywhere", minWidth: 220 }}>
        {item.guid || "—"}
      </TableCell>
      <TableCell sx={{ overflowWrap: "anywhere", minWidth: 220, maxWidth: 360 }}>
        {linked ? (
          <Link href={url} target="_blank" rel="noreferrer" underline="hover">
            {url}
          </Link>
        ) : (
          url || "—"
        )}
      </TableCell>
      <TableCell sx={{ minWidth: 160 }}>
        <Typography variant="body2">{item.title || "—"}</Typography>
        <Typography variant="caption" color="text.secondary">
          {[kindLabel[item.kind] || item.kind, item.origin === "watching" ? "Watching" : "Manual"].filter(Boolean).join(" · ")}
        </Typography>
      </TableCell>
      <TableCell>
        <Chip size="small" label={statusLabel[item.status] || item.status || "—"} />
      </TableCell>
      <TableCell sx={{ whiteSpace: "nowrap" }}>{formatWhen(item.finished_at)}</TableCell>
      <TableCell sx={{ whiteSpace: "nowrap" }}>{formatWhen(item.created_at)}</TableCell>
      <TableCell sx={{ whiteSpace: "nowrap" }}>{formatWhen(item.content_at)}</TableCell>
    </TableRow>
  );
}

export function HistoryPage() {
  const [draft, setDraft] = useState("");
  const [query, setQuery] = useState("");
  const [page, setPage] = useState(0);
  const [pageSize, setPageSize] = useState(100);
  const appliedQuery = useRef("");
  const history = useHistoryQuery(query, page + 1, pageSize);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      const next = draft.trim();
      if (appliedQuery.current === next) return;
      appliedQuery.current = next;
      setQuery(next);
      setPage(0);
    }, 300);
    return () => window.clearTimeout(timer);
  }, [draft]);

  useEffect(() => {
    if (history.data && !history.isPlaceholderData && history.data.page !== page + 1) {
      setPage(Math.max(0, history.data.page - 1));
    }
  }, [history.data, history.isPlaceholderData, page]);

  const total = history.data?.total ?? 0;
  const items = history.data?.items ?? [];
  const sizes = history.data?.page_sizes?.length ? history.data.page_sizes : [25, 50, 100, 200, 500];

  return (
    <PageScaffold title="History" eyebrow="Downloads">
      <WorkspacePanel>
        <Stack spacing={2}>
          <TextField
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            placeholder="Search UUID, URL, title, kind, or status"
            size="small"
            fullWidth
            InputProps={{
              startAdornment: (
                <InputAdornment position="start">
                  <SearchIcon fontSize="small" />
                </InputAdornment>
              )
            }}
            helperText="Separate words to narrow the list. Each word can match the UUID, URL, title, kind, or status."
          />
          {history.isError ? <Alert severity="error">Could not load history.</Alert> : null}
          {history.isLoading ? (
            <Box sx={{ display: "flex", justifyContent: "center", py: 6 }}>
              <CircularProgress size={28} />
            </Box>
          ) : (
            <Box sx={{ overflow: "auto" }}>
              <Table size="small" sx={{ minWidth: 960 }}>
                <TableHead>
                  <TableRow>
                    <TableCell>UUID</TableCell>
                    <TableCell>URL</TableCell>
                    <TableCell>Title</TableCell>
                    <TableCell>Status</TableCell>
                    <TableCell>Finished</TableCell>
                    <TableCell>Requested</TableCell>
                    <TableCell>Content date</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {items.length === 0 ? (
                    <TableRow>
                      <TableCell colSpan={7}>
                        <Typography variant="body2" color="text.secondary" sx={{ py: 3, textAlign: "center" }}>
                          {query ? "No downloads match this search." : "No downloads yet."}
                        </Typography>
                      </TableCell>
                    </TableRow>
                  ) : (
                    items.map((item) => <HistoryRow key={item.request_id} item={item} />)
                  )}
                </TableBody>
              </Table>
              <TablePagination
                component="div"
                count={total}
                page={Math.min(page, Math.max(0, Math.ceil(total / pageSize) - 1))}
                onPageChange={(_event, next) => setPage(next)}
                rowsPerPage={pageSize}
                onRowsPerPageChange={(event) => {
                  setPageSize(Number(event.target.value));
                  setPage(0);
                }}
                rowsPerPageOptions={sizes}
              />
            </Box>
          )}
        </Stack>
      </WorkspacePanel>
    </PageScaffold>
  );
}
