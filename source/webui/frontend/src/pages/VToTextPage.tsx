import AudioFileOutlinedIcon from "@mui/icons-material/AudioFileOutlined";
import ContentCopyOutlinedIcon from "@mui/icons-material/ContentCopyOutlined";
import LinkOutlinedIcon from "@mui/icons-material/LinkOutlined";
import StopCircleOutlinedIcon from "@mui/icons-material/StopCircleOutlined";
import UploadFileOutlinedIcon from "@mui/icons-material/UploadFileOutlined";
import {
  Alert,
  Box,
  Button,
  Chip,
  Divider,
  LinearProgress,
  List,
  ListItemButton,
  ListItemText,
  Paper,
  Snackbar,
  Stack,
  TextField,
  Typography
} from "@mui/material";
import { useEffect, useMemo, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useSettingsQuery } from "../api/settings";
import {
  useCancelTranscriptionJobMutation,
  useCreateUrlTranscriptionJobMutation,
  useTranscriptionJobQuery,
  useTranscriptionRecordQuery,
  useTranscriptionRecordsQuery,
  useUploadTranscriptionJobMutation
} from "../api/transcription";
import type { TranscriptionJob, TranscriptionRecordSummary, TranscriptSegment } from "../types/transcription";
import { formatBytes, formatDateTime, formatSeconds } from "../utils/format";
import { buildTranscriptObsidianDraft, openObsidianDraft } from "../utils/obsidian";
import { PageScaffold, WorkspacePanel } from "./PageScaffold";

const steps = ["downloading", "transcripting", "polishing", "titled", "done"];

