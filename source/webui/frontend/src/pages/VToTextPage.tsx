import LinkOutlinedIcon from "@mui/icons-material/LinkOutlined";
import {
  Alert,
  Box,
  Button,
  Divider,
  LinearProgress,
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
import { chatWithLocalLlm } from "../api/localLlm";
import { useSettingsQuery } from "../api/settings";
import { LlmApiKeyDialog } from "../components/llm/LlmApiKeyDialog";
import { ObsidianNotePreview } from "../components/obsidian/ObsidianNotePreview";
import { compactStepperSx } from "../components/workflow/stepperStyles";
import { useLlmApiKey } from "../hooks/useLlmApiKey";
import { useGuardedWork } from "../hooks/useWorkGuard";
import {
  useCancelTranscriptionJobMutation,
  useCreateUrlTranscriptionJobMutation,
  useTranscriptionJobQuery,
  useTranscriptionRecordQuery,
  useUploadTranscriptionJobMutation
} from "../api/transcription";
import type { TranscriptionJob, TranscriptionRecord } from "../types/transcription";
import { buildTranscriptObsidianDraft, openObsidianDraft } from "../utils/obsidian";
import { PageScaffold, WorkspacePanel } from "./PageScaffold";

const steps = ["Source", "Transcribe", "AI Tags", "Ready"];
const V_TO_TEXT_STATE_KEY = "airtype:v-to-text:state";

type PersistedVToTextState = {
  activeJobId: string | null;
  selectedRecordId: string | null;
  sourceUrl: string;
  aiTags: string;
  aiTagsSourceKey: string;
};

export function VToTextPage() {
  const queryClient = useQueryClient();
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const restoredState = useMemo(readPersistedVToTextState, []);
  const [sourceUrl, setSourceUrl] = useState(restoredState.sourceUrl);
  const [selectedRecordId, setSelectedRecordId] = useState<string | null>(restoredState.selectedRecordId);
  const [activeJobId, setActiveJobId] = useState<string | null>(restoredState.activeJobId);
  const [uploadProgress, setUploadProgress] = useState<number | null>(null);
  const [aiTags, setAiTags] = useState(restoredState.aiTags);
  const [aiTagsSourceKey, setAiTagsSourceKey] = useState(restoredState.aiTagsSourceKey);
  const [isGeneratingAiTags, setIsGeneratingAiTags] = useState(false);
  const [toast, setToast] = useState("");

  const settingsQuery = useSettingsQuery();
  const jobQuery = useTranscriptionJobQuery(activeJobId, Boolean(activeJobId));
  const recordLookupId = selectedRecordId || activeJobId;
  const recordQuery = useTranscriptionRecordQuery(recordLookupId);
  const createUrlJob = useCreateUrlTranscriptionJobMutation();
  const uploadJob = useUploadTranscriptionJobMutation();
  const cancelJob = useCancelTranscriptionJobMutation();
  const llmApiKey = useLlmApiKey();

  const whisper = settingsQuery.data?.whisper || {};
  const activeJob = jobQuery.data;
  const selectedRecord = recordQuery.data;
  const isWorking = Boolean(activeJobId && !isTerminalStatus(selectedRecord?.status)) || createUrlJob.isPending || uploadJob.isPending;
  const obsidianDraft = useMemo(() => buildTranscriptObsidianDraft(selectedRecord, aiTags), [selectedRecord, aiTags]);
  const aiTagsSource = useMemo(() => transcriptAiTagsSource(selectedRecord), [selectedRecord]);
  const workflowStepIndex = voiceWorkflowStepIndex({
    status: activeJob?.status || selectedRecord?.status,
    hasRecord: Boolean(selectedRecord),
    hasTagSource: Boolean(aiTagsSource.key),
    tagsDone: !aiTagsSource.key || (aiTagsSourceKey === aiTagsSource.key && !isGeneratingAiTags),
    isSubmitting: uploadProgress !== null || createUrlJob.isPending || uploadJob.isPending,
    isGeneratingAiTags
  });
  const activeProgress = isGeneratingAiTags ? Math.max(92, selectedRecord?.progress ?? 0) : uploadProgress ?? activeJob?.progress ?? selectedRecord?.progress ?? 0;
  const activeMessage = isGeneratingAiTags
    ? "Generating AI tags"
    : jobProgressMessage(activeJob) || selectedRecord?.message || (uploadProgress ? "Uploading media..." : "Ready");

  useGuardedWork({
    id: "v-to-text",
    label: "Voice to Text",
    isActive: isWorking,
    onConfirmLeave: async () => {
      if (!activeJobId) return;
      await cancelJob.mutateAsync(activeJobId);
      setActiveJobId(null);
      setUploadProgress(null);
    }
  });

  useEffect(() => {
    writePersistedVToTextState({ activeJobId, selectedRecordId, sourceUrl, aiTags, aiTagsSourceKey });
  }, [activeJobId, selectedRecordId, sourceUrl, aiTags, aiTagsSourceKey]);

  useEffect(() => {
    if (!isWorking || !activeJobId) return;
    function handlePageHide() {
      navigator.sendBeacon?.(`/api/transcribe/jobs/${activeJobId}/cancel`, new Blob());
      writePersistedVToTextState({ activeJobId: null, selectedRecordId, sourceUrl, aiTags, aiTagsSourceKey });
    }

    window.addEventListener("pagehide", handlePageHide);
    return () => window.removeEventListener("pagehide", handlePageHide);
  }, [activeJobId, aiTags, aiTagsSourceKey, isWorking, selectedRecordId, sourceUrl]);

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

  useEffect(() => {
    if (!activeJobId || !selectedRecord) return;
    if (selectedRecord.status === "completed") {
      setSelectedRecordId(activeJobId);
      setActiveJobId(null);
      setUploadProgress(null);
      queryClient.invalidateQueries({ queryKey: ["transcription-record", activeJobId] });
    }
    if (selectedRecord.status === "failed" || selectedRecord.status === "cancelled") {
      setActiveJobId(null);
      setUploadProgress(null);
    }
  }, [activeJobId, selectedRecord, queryClient]);

  useEffect(() => {
    if (!aiTagsSource.key) {
      setAiTags("");
      setAiTagsSourceKey("");
      setIsGeneratingAiTags(false);
      return;
    }
    if (aiTagsSourceKey === aiTagsSource.key) return;

    let cancelled = false;
    setIsGeneratingAiTags(true);
    setAiTags("");
    setAiTagsSourceKey(aiTagsSource.key);

    async function generateTranscriptAiTags() {
      try {
        const apiKey = await llmApiKey.ensureApiKey(settingsQuery.data || {});
        const response = await chatWithLocalLlm(
          settingsQuery.data || {},
          buildAiTagsPrompt(aiTagsSource.content, aiTagsSource.title),
          "你是擅長資訊整理的繁體中文知識管理助手。只輸出可直接貼進 Obsidian 的 hashtag 清單。",
          apiKey
        );
        if (!cancelled) {
          const tags = normalizeAiTags(response);
          setAiTags(tags);
          if (tags) setToast("AI tags generated");
        }
      } catch (caught) {
        if (!cancelled) {
          const message = caught instanceof Error ? caught.message : "AI tags unavailable";
          setToast(message);
        }
      } finally {
        if (!cancelled) setIsGeneratingAiTags(false);
      }
    }

    void generateTranscriptAiTags();

    return () => {
      cancelled = true;
    };
  }, [aiTagsSource, aiTagsSourceKey, llmApiKey, settingsQuery.data]);

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
    writePersistedVToTextState({ activeJobId: job.job_id, selectedRecordId: null, sourceUrl: url, aiTags, aiTagsSourceKey });
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
    writePersistedVToTextState({ activeJobId: job.job_id, selectedRecordId: null, sourceUrl: "", aiTags, aiTagsSourceKey });
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
    openObsidianDraft(obsidianDraft, settingsQuery.data?.obsidian?.default_folder);
    setToast("Opening Obsidian to create the note");
  }

  return (
    <PageScaffold>
      <WorkspacePanel>
        <Stack spacing={2.25} sx={{ minWidth: 0 }}>
          <Box
            sx={{
              alignItems: "center",
              display: "grid",
              gap: { xs: 1.5, md: 3 },
              gridTemplateColumns: { xs: "1fr", md: "minmax(360px, 520px) minmax(280px, 420px)" },
              justifyContent: "center",
              minWidth: 0
            }}
          >
            <Box sx={{ minWidth: 0, overflowX: "auto", pb: 0.5 }}>
              <WorkflowStepper activeStep={workflowStepIndex} />
            </Box>
            <Stack spacing={1} sx={{ width: "100%", maxWidth: 420, mx: "auto", minWidth: 0 }}>
              <Stack direction="row" justifyContent="space-between" alignItems="center" spacing={1}>
                <Typography variant="body2" color="text.secondary" fontWeight={700} noWrap>
                  {activeMessage}
                </Typography>
                <Typography variant="body2" color="text.secondary" fontWeight={700} sx={{ flexShrink: 0 }}>
                  {Math.round(activeProgress)}%
                </Typography>
              </Stack>
              <LinearProgress value={Math.min(100, activeProgress)} variant="determinate" />
            </Stack>
          </Box>
          <Divider />
          <Stack direction={{ xs: "column", sm: "row" }} spacing={1.5} sx={{ minWidth: 0 }}>
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
          {createUrlJob.isError || uploadJob.isError || (jobQuery.isError && !selectedRecord) || (selectedRecordId && recordQuery.isError) ? (
            <Alert severity="error">
              {errorMessage(createUrlJob.error || uploadJob.error || (!selectedRecord ? jobQuery.error : null) || recordQuery.error)}
            </Alert>
          ) : null}
        </Stack>
      </WorkspacePanel>

      <WorkspacePanel>
        <Stack spacing={1.5}>
          <Stack direction={{ xs: "column", sm: "row" }} justifyContent="space-between" alignItems={{ xs: "stretch", sm: "center" }} spacing={1}>
            <Typography variant="h3">Obsidian Preview</Typography>
            <Button variant="contained" disabled={!obsidianDraft} onClick={saveToObsidian} sx={{ whiteSpace: "nowrap" }}>
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
      <LlmApiKeyDialog
        open={Boolean(llmApiKey.pendingRequest)}
        endpoint={llmApiKey.pendingRequest?.endpoint}
        provider={llmApiKey.pendingRequest?.provider}
        onSubmit={llmApiKey.submitApiKey}
        onCancel={llmApiKey.cancelApiKey}
      />
    </PageScaffold>
  );
}

