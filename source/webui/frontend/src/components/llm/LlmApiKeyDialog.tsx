import { Button, Dialog, DialogActions, DialogContent, DialogTitle, Stack, TextField, Typography } from "@mui/material";
import { useEffect, useState } from "react";

type LlmApiKeyDialogProps = {
  open: boolean;
  endpoint?: string;
  provider?: string;
  onSubmit: (value: string) => void;
  onCancel: () => void;
};

export function LlmApiKeyDialog({ open, endpoint, provider, onSubmit, onCancel }: LlmApiKeyDialogProps) {
  const [value, setValue] = useState("");

  useEffect(() => {
    if (open) setValue("");
  }, [open]);

  return (
    <Dialog open={open} onClose={onCancel} fullWidth maxWidth="xs">
      <DialogTitle>LLM API key</DialogTitle>
      <DialogContent>
        <Stack spacing={2} sx={{ pt: 0.5 }}>
          <Typography color="text.secondary">
            {provider || "This LLM endpoint"} needs a bearer token for this browser session.
          </Typography>
          <Typography variant="body2" color="text.secondary" sx={{ overflowWrap: "anywhere" }}>
            {endpoint}
          </Typography>
          <TextField
            autoFocus
            fullWidth
            label="API key"
            type="password"
            value={value}
            onChange={(event) => setValue(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                event.preventDefault();
                onSubmit(value);
              }
            }}
          />
        </Stack>
      </DialogContent>
      <DialogActions>
        <Button onClick={onCancel}>Cancel</Button>
        <Button variant="contained" onClick={() => onSubmit(value)} disabled={!value.trim()}>
          Use key
        </Button>
      </DialogActions>
    </Dialog>
  );
}
