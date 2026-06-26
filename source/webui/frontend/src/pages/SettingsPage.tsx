import { Button, Divider, Grid, Stack, TextField, Typography } from "@mui/material";
import { PageScaffold, WorkspacePanel } from "./PageScaffold";

export function SettingsPage() {
  return (
    <PageScaffold title="Settings" eyebrow="Configuration" actions={<Button variant="contained">Save settings</Button>}>
      <Grid container spacing={2}>
        {[
          ["Web UI access", "Username, password, and browser access controls."],
          ["whisper-server", "Local or remote transcription server settings."],
          ["Local LLM model", "Provider, endpoint, model list, and default prompt."],
          ["Obsidian", "Vault save location and note template settings."]
        ].map(([title, description]) => (
          <Grid key={title} size={{ xs: 12, lg: 6 }}>
            <WorkspacePanel>
              <Stack spacing={1.5}>
                <Typography variant="h3">{title}</Typography>
                <Typography color="text.secondary">{description}</Typography>
                <Divider />
                <TextField size="small" label="Coming soon" disabled />
              </Stack>
            </WorkspacePanel>
          </Grid>
        ))}
      </Grid>
    </PageScaffold>
  );
}