function WorkflowStepper({ activeStep }: { activeStep: number }) {
  return (
    <Stepper activeStep={activeStep} alternativeLabel sx={compactStepperSx}>
      {steps.map((step, index) => (
        <Step key={step} completed={index < activeStep}>
          <StepLabel>{step}</StepLabel>
        </Step>
      ))}
    </Stepper>
  );
}

function ObsidianPreview({ draft }: { draft: ReturnType<typeof buildTranscriptObsidianDraft> }) {
  return (
    <ObsidianNotePreview
      draft={draft}
      emptyMessage="Complete a transcript to preview the note."
      polishedFallback="AI article is not available for this transcript."
      originalTitle="Original Transcript"
    />
  );
}

function voiceWorkflowStepIndex({
  status,
  hasRecord,
  hasTagSource,
  tagsDone,
  isSubmitting,
  isGeneratingAiTags
}: {
  status?: string;
  hasRecord: boolean;
  hasTagSource: boolean;
  tagsDone: boolean;
  isSubmitting: boolean;
  isGeneratingAiTags: boolean;
}) {
  if (isSubmitting || status === "queued" || status === "downloading") return 0;
  if (status === "running") return 1;
  if (isGeneratingAiTags || (hasRecord && hasTagSource && !tagsDone)) return 2;
  if (status === "completed" || hasRecord) return 3;
  return 0;
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

function isTerminalStatus(status?: string) {
  return status === "completed" || status === "failed" || status === "cancelled";
}

function transcriptAiTagsSource(record?: TranscriptionRecord | null) {
  if (!record) return { key: "", title: "", content: "" };
  const content =
    record.article?.text?.trim() ||
    record.transcript?.text?.trim() ||
    (record.transcript?.segments || []).map((segment) => segment.text || "").join("\n").trim();
  if (!content) return { key: "", title: "", content: "" };
  const title = record.article?.title || record.title || record.source?.name || "Untitled transcript";
  return {
    key: `${record.job_id || title}|${title}|${content.slice(0, 2000)}`,
    title,
    content
  };
}

function buildAiTagsPrompt(content: string, title: string) {
  return `請根據以下文章產生 5 到 8 組 Obsidian hashtag。

要求：
1. 每一組包含一個繁體中文 hashtag 與一個對應英文 hashtag。
2. 英文若有常見縮寫，請優先使用縮寫，例如 AI、LLM、API、GPU、CPU、SaaS。
3. hashtag 不要有空格、標點或解釋文字。
4. 每行只輸出一組，格式固定為：#中文標籤 #EnglishTag
5. 不要輸出編號、前言、結語、Markdown code block。

標題：${title || "未命名"}

文章：
${content}`;
}

function normalizeAiTags(text = "") {
  return String(text)
    .replace(/```[\s\S]*?```/g, (block) => block.replace(/```[a-zA-Z]*\n?/g, "").replace(/```/g, ""))
    .split(/\r?\n/)
    .map((line) => line.replace(/^\s*(?:[-*]|\d+[.)])\s*/, "").trim())
    .filter(Boolean)
    .filter((line) => line.includes("#"))
    .slice(0, 8)
    .join("\n");
}

