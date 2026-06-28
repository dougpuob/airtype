import { Alert, Box, Button, CircularProgress, Paper, Stack, TextField, Typography } from "@mui/material";
import { FormEvent, useEffect, useState } from "react";
import type { AuthStatus } from "../api/auth";
import { useLoginMutation } from "../api/auth";

export function LoginPage({ status }: { status: AuthStatus }) {
  const login = useLoginMutation();
  const [username, setUsername] = useState(status.username || "");
  const [password, setPassword] = useState("");

  useEffect(() => {
    setUsername(status.username || "");
  }, [status.username]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    await login.mutateAsync({ username: username.trim(), password }).catch(() => undefined);
  }

  return (
    <Box
      sx={{
        alignItems: "center",
        bgcolor: "background.default",
        display: "flex",
        justifyContent: "center",
        minHeight: "100vh",
        p: 2
      }}
    >
      <Paper component="form" onSubmit={(event) => void submit(event)} sx={{ maxWidth: 400, p: 3, width: "100%" }}>
        <Stack spacing={2}>
          <Stack alignItems="center" spacing={1}>
            <Box component="img" src="/app/favicon.svg" alt="" sx={{ height: 52, width: 52 }} />
            <Typography variant="h2">Sign in to AirType</Typography>
            <Typography variant="body2" color="text.secondary" textAlign="center">
              This browser will stay signed in for {status.session_days || 14} days.
            </Typography>
          </Stack>
          {login.isError ? (
            <Alert severity="error">
              {login.error instanceof Error ? login.error.message : "Could not sign in"}
            </Alert>
          ) : null}
          <TextField
            autoFocus
            autoComplete="username"
            label="Username"
            value={username}
            onChange={(event) => setUsername(event.target.value)}
          />
          <TextField
            autoComplete="current-password"
            label="Password"
            type="password"
            value={password}
            onChange={(event) => setPassword(event.target.value)}
          />
          <Button
            disabled={login.isPending || !username.trim() || !password}
            startIcon={login.isPending ? <CircularProgress color="inherit" size={16} /> : undefined}
            type="submit"
            variant="contained"
          >
            {login.isPending ? "Signing in..." : "Sign in"}
          </Button>
        </Stack>
      </Paper>
    </Box>
  );
}
