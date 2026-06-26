import AddCircleOutlineIcon from "@mui/icons-material/AddCircleOutline";
import { Button, Chip, Grid, Stack, Typography } from "@mui/material";
import { Link as RouterLink } from "react-router-dom";
import { PageScaffold, WorkspacePanel } from "./PageScaffold";

export function DashboardPage() {
  return (
    <PageScaffold
      title="Dashboard"
      eyebrow="Overview"
      actions={
        <Button component={RouterLink} to="/v-to-text" variant="contained" startIcon={<AddCircleOutlineIcon />}>
          New V to Text
        </Button>
      }
    >
      <Grid container spacing={2}>
        {[
          ["ASR Server", "Waiting for API wiring"],
          ["LLM Server", "Waiting for API wiring"],
          ["Recent Jobs", "0 active"],
          ["Obsidian", "Not checked"]
        ].map(([label, value]) => (
          <Grid key={label} size={{ xs: 12, md: 6, lg: 3 }}>
            <WorkspacePanel>
              <Stack spacing={1}>
                <Typography variant="body2" color="text.secondary" fontWeight={700}>
                  {label}
                </Typography>
                <Typography variant="h2">{value}</Typography>
              </Stack>
            </WorkspacePanel>
          </Grid>
        ))}
      </Grid>
      <WorkspacePanel>
        <Stack direction="row" alignItems="center" spacing={1.5}>
          <Chip label="Phase 1" color="primary" variant="outlined" />
          <Typography color="text.secondary">
            React + MUI workspace shell is ready for API integration.
          </Typography>
        </Stack>
      </WorkspacePanel>
    </PageScaffold>
  );
}
