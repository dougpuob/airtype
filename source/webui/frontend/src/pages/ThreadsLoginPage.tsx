import ArrowDownwardIcon from "@mui/icons-material/ArrowDownward";
import BackspaceOutlinedIcon from "@mui/icons-material/BackspaceOutlined";
import LoginOutlinedIcon from "@mui/icons-material/LoginOutlined";
import RefreshOutlinedIcon from "@mui/icons-material/RefreshOutlined";
import SaveOutlinedIcon from "@mui/icons-material/SaveOutlined";
import StopCircleOutlinedIcon from "@mui/icons-material/StopCircleOutlined";
import SubdirectoryArrowLeftOutlinedIcon from "@mui/icons-material/SubdirectoryArrowLeftOutlined";
import TabOutlinedIcon from "@mui/icons-material/TabOutlined";
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  IconButton,
  Paper,
  Stack,
  TextField,
  Tooltip,
  Typography
} from "@mui/material";
import type { MouseEvent } from "react";
import { useEffect, useRef, useState } from "react";
import {
  clickThreadsLogin,
  getThreadsLoginScreenshot,
  getThreadsLoginStatus,
  pressThreadsLoginKey,
  saveThreadsLogin,
  startThreadsLogin,
  stopThreadsLogin,
  type ThreadsLoginScreenshot,
  type ThreadsLoginStatus,
  typeThreadsLogin
} from "../api/threadsLogin";