function readPersistedVToTextState(): PersistedVToTextState {
  const fallback = { activeJobId: null, selectedRecordId: null, sourceUrl: "", aiTags: "", aiTagsSourceKey: "" };
  if (typeof window === "undefined") return fallback;
  try {
    const value = window.sessionStorage.getItem(V_TO_TEXT_STATE_KEY) || window.localStorage.getItem(V_TO_TEXT_STATE_KEY);
    if (!value) return fallback;
    const parsed = JSON.parse(value) as Partial<PersistedVToTextState>;
    return {
      activeJobId: typeof parsed.activeJobId === "string" && parsed.activeJobId ? parsed.activeJobId : null,
      selectedRecordId: typeof parsed.selectedRecordId === "string" && parsed.selectedRecordId ? parsed.selectedRecordId : null,
      sourceUrl: typeof parsed.sourceUrl === "string" ? parsed.sourceUrl : "",
      aiTags: typeof parsed.aiTags === "string" ? parsed.aiTags : "",
      aiTagsSourceKey: typeof parsed.aiTagsSourceKey === "string" ? parsed.aiTagsSourceKey : ""
    };
  } catch {
    return fallback;
  }
}

function writePersistedVToTextState(state: PersistedVToTextState) {
  if (typeof window === "undefined") return;
  try {
    const value = JSON.stringify(state);
    window.sessionStorage.setItem(V_TO_TEXT_STATE_KEY, value);
    window.localStorage.setItem(V_TO_TEXT_STATE_KEY, value);
  } catch {
    // If storage is unavailable, the in-memory state still keeps the current page usable.
  }
}
