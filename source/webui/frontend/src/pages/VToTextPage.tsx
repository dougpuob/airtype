import LinkOutlinedIcon from "@mui/icons-material/LinkOutlined";
import {
  Alert,
  Box,
  Button,
  Divider,
  LinearProgress,
  Paper,
  Snackbar,
  Stack,
  Step,
  StepLabel,
  Stepper,
  TextField,
  Typography
} from "@mui/material";
import { useEffect, useMemo, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useSettingsQuery } from "../api/settings";
import { compactStepperSx } from "../components/workflow/stepperStyles";
import {
  useCancelTranscriptionJobMutation,
  useCreateUrlTranscriptionJobMutation,
  useTranscriptionJobQuery,
  useTranscriptionRecordQuery,
  useUploadTranscriptionJobMutation
} from "../api/transcription";
import type { TranscriptionJob } from "../types/transcription";
import { buildTranscriptObsidianDraft, openObsidianDraft } from "../utils/obsidian";
import { PageScaffold, WorkspacePanel } from "./PageScaffold";

const steps = ["Downloading", "Transcribing", "Polishing", "Titled", "Done"];

export function VToTextPage() {
  const queryClient = useQueryClient();
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [sourceUrl, setSourceUrl] = useState("");
  const [selectedRecordId, setSelectedRecordId] = useState<string | null>(null);
  const [activeJobId, setActiveJobId] = useState<string | null>(null);
  const [uploadProgress, setUploadProgress] = useState<number | null>(null);
  const [toast, setToast] = useState("");

  const settingsQuery = useSettingsQuery();
  const jobQuery = useTranscriptionJobQuery(activeJobId, Boolean(activeJobId));
  const recordQuery = useTranscriptionRecordQuery(selectedRecordId);
  const createUrlJob = useCreateUrlTranscriptionJobMutation();
  const uploadJob = useUploadTranscriptionJobMutation();
  const cancelJob = useCancelTranscriptionJobMutation();

  const whisper = settingsQuery.data?.whisper || {};
  const activeJob = jobQuery.data;
  const selectedRecord = recordQuery.data;
  const activeProgress = uploadProgress ?? activeJob?.progress ?? selectedRecord?.progress ?? 0;
  const activeMessage = jobProgressMessage(activeJob) || selectedRecord?.message || (uploadProgress ? "Uploading media..." : "Ready");
  const isWorking = Boolean(activeJobId) || createUrlJob.isPending || uploadJob.isPending;
  const obsidianDraft = useMemo(() => buildTranscriptObsidianDraft(selectedRecord), [selectedRecord]);

  useEffect(() => {
    if (!activeJob) return;
    if (activeJob.status === "completed") {
      setSelectedRecordId(activeJob.job_id);
      setActiveJobId(null);
      setUploadProgress(null);
      setToast("Transcript ready");
      queryClient.invalidateQueries({ queryKey: ["transcription-record", activeJob.job_id] });
    }
    if (activeJob.status === "failed") {
      setActiveJobId(null);
      setUploadProgress(null);
      setToast(activeJob.error || "Transcription failed");
    }
    if (activeJob.status === "cancelled") {
      setActiveJobId(null);
      setUploadProgress(null);
      setToast("Transcription stopped");
    }
  }, [activeJob, queryClient]);

  async function startUrlJob() {
    const url = sourceUrl.trim();
    if (!url) {
      setToast("Paste a media URL first");
      return;
    }

    setSelectedRecordId(null);
    setUploadProgress(null);
    const job = await createUrlJob.mutateAsync({
      url,
      language: whisper.language || null,
      whisperEndpoint: whisper.remote_endpoint || null
    });
    setActiveJobId(job.job_id);
    setToast("URL job started");
  }

  async function startFileJob(file: File) {
    setSourceUrl("");
    setSelectedRecordId(null);
    const job = await uploadJob.mutateAsync({
      file,
      language: whisper.language || null,
      whisperEndpoint: whisper.remote_endpoint || null,
      onProgress: setUploadProgress
    });
    setActiveJobId(job.job_id);
    setToast("Upload complete; transcription queued");
  }

  async function stopActiveJob() {
    if (!activeJobId) return;
    await cancelJob.mutateAsync(activeJobId);
    setToast("Stop requested");
  }

  function saveToObsidian() {
    if (!obsidianDraft) {
      setToast("Complete a transcript before saving");
      return;
    }
    openObsidianDraft(obsidianDraft);
    setToast("Opening Obsidian to create the note");
  }

  return (
    <PageScaffold>
      <WorkspacePanel>
        <Stack spacing={2.25}>
          <WorkflowStepper status={activeJob?.status || selectedRecord?.status} />
          <Divider />
          <Stack direction={{ xs: "column", md: "row" }} spacing={1.5}>
            <TextField
              fullWidth
              size="small"
              sx={{ "& .MuiOutlinedInput-root": { height: 40 } }}
              value={sourceUrl}
              onChange={(event) => setSourceUrl(event.target.value)}
              placeholder="Paste media URL, YouTube, Bilibili, Shorts, Instagram, Threads, or a direct file link"
              InputProps={{
                startAdornment: <LinkOutlinedIcon color="disabled" fontSize="small" sx={{ mr: 1 }} />
              }}
            />
            <Button
              variant="contained"
              color={isWorking ? "error" : "primary"}
              disabled={createUrlJob.isPending || uploadJob.isPending || cancelJob.isPending}
              onClick={isWorking ? stopActiveJob : startUrlJob}
              sx={{ height: 40, whiteSpace: "nowrap", flexShrink: 0 }}
            >
              {isWorking ? "Stop" : "Transcribe"}
            </Button>
            <Button
              variant="outlined"
              component="label"
              disabled={isWorking}
              sx={{ height: 40, whiteSpace: "nowrap", flexShrink: 0, minWidth: 112 }}
            >
              Choose File
              <input
                ref={fileInputRef}
                hidden
                type="file"
                accept="audio/*,video/*"
                onChange={(event) => {
                  const file = event.target.files?.[0];
                  if (file) void startFileJob(file);
                  event.target.value = "";
                }}
              />
            </Button>
          </Stack>
          <Stack spacing={1}>
            <Stack direction="row" justifyContent="space-between" alignItems="center">
              <Typography variant="body2" color="text.secondary" fontWeight={700}>
                {activeMessage}
              </Typography>
              <Typography variant="body2" color="text.secondary" fontWeight={700}>
                {Math.round(activeProgress)}%
              </Typography>
            </Stack>
            <LinearProgress value={Math.min(100, activeProgress)} variant="determinate" />
          </Stack>
          {createUrlJob.isError || uploadJob.isError || jobQuery.isError || recordQuery.isError ? (
            <Alert severity="error">
              {errorMessage(createUrlJob.error || uploadJob.error || jobQuery.error || recordQuery.error)}
            </Alert>
          ) : null}
        </Stack>
      </WorkspacePanel>

      <WorkspacePanel>
        <Stack spacing={1.5}>
          <Stack direction="row" justifyContent="space-between" alignItems="center">
            <Typography variant="h3">Obsidian Preview</Typography>
            <Button variant="contained" disabled={!obsidianDraft} onClick={saveToObsidian}>
              Save to Obsidian
            </Button>
          </Stack>
          <Divider />
          <ObsidianPreview draft={obsidianDraft} />
        </Stack>
      </WorkspacePanel>

      <Snackbar
        open={Boolean(toast)}
        autoHideDuration={2200}
        onClose={() => setToast("")}
        message={toast}
        anchorOrigin={{ vertical: "bottom", horizontal: "center" }}
      />
    </PageScaffold>
  );
}

