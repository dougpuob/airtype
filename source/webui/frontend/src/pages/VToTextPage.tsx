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
import { DEFAULT_AI_TITLE_SYSTEM_PROMPT, fallbackAiTitle, normalizeAiTitle } from "../utils/aiTitle";
import { buildTranscriptObsidianDraft, openObsidianDraft } from "../utils/obsidian";
import { PageScaffold, WorkspacePanel } from "./PageScaffold";

const V_TO_TEXT_STATE_KEY = "airtype:v-to-text:state";

type PersistedVToTextState = {
  activeJobId: string | null;
  selectedRecordId: string | null;
  sourceUrl: string;
  aiTitle: string;
  aiTitleSourceKey: string;
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
  const [aiTitle, setAiTitle] = useState(restoredState.aiTitle);
  const [aiTitleSourceKey, setAiTitleSourceKey] = useState(restoredState.aiTitleSourceKey);
  const [isGeneratingAiTitle, setIsGeneratingAiTitle] = useState(false);
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
  const aiTitleEnabled = settingsQuery.data?.capture_post?.ai_title_enabled ?? true;
  const aiTitleSystemPrompt =
    settingsQuery.data?.capture_post?.title_system_prompt ?? DEFAULT_AI_TITLE_SYSTEM_PROMPT;
  const activeJob = jobQuery.data;
  const selectedRecord = recordQuery.data;
  const isWorking = Boolean(activeJobId && !isTerminalStatus(selectedRecord?.status)) || createUrlJob.isPending || uploadJob.isPending;
  const aiTitleSource = useMemo(() => transcriptAiSource(selectedRecord), [selectedRecord]);
  const aiTitleRequestKey = aiTitleSource.key
    ? `${aiTitleSource.key}|${aiTitleEnabled ? "ai" : "plain"}|${aiTitleSystemPrompt}`
    : "";
  const aiTitleDone =
    !aiTitleRequestKey || (aiTitleSourceKey === aiTitleRequestKey && !isGeneratingAiTitle);
  const effectiveAiTitle = aiTitleSourceKey === aiTitleRequestKey ? aiTitle : "";
  const aiTagsSource = useMemo(
    () => transcriptAiSource(selectedRecord, effectiveAiTitle),
    [effectiveAiTitle, selectedRecord]
  );
  const aiTagsRequestKey = aiTagsSource.key ? `${aiTagsSource.key}|${aiTagsSource.title}` : "";
  const obsidianDraft = useMemo(
    () => buildTranscriptObsidianDraft(selectedRecord, aiTags, effectiveAiTitle),
    [aiTags, effectiveAiTitle, selectedRecord]
  );
  const workflowStepIndex = voiceWorkflowStepIndex({
    status: activeJob?.status || selectedRecord?.status,
    hasRecord: Boolean(selectedRecord),
    hasTitleSource: Boolean(aiTitleSource.key),
    titleDone: aiTitleDone,
    hasTagSource: Boolean(aiTagsSource.key),
    tagsDone: !aiTagsRequestKey || (aiTagsSourceKey === aiTagsRequestKey && !isGeneratingAiTags),
    isSubmitting: uploadProgress !== null || createUrlJob.isPending || uploadJob.isPending,
    isGeneratingAiTitle,
    isGeneratingAiTags
  });
  const activeProgress = isGeneratingAiTags
    ? Math.max(94, selectedRecord?.progress ?? 0)
    : isGeneratingAiTitle
      ? Math.max(86, selectedRecord?.progress ?? 0)
      : uploadProgress ?? activeJob?.progress ?? selectedRecord?.progress ?? 0;
  const activeMessage = isGeneratingAiTitle
    ? "Generating AI title"
    : isGeneratingAiTags
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
    writePersistedVToTextState({
      activeJobId,
      selectedRecordId,
      sourceUrl,
      aiTitle,
      aiTitleSourceKey,
      aiTags,
      aiTagsSourceKey
    });
  }, [activeJobId, selectedRecordId, sourceUrl, aiTitle, aiTitleSourceKey, aiTags, aiTagsSourceKey]);

  useEffect(() => {
    if (!isWorking || !activeJobId) return;
    function handlePageHide() {
      navigator.sendBeacon?.(`/api/transcribe/jobs/${activeJobId}/cancel`, new Blob());
      writePersistedVToTextState({
        activeJobId: null,
        selectedRecordId,
        sourceUrl,
        aiTitle,
        aiTitleSourceKey,
        aiTags,
        aiTagsSourceKey
      });
    }

    window.addEventListener("pagehide", handlePageHide);
    return () => window.removeEventListener("pagehide", handlePageHide);
  }, [activeJobId, aiTitle, aiTitleSourceKey, aiTags, aiTagsSourceKey, isWorking, selectedRecordId, sourceUrl]);

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
    if (!aiTitleRequestKey) {
      setAiTitle("");
      setAiTitleSourceKey("");
      setIsGeneratingAiTitle(false);
      return;
    }
    if (aiTitleSourceKey === aiTitleRequestKey) return;

    let cancelled = false;
    const fallback = fallbackAiTitle(aiTitleSource.content);
    if (!aiTitleEnabled) {
      setAiTitle(aiTitleSource.title || fallback);
      setAiTitleSourceKey(aiTitleRequestKey);
      setIsGeneratingAiTitle(false);
      return;
    }
    setIsGeneratingAiTitle(true);
    setAiTitle("");

    async function generateTranscriptAiTitle() {
      try {
        const apiKey = await llmApiKey.ensureApiKey(settingsQuery.data || {});
        const response = await chatWithLocalLlm(
          settingsQuery.data || {},
          aiTitleSource.content,
          aiTitleSystemPrompt,
          apiKey
        );
        if (!cancelled) {
          setAiTitle(normalizeAiTitle(response) || fallback);
          setToast("AI title generated");
        }
      } catch {
        if (!cancelled) {
          setAiTitle(fallback);
          setToast("AI title unavailable; using fallback title");
        }
      } finally {
        if (!cancelled) {
          setAiTitleSourceKey(aiTitleRequestKey);
          setIsGeneratingAiTitle(false);
        }
      }
    }

    void generateTranscriptAiTitle();

    return () => {
      cancelled = true;
    };
  }, [
    aiTitleEnabled,
    aiTitleRequestKey,
    aiTitleSource,
    aiTitleSourceKey,
    aiTitleSystemPrompt,
    settingsQuery.data
  ]);

  useEffect(() => {
    if (!aiTitleDone) return;
    if (!aiTagsSource.key) {
      setAiTags("");
      setAiTagsSourceKey("");
      setIsGeneratingAiTags(false);
      return;
    }
    if (aiTagsSourceKey === aiTagsRequestKey) return;

    let cancelled = false;
    setIsGeneratingAiTags(true);
    setAiTags("");

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
        if (!cancelled) {
          setAiTagsSourceKey(aiTagsRequestKey);
          setIsGeneratingAiTags(false);
        }
      }
    }

    void generateTranscriptAiTags();

    return () => {
      cancelled = true;
    };
  }, [aiTagsRequestKey, aiTagsSource, aiTagsSourceKey, aiTitleDone, settingsQuery.data]);

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
    writePersistedVToTextState({
      activeJobId: job.job_id,
      selectedRecordId: null,
      sourceUrl: url,
      aiTitle,
      aiTitleSourceKey,
      aiTags,
      aiTagsSourceKey
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
    writePersistedVToTextState({
      activeJobId: job.job_id,
      selectedRecordId: null,
      sourceUrl: "",
      aiTitle,
      aiTitleSourceKey,
      aiTags,
      aiTagsSourceKey
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
    openObsidianDraft(obsidianDraft, {
      vaultName: settingsQuery.data?.obsidian?.vault_name,
      defaultFolder: settingsQuery.data?.obsidian?.default_folder
    });
    setToast("Opening Obsidian to create the note");
  }

  return (
    <PageScaffold>
      <WorkspacePanel>
        <Stack spacing={2.25} sx={{ minWidth: 0 }}>
          <Box
            sx={{
              alignItems: "stretch",
              display: "grid",
              gap: { xs: 1.5, md: 2.5 },
              gridTemplateColumns: { xs: "1fr", md: "minmax(0, 3fr) minmax(0, 7fr)" },
              minWidth: 0
            }}
          >
            <Box sx={{ alignContent: "center", minWidth: 0, overflowX: "auto", pb: 0.5 }}>
              <WorkflowStepper activeStep={workflowStepIndex} aiTitleEnabled={aiTitleEnabled} />
            </Box>
            <Box
              sx={{
                alignItems: "stretch",
                display: "grid",
                gap: { xs: 1.25, sm: 1.5 },
                gridTemplateColumns: { xs: "1fr", sm: "minmax(0, 1fr) auto" },
                minWidth: 0
              }}
            >
              <Stack spacing={1} sx={{ minWidth: 0 }}>
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
              <Stack direction={{ xs: "column", sm: "row" }} spacing={1} sx={{ alignSelf: "end", minWidth: 0 }}>
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
              <TextField
                fullWidth
                size="small"
                sx={{ gridColumn: { sm: "1 / -1" }, "& .MuiOutlinedInput-root": { height: 40 } }}
                value={sourceUrl}
                onChange={(event) => setSourceUrl(event.target.value)}
                placeholder="Paste media URL, YouTube, Bilibili, Shorts, Instagram, Threads, or a direct file link"
                InputProps={{
                  startAdornment: <LinkOutlinedIcon color="disabled" fontSize="small" sx={{ mr: 1 }} />
                }}
              />
            </Box>
          </Box>
          <Divider />
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

function WorkflowStepper({ activeStep, aiTitleEnabled }: { activeStep: number; aiTitleEnabled: boolean }) {
  const steps = ["Source", "AI Transcribe", aiTitleEnabled ? "AI Title" : "Title", "AI Tags", "Ready"];
  return (
    <Stack spacing={0.5}>
      <Typography
        color="text.primary"
        sx={{ fontSize: 13, fontWeight: 780, lineHeight: 1.25, textAlign: "center" }}
      >
        Voice to Text
      </Typography>
      <Stepper activeStep={activeStep} alternativeLabel sx={compactStepperSx}>
        {steps.map((step, index) => (
          <Step key={step} completed={index < activeStep}>
            <StepLabel>{step}</StepLabel>
          </Step>
        ))}
      </Stepper>
    </Stack>
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
  hasTitleSource,
  titleDone,
  hasTagSource,
  tagsDone,
  isSubmitting,
  isGeneratingAiTitle,
  isGeneratingAiTags
}: {
  status?: string;
  hasRecord: boolean;
  hasTitleSource: boolean;
  titleDone: boolean;
  hasTagSource: boolean;
  tagsDone: boolean;
  isSubmitting: boolean;
  isGeneratingAiTitle: boolean;
  isGeneratingAiTags: boolean;
}) {
  if (isSubmitting || status === "queued" || status === "downloading") return 0;
  if (status === "running") return 1;
  if (isGeneratingAiTitle || (hasRecord && hasTitleSource && !titleDone)) return 2;
  if (isGeneratingAiTags || (hasRecord && hasTagSource && !tagsDone)) return 3;
  if (status === "completed" || hasRecord) return 4;
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

function transcriptAiSource(record?: TranscriptionRecord | null, titleOverride = "") {
  if (!record) return { key: "", title: "", content: "" };
  const content =
    record.article?.text?.trim() ||
    record.transcript?.text?.trim() ||
    (record.transcript?.segments || []).map((segment) => segment.text || "").join("\n").trim();
  if (!content) return { key: "", title: "", content: "" };
  const title = titleOverride || record.article?.title || record.title || record.source?.name || "Untitled transcript";
  return {
    key: `${record.job_id || record.title || "transcript"}|${content.slice(0, 2000)}`,
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
  const fallback: PersistedVToTextState = {
    activeJobId: null,
    selectedRecordId: null,
    sourceUrl: "",
    aiTitle: "",
    aiTitleSourceKey: "",
    aiTags: "",
    aiTagsSourceKey: ""
  };
  if (typeof window === "undefined") return fallback;
  try {
    const value = window.sessionStorage.getItem(V_TO_TEXT_STATE_KEY) || window.localStorage.getItem(V_TO_TEXT_STATE_KEY);
    if (!value) return fallback;
    const parsed = JSON.parse(value) as Partial<PersistedVToTextState>;
    return {
      activeJobId: typeof parsed.activeJobId === "string" && parsed.activeJobId ? parsed.activeJobId : null,
      selectedRecordId: typeof parsed.selectedRecordId === "string" && parsed.selectedRecordId ? parsed.selectedRecordId : null,
      sourceUrl: typeof parsed.sourceUrl === "string" ? parsed.sourceUrl : "",
      aiTitle: typeof parsed.aiTitle === "string" ? parsed.aiTitle : "",
      aiTitleSourceKey: typeof parsed.aiTitleSourceKey === "string" ? parsed.aiTitleSourceKey : "",
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