export function ThreadsLoginPage() {
  const imageRef = useRef<HTMLImageElement | null>(null);
  const [status, setStatus] = useState<ThreadsLoginStatus | null>(null);
  const [screenshot, setScreenshot] = useState<ThreadsLoginScreenshot | null>(null);
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    void refreshStatus();
  }, []);

  async function run<T>(action: () => Promise<T>, after?: (value: T) => void) {
    setBusy(true);
    setError("");
    try {
      const value = await action();
      after?.(value);
      return value;
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
      return null;
    } finally {
      setBusy(false);
    }
  }

  async function refreshStatus() {
    await run(getThreadsLoginStatus, setStatus);
  }

  async function refreshScreenshot() {
    await run(getThreadsLoginScreenshot, (value) => {
      setScreenshot(value);
      setStatus(value);
    });
  }

  async function start() {
    const started = await run(startThreadsLogin, setStatus);
    if (started) await refreshScreenshot();
  }

  async function save() {
    await run(saveThreadsLogin, setStatus);
  }

  async function stop() {
    await run(stopThreadsLogin, (value) => {
      setStatus(value);
      setScreenshot(null);
    });
  }

  async function clickImage(event: MouseEvent<HTMLImageElement>) {
    if (!screenshot || !imageRef.current) return;
    const rect = imageRef.current.getBoundingClientRect();
    const x = ((event.clientX - rect.left) / rect.width) * screenshot.width;
    const y = ((event.clientY - rect.top) / rect.height) * screenshot.height;
    await run(() => clickThreadsLogin(x, y), setStatus);
    await refreshScreenshot();
  }

  async function sendText() {
    if (!text) return;
    const value = text;
    setText("");
    await run(() => typeThreadsLogin(value), setStatus);
    await refreshScreenshot();
  }

  async function pressKey(key: string) {
    await run(() => pressThreadsLoginKey(key), setStatus);
    await refreshScreenshot();
  }

  return (
    <Stack spacing={2.5} sx={{ height: "100%", minHeight: 0 }}>
      <Stack direction={{ xs: "column", md: "row" }} spacing={1.5} alignItems={{ xs: "stretch", md: "center" }}>
        <Box sx={{ flex: 1, minWidth: 0 }}>
          <Typography variant="h4" component="h1">
            Threads Login
          </Typography>
          <Typography variant="body2" color="text.secondary">
            {status?.cookie_count ?? 0} saved Threads cookies
          </Typography>
        </Box>
        <Stack direction="row" spacing={1} flexWrap="wrap" useFlexGap>
          <Button startIcon={<LoginOutlinedIcon />} variant="contained" onClick={start} disabled={busy}>
            Start
          </Button>
          <Button startIcon={<RefreshOutlinedIcon />} variant="outlined" onClick={refreshScreenshot} disabled={busy || !status?.running}>
            Refresh
          </Button>
          <Button startIcon={<SaveOutlinedIcon />} variant="outlined" onClick={save} disabled={busy || !status?.running}>
            Save Cookies
          </Button>
          <Button startIcon={<StopCircleOutlinedIcon />} color="inherit" variant="outlined" onClick={stop} disabled={busy || !status?.running}>
            Stop
          </Button>
        </Stack>
      </Stack>

      {error ? <Alert severity="error">{error}</Alert> : null}

      <Stack direction={{ xs: "column", lg: "row" }} spacing={2} sx={{ minHeight: 0, flex: 1 }}>
        <Paper
          variant="outlined"
          sx={{
            flex: 1,
            minWidth: 0,
            minHeight: 360,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            overflow: "auto",
            bgcolor: "#111"
          }}
        >
          {busy && !screenshot ? (
            <CircularProgress />
          ) : screenshot?.image ? (
            <Box
              component="img"
              ref={imageRef}
              src={screenshot.image}
              alt="Threads login browser"
              onClick={clickImage}
              sx={{
                width: "100%",
                maxWidth: screenshot.width,
                height: "auto",
                display: "block",
                cursor: "crosshair",
                userSelect: "none"
              }}
            />
          ) : (
            <Stack spacing={1} alignItems="center" sx={{ color: "common.white", p: 3, textAlign: "center" }}>
              <Typography variant="h6">Server browser stopped</Typography>
              <Typography variant="body2" sx={{ color: "rgba(255,255,255,0.72)" }}>
                Threads login session is inactive.
              </Typography>
            </Stack>
          )}
        </Paper>

        <Paper variant="outlined" sx={{ width: { xs: "100%", lg: 340 }, p: 2, alignSelf: "stretch" }}>
          <Stack spacing={2}>
            <Stack direction="row" spacing={1} flexWrap="wrap" useFlexGap>
              <Chip size="small" label={status?.running ? "Browser running" : "Browser stopped"} color={status?.running ? "success" : "default"} />
              <Chip size="small" label={status?.storage_state_exists ? "Cookies saved" : "No saved cookies"} color={status?.storage_state_exists ? "success" : "default"} />
            </Stack>
            <Typography variant="body2" color="text.secondary" sx={{ wordBreak: "break-all" }}>
              {status?.url || "No active page"}
            </Typography>
            <TextField
              label="Input"
              type="password"
              value={text}
              onChange={(event) => setText(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
                  event.preventDefault();
                  void sendText();
                }
              }}
              autoComplete="off"
              disabled={!status?.running || busy}
            />
            <Button variant="contained" onClick={sendText} disabled={!text || !status?.running || busy}>
              Send Text
            </Button>
            <Stack direction="row" spacing={1}>
              <Tooltip title="Press Enter">
                <span>
                  <IconButton disabled={!status?.running || busy} onClick={() => void pressKey("Enter")}>
                    <SubdirectoryArrowLeftOutlinedIcon />
                  </IconButton>
                </span>
              </Tooltip>
              <Tooltip title="Press Tab">
                <span>
                  <IconButton disabled={!status?.running || busy} onClick={() => void pressKey("Tab")}>
                    <TabOutlinedIcon />
                  </IconButton>
                </span>
              </Tooltip>
              <Tooltip title="Press Backspace">
                <span>
                  <IconButton disabled={!status?.running || busy} onClick={() => void pressKey("Backspace")}>
                    <BackspaceOutlinedIcon />
                  </IconButton>
                </span>
              </Tooltip>
              <Tooltip title="Press ArrowDown">
                <span>
                  <IconButton disabled={!status?.running || busy} onClick={() => void pressKey("ArrowDown")}>
                    <ArrowDownwardIcon />
                  </IconButton>
                </span>
              </Tooltip>
            </Stack>
          </Stack>
        </Paper>
      </Stack>
    </Stack>
  );
}