function WorkflowStepper({ status }: { status?: string }) {
  return (
    <Stepper activeStep={statusToStepIndex(status)} alternativeLabel sx={compactStepperSx}>
      {steps.map((step) => (
        <Step key={step} completed={isStepCompleted(step, status)}>
          <StepLabel>{step}</StepLabel>
        </Step>
      ))}
    </Stepper>
  );
}

function ObsidianPreview({ draft }: { draft: ReturnType<typeof buildTranscriptObsidianDraft> }) {
  if (!draft) {
    return (
      <Stack alignItems="center" justifyContent="center" sx={{ minHeight: 520, color: "text.secondary" }}>
        <Typography>Complete a transcript to preview the note.</Typography>
      </Stack>
    );
  }

  return (
    <Paper
      sx={{
        p: 2,
        bgcolor: "#1F2330",
        color: "#F1F4FA",
        borderColor: "#343A4A",
        minHeight: 520,
        maxHeight: 720,
        overflow: "auto"
      }}
    >
      <Stack spacing={2}>
        <Typography sx={{ color: "#C8D2FF", fontSize: 18, fontWeight: 850, lineHeight: 1.35 }}>
          {draft.noteTitle}
        </Typography>
        <PreviewSection title="Properties">
          <Typography>title: {draft.noteTitle}</Typography>
          <Typography>sources: {draft.sources.length ? draft.sources.join(", ") : "--"}</Typography>
          <Typography>datetime: {draft.datetime}</Typography>
          <Typography>tags: {draft.tags.join(", ")}</Typography>
        </PreviewSection>
        <PreviewSection title="AI Polished Article">
          {draft.polishedContent || "AI article is not available for this transcript."}
        </PreviewSection>
        <PreviewSection title="Original Transcript">{draft.content}</PreviewSection>
      </Stack>
    </Paper>
  );
}

function PreviewSection({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <Box sx={{ pt: 1.5, borderTop: 1, borderColor: "#343A4A" }}>
      <Typography sx={{ color: "#C8D2FF", mb: 1, fontSize: 13, fontWeight: 850 }}>
        {title}
      </Typography>
      <Typography component="div" sx={{ whiteSpace: "pre-wrap", lineHeight: 1.75, fontSize: 14 }}>
        {children}
      </Typography>
    </Box>
  );
}

function statusToStepIndex(status?: string) {
  if (status === "completed") return 4;
  if (status === "running") return 1;
  if (status === "downloading") return 0;
  if (status === "queued") return 0;
  if (status === "failed" || status === "cancelled") return 0;
  return 0;
}

function isStepCompleted(step: string, status?: string) {
  if (status === "completed") return true;
  if (status === "running") return step === "Downloading";
  return false;
}

function jobProgressMessage(job?: TranscriptionJob) {
  if (!job) return "";
  if (job.message) return job.message;
  if (job.status === "completed") return "Transcript ready";
  return job.status;
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : "Something went wrong";
}
