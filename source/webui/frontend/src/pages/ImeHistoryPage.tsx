import SearchOutlinedIcon from "@mui/icons-material/SearchOutlined";
import { Box, Divider, InputAdornment, Stack, TextField, Typography } from "@mui/material";
import { PageScaffold, WorkspacePanel } from "./PageScaffold";

export function ImeHistoryPage() {
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
