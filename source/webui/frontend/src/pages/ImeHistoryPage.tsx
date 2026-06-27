import SearchOutlinedIcon from "@mui/icons-material/SearchOutlined";
import { Box, Divider, InputAdornment, Stack, TextField, Typography } from "@mui/material";
import { useEffect, useMemo, useState } from "react";
import { PageScaffold, WorkspacePanel } from "./PageScaffold";

const IME_HISTORY_STATE_KEY = "airtype:ime-history:state";

export function ImeHistoryPage() {
  const restoredState = useMemo(readPersistedImeHistoryState, []);
  const [searchText, setSearchText] = useState(restoredState.searchText);

  useEffect(() => {
    writePersistedImeHistoryState({ searchText });
  }, [searchText]);

  return (
    <PageScaffold title="IME History" eyebrow="Speech input records">
      <Box
        sx={{
          display: "grid",
          gridTemplateColumns: { xs: "1fr", lg: "320px minmax(0, 1fr)" },
          gap: 2,
          minHeight: 0
        }}
      >
        <WorkspacePanel>
          <Stack spacing={1.5}>
            <TextField
              size="small"
              value={searchText}
              onChange={(event) => setSearchText(event.target.value)}
              placeholder="Search IME history"
              InputProps={{
                startAdornment: (
                  <InputAdornment position="start">
                    <SearchOutlinedIcon fontSize="small" />
                  </InputAdornment>
                )
              }}
            />
            <Divider />
            <Typography color="text.secondary">IME records will appear here.</Typography>
          </Stack>
        </WorkspacePanel>
        <WorkspacePanel>
          <Stack spacing={1.5} sx={{ minHeight: 520 }}>
            <Typography variant="h3">Record Detail</Typography>
            <Divider />
            <Typography color="text.secondary">Select a record to review, copy, or export.</Typography>
          </Stack>
        </WorkspacePanel>
      </Box>
    </PageScaffold>
  );
}

function readPersistedImeHistoryState() {
  const fallback = { searchText: "" };
  if (typeof window === "undefined") return fallback;
  try {
    const value = window.sessionStorage.getItem(IME_HISTORY_STATE_KEY) || window.localStorage.getItem(IME_HISTORY_STATE_KEY);
    if (!value) return fallback;
    const parsed = JSON.parse(value) as Partial<typeof fallback>;
    return { searchText: typeof parsed.searchText === "string" ? parsed.searchText : "" };
  } catch {
    return fallback;
  }
}

function writePersistedImeHistoryState(state: { searchText: string }) {
  if (typeof window === "undefined") return;
  try {
    const value = JSON.stringify(state);
    window.sessionStorage.setItem(IME_HISTORY_STATE_KEY, value);
    window.localStorage.setItem(IME_HISTORY_STATE_KEY, value);
  } catch {
    // If storage is unavailable, the in-memory search field still works.
  }
}