export function VToTextPage() {
  const queryClient = useQueryClient();
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [sourceUrl, setSourceUrl] = useState("");
  const [selectedRecordId, setSelectedRecordId] = useState<string | null>(null);
  const [activeJobId, setActiveJobId] = useState<string | null>(null);
  const [uploadProgress, setUploadProgress] = useState<number | null>(null);
  const [toast, setToast] = useState("");

  const settingsQuery = useSettingsQuery();
  const recordsQuery = useTranscriptionRecordsQuery();
  const jobQuery = useTranscriptionJobQuery(activeJobId, Boolean(activeJobId));
  const recordQuery = useTranscriptionRecordQuery(selectedRecordId);
  const createUrlJob = useCreateUrlTranscriptionJobMutation();
  const uploadJob = useUploadTranscriptionJobMutation();
  const cancelJob = useCancelTranscriptionJobMutation();

  const whisper = settingsQuery.data?.whisper || {};
  const activeJob = jobQuery.data;
  const selectedRecord = recordQuery.data;
  const activeProgress = uploadProgress ?? activeJob?.progress ?? 0;
  const activeMessage = jobProgressMessage(activeJob) || (uploadProgress ? "Uploading media..." : "Ready");
  const isWorking = Boolean(activeJobId) || createUrlJob.isPending || uploadJob.isPending;
  const displayedSegments = normalizeSegments(
    activeJob?.partial_segments?.length ? activeJob.partial_segments : selectedRecord?.transcript?.segments
  );
  const obsidianDraft = useMemo(() => buildTranscriptObsidianDraft(selectedRecord), [selectedRecord]);

  useEffect(() => {
    if (!activeJob) return;
    if (activeJob.status === "completed") {
      setSelectedRecordId(activeJob.job_id);
      setActiveJobId(null);
      setUploadProgress(null);
      setToast("Transcript ready");
      queryClient.invalidateQueries({ queryKey: ["transcription-records"] });
      queryClient.invalidateQueries({ queryKey: ["transcription-record", activeJob.job_id] });
    }
    if (activeJob.status === "failed") {
      setActiveJobId(null);
      setUploadProgress(null);
      setToast(activeJob.error || "Transcription failed");
      queryClient.invalidateQueries({ queryKey: ["transcription-records"] });
    }
    if (activeJob.status === "cancelled") {
      setActiveJobId(null);
      setUploadProgress(null);
      setToast("Transcription stopped");
      queryClient.invalidateQueries({ queryKey: ["transcription-records"] });
    }
  }, [activeJob, queryClient]);

  async function startUrlJob() {
    const url = sourceUrl.trim();
    if (!url) {
      setToast("Paste a media URL first");
      return;
    }

    setUploadProgress(null);
    const job = await createUrlJob.mutateAsync({
      url,
      language: whisper.language || null,
      whisperEndpoint: whisper.remote_endpoint || null
    });
    setSelectedRecordId(job.job_id);
    setActiveJobId(job.job_id);
    setToast("URL job started");
  }

  async function startFileJob(file: File) {
    setSourceUrl("");
    const job = await uploadJob.mutateAsync({
      file,
      language: whisper.language || null,
      whisperEndpoint: whisper.remote_endpoint || null,
      onProgress: setUploadProgress
    });
    setSelectedRecordId(job.job_id);
    setActiveJobId(job.job_id);
    setToast("Upload complete; transcription queued");
  }

  async function stopActiveJob() {
    if (!activeJobId) return;
    await cancelJob.mutateAsync(activeJobId);
    setToast("Stop requested");
  }

  async function copyTranscript() {
    const text = selectedRecord?.transcript?.text || displayedSegments.map((segment) => segment.text).join("\n");
    if (!text.trim()) {
      setToast("No transcript text to copy");
      return;
    }
    await navigator.clipboard.writeText(text);
    setToast("Transcript copied");
  }

  function saveToObsidian() {
    if (!obsidianDraft) {
      setToast("Complete or select a transcript before saving");
      return;
    }
    openObsidianDraft(obsidianDraft);
    setToast("Opening Obsidian to create the note");
  }

  return (
    <PageScaffold title="V to Text" eyebrow="Transcription workflow">
      <WorkspacePanel>
        <Stack spacing={2}>
          <WorkflowSteps status={activeJob?.status} />
          <Divider />
          <Stack direction={{ xs: "column", md: "row" }} spacing={1.5}>
            <TextField
              fullWidth
              size="small"
              value={sourceUrl}
              onChange={(event) => setSourceUrl(event.target.value)}
              placeholder="Paste media URL, YouTube, Bilibili, Shorts, Instagram, Threads, or a direct file link"
              InputProps={{
                startAdornment: <LinkOutlinedIcon color="disabled" fontSize="small" sx={{ mr: 1 }} />
              }}
            />
            <Button variant="contained" disabled={isWorking} onClick={startUrlJob}>
              Transcribe
            </Button>
            <Button
              variant="outlined"
              startIcon={<UploadFileOutlinedIcon />}
              component="label"
              disabled={isWorking}
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
            <Button
              variant="outlined"
              color="error"
              startIcon={<StopCircleOutlinedIcon />}
              disabled={!activeJobId || cancelJob.isPending}
              onClick={stopActiveJob}
            >
              Stop
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
            <LinearProgress variant={isWorking ? "determinate" : "determinate"} value={Math.min(100, activeProgress)} />
          </Stack>
          {createUrlJob.isError || uploadJob.isError || jobQuery.isError ? (
            <Alert severity="error">{errorMessage(createUrlJob.error || uploadJob.error || jobQuery.error)}</Alert>
          ) : null}
        </Stack>
      </WorkspacePanel>

      <Box
        sx={{
          display: "grid",
          gridTemplateColumns: { xs: "1fr", lg: "320px minmax(0, 1fr)" },
          gap: 2,
          minHeight: 0
        }}
      >
        <HistoryPanel
          records={recordsQuery.data || []}
          selectedRecordId={selectedRecordId}
          onSelect={(recordId) => {
            setSelectedRecordId(recordId);
            setActiveJobId(null);
            setUploadProgress(null);
          }}
        />
        <WorkspacePanel>
          <Stack spacing={2}>
            <Stack direction="row" justifyContent="space-between" alignItems="center" spacing={1}>
              <Box sx={{ minWidth: 0 }}>
                <Typography variant="h3" noWrap>
                  {activeJob?.title || selectedRecord?.title || "Transcript"}
                </Typography>
                <Typography variant="body2" color="text.secondary" noWrap>
                  {sourceSummary(activeJob, selectedRecord)}
                </Typography>
              </Box>
              <Button variant="outlined" startIcon={<ContentCopyOutlinedIcon />} onClick={copyTranscript}>
                Copy Text
              </Button>
            </Stack>
            <Divider />
            <SegmentsPanel segments={displayedSegments} />
          </Stack>
        </WorkspacePanel>
      </Box>

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

function WorkflowSteps({ status }: { status?: string }) {
  const activeIndex = statusToStepIndex(status);
  return (
    <Stack direction="row" spacing={1} sx={{ overflowX: "auto", pb: 0.5 }}>
      {steps.map((step, index) => (
        <Stack key={step} direction="row" alignItems="center" spacing={1} sx={{ minWidth: 150, flex: 1 }}>
          <Typography
            sx={{
              display: "grid",
              placeItems: "center",
              width: 28,
              height: 28,
              borderRadius: "50%",
              bgcolor: index <= activeIndex ? "primary.light" : "background.default",
              color: index <= activeIndex ? "primary.dark" : "text.secondary",
              border: 1,
              borderColor: index <= activeIndex ? "primary.main" : "divider",
              fontWeight: 800
            }}
          >
            {index + 1}
          </Typography>
          <Typography color={index <= activeIndex ? "text.primary" : "text.secondary"} fontWeight={700}>
            {step}
          </Typography>
        </Stack>
      ))}
    </Stack>
  );
}

function HistoryPanel({
  records,
  selectedRecordId,
  onSelect
}: {
  records: TranscriptionRecordSummary[];
  selectedRecordId: string | null;
  onSelect: (recordId: string) => void;
}) {
  return (
    <WorkspacePanel>
      <Stack spacing={1.5}>
        <Stack direction="row" alignItems="center" justifyContent="space-between">
          <Typography variant="h3">History</Typography>
          <Chip size="small" label={`${records.length} records`} variant="outlined" />
        </Stack>
        <Divider />
        <List disablePadding sx={{ display: "grid", gap: 1, maxHeight: 520, overflow: "auto" }}>
          {records.slice(0, 24).map((record) => (
            <ListItemButton
              key={record.job_id}
              selected={record.job_id === selectedRecordId}
              onClick={() => onSelect(record.job_id)}
              sx={{ border: 1, borderColor: "divider" }}
            >
              <ListItemText
                primary={record.title || record.source?.name || "Untitled transcript"}
                secondary={`${formatDateTime(record.updated_at)} · ${record.result?.segment_count ?? 0} segments`}
                primaryTypographyProps={{ fontSize: 13, fontWeight: 800, noWrap: true }}
                secondaryTypographyProps={{ fontSize: 12, noWrap: true }}
              />
            </ListItemButton>
          ))}
          {!records.length ? (
            <Typography color="text.secondary">Completed transcripts will appear here.</Typography>
          ) : null}
        </List>
      </Stack>
    </WorkspacePanel>
  );
}

function SegmentsPanel({ segments }: { segments: NormalizedSegment[] }) {
  if (!segments.length) {
    return (
      <Stack alignItems="center" justifyContent="center" spacing={1} sx={{ minHeight: 360, color: "text.secondary" }}>
        <AudioFileOutlinedIcon />
        <Typography>Transcript segments will appear here.</Typography>
      </Stack>
    );
  }

  return (
    <Stack spacing={1} sx={{ maxHeight: 560, overflow: "auto", pr: 0.5 }}>
      {segments.map((segment, index) => (
        <Paper key={`${segment.id}-${index}`} variant="outlined" sx={{ p: 1.5 }}>
          <Stack direction={{ xs: "column", md: "row" }} spacing={2}>
            <Box sx={{ width: { md: 150 }, flexShrink: 0 }}>
              <Typography variant="body2" fontWeight={800}>
                {segment.time}
              </Typography>
              <Typography variant="caption" color="text.secondary">
                {segment.durationText}
              </Typography>
            </Box>
            <Typography sx={{ lineHeight: 1.7, whiteSpace: "pre-wrap" }}>{segment.text}</Typography>
          </Stack>
        </Paper>
      ))}
    </Stack>
  );
}

function ObsidianPreview({ draft }: { draft: ReturnType<typeof buildTranscriptObsidianDraft> }) {
  if (!draft) {
    return (
      <Stack alignItems="center" justifyContent="center" sx={{ minHeight: 260, color: "text.secondary" }}>
        <Typography>Complete or select a transcript to preview the note.</Typography>
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
        maxHeight: 520,
        overflow: "auto"
      }}
    >
      <Stack spacing={2}>
        <Typography variant="h2" sx={{ color: "#C8D2FF" }}>
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
      <Typography variant="h3" sx={{ color: "#C8D2FF", mb: 1 }}>
        {title}
      </Typography>
      <Typography component="div" sx={{ whiteSpace: "pre-wrap", lineHeight: 1.7 }}>
        {children}
      </Typography>
    </Box>
  );
}

type NormalizedSegment = {
  id: string | number;
  time: string;
  durationText: string;
  text: string;
};

function normalizeSegments(segments?: TranscriptSegment[]): NormalizedSegment[] {
  if (!segments?.length) return [];
  return segments.map((segment, index) => {
    const start = segment.start ?? 0;
    const end = segment.end ?? 0;
    const hasTimestamps = segment.has_timestamps !== false && segment.start !== null && segment.end !== null;
    return {
      id: segment.id ?? index,
      time: segment.time || (hasTimestamps ? `${formatSeconds(start)} -> ${formatSeconds(end)}` : "time unavailable"),
      durationText:
        segment.duration_text || (hasTimestamps ? `${Math.max(0, Number(end) - Number(start)).toFixed(1)}s` : ""),
      text: segment.text || ""
    };
  });
}

function statusToStepIndex(status?: string) {
  if (status === "completed") return 4;
  if (status === "running") return 1;
  if (status === "downloading") return 0;
  if (status === "queued") return 0;
  if (status === "failed" || status === "cancelled") return 0;
  return 0;
}

function jobProgressMessage(job?: TranscriptionJob) {
  if (!job) return "";
  if (job.message) return job.message;
  if (job.status === "completed") return "Transcript ready";
  return job.status;
}

function sourceSummary(job?: TranscriptionJob, record?: TranscriptionRecordSummary | null) {
  const title = job?.source_name || record?.source?.name || "No source selected";
  const type = job?.source_type || record?.source?.type || "--";
  const size = formatBytes(job?.source_size ?? record?.source?.size);
  return `${title} · ${type} · ${size}`;
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : "Something went wrong";
}
