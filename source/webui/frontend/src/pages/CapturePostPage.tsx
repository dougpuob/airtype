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
import { useEffect, useMemo, useState } from "react";
import { chatWithLocalLlm } from "../api/localLlm";
import { useImportPostMutation } from "../api/postWeaver";
import { useSettingsQuery } from "../api/settings";
import { LlmApiKeyDialog } from "../components/llm/LlmApiKeyDialog";
import { ObsidianNotePreview } from "../components/obsidian/ObsidianNotePreview";
import { compactStepperSx } from "../components/workflow/stepperStyles";
import { useLlmApiKey } from "../hooks/useLlmApiKey";
import { useGuardedWork } from "../hooks/useWorkGuard";
import type { ThreadsChainResponse, WovenPost } from "../types/postWeaver";
import { buildPostObsidianDraft, openObsidianDraft } from "../utils/obsidian";
import { PageScaffold, WorkspacePanel } from "./PageScaffold";

const steps = ["Capture", "Polish", "Title", "Tags", "Ready"];
const CAPTURE_POST_STATE_KEY = "airtype:capture-post:state";

type CaptureStep = "idle" | "capture" | "polish" | "title" | "tags" | "obsidian" | "complete" | "error";

type PersistedCapturePostState = {
  postUrl: string;
  posts: WovenPost[];
  capturedUrl: string;
  capturedTitle: string;
  polishedContent: string;
  aiTags: string;
  step: CaptureStep;
  error: string;
};

export function CapturePostPage() {
  const restoredState = useMemo(readPersistedCapturePostState, []);
  const [postUrl, setPostUrl] = useState(restoredState.postUrl);
  const [posts, setPosts] = useState<WovenPost[]>(restoredState.posts);
  const [capturedUrl, setCapturedUrl] = useState(restoredState.capturedUrl);
  const [capturedTitle, setCapturedTitle] = useState(restoredState.capturedTitle);
  const [polishedContent, setPolishedContent] = useState(restoredState.polishedContent);
  const [aiTags, setAiTags] = useState(restoredState.aiTags);
  const [step, setStep] = useState<CaptureStep>(restoredState.step);
  const [toast, setToast] = useState("");
  const [error, setError] = useState(restoredState.error);

  const settingsQuery = useSettingsQuery();
  const importPost = useImportPostMutation();
  const llmApiKey = useLlmApiKey();
  const isWorking = importPost.isPending || ["capture", "polish", "title", "tags", "obsidian"].includes(step);
  const activeProgress = captureProgress(step);
  const activeMessage = captureProgressMessage(step);
  const draft = useMemo(
    () => buildPostObsidianDraft({ posts, capturedUrl, capturedTitle, polishedContent, aiTags }),
    [posts, capturedUrl, capturedTitle, polishedContent, aiTags]
  );

  useGuardedWork({
    id: "capture-post",
    label: "Capture Post",
    isActive: isWorking,
    onConfirmLeave: () => {
      setStep("idle");
      writePersistedCapturePostState({
        postUrl,
        posts,
        capturedUrl,
        capturedTitle,
        polishedContent,
        aiTags,
        step: "idle",
        error
      });
    }
  });

  useEffect(() => {
    writePersistedCapturePostState({ postUrl, posts, capturedUrl, capturedTitle, polishedContent, aiTags, step, error });
  }, [postUrl, posts, capturedUrl, capturedTitle, polishedContent, aiTags, step, error]);

  useEffect(() => {
    if (!isWorking) return;
    function handlePageHide() {
      writePersistedCapturePostState({
        postUrl,
        posts,
        capturedUrl,
        capturedTitle,
        polishedContent,
        aiTags,
        step: "idle",
        error
      });
    }

    window.addEventListener("pagehide", handlePageHide);
    return () => window.removeEventListener("pagehide", handlePageHide);
  }, [aiTags, capturedTitle, capturedUrl, error, isWorking, polishedContent, postUrl, posts]);

  async function capturePost() {
    const url = postUrl.trim();
    if (!url) {
      setToast("Paste a public post URL first");
      return;
    }

    setError("");
    setPosts([]);
    setPolishedContent("");
    setAiTags("");
    setCapturedTitle("");
    setCapturedUrl(url);
    setStep("capture");

    try {
      const { payload, isThreads } = await importPost.mutateAsync(url);
      const nextPosts = normalizeImportedPosts(payload, url, isThreads);
      if (!nextPosts.length) throw new Error("No public post text was found");
      const initialTitle = titleFromPostText(nextPosts[0]?.text || "");
      setPosts(nextPosts);
      setCapturedTitle(initialTitle);
      setToast(`Captured ${nextPosts.length} post${nextPosts.length === 1 ? "" : "s"}`);

      setStep("polish");
      const source = uniquePostBlocks(nextPosts.map((post) => post.text.trim()).filter(Boolean).join("\n\n"));
      const polished = await polishPosts(source);
      setPolishedContent(polished);

      setStep("title");
      const title = await generateTitle(polished || source);
      setCapturedTitle(title || initialTitle);

      setStep("tags");
      const generatedTags = await generateAiTags(polished || source, title || initialTitle);
      setAiTags(generatedTags);

      setStep("complete");
      setToast("Post ready for Obsidian");
    } catch (caught) {
      setStep("error");
      const message = caught instanceof Error ? caught.message : "Could not capture this post";
      setError(message);
      setToast(message);
    }
  }

  async function polishPosts(source: string) {
    if (!source) return "";
    try {
      const apiKey = await llmApiKey.ensureApiKey(settingsQuery.data || {});
      const response = await chatWithLocalLlm(
        settingsQuery.data || {},
        `請將以下社群貼文整理成一篇通順、簡潔、語氣中性的繁體中文文章。\n\n要求：\n1. 移除重複段落、重複敘述、社群介面文字與 hashtag 雜訊；同一事實只保留一次。\n2. 只做必要的語句銜接與錯字修正，不要改寫成花俏、幽默或煽動性的文風。\n3. 保留原本段落與事實順序；不新增標題、標籤、摘要或任何說明。\n4. 只輸出完成後的文章正文。\n\n原始貼文：\n${source}`,
        "你是嚴謹、克制的繁體中文編輯。忠實保留原文的觀點、時間線與事實，不得加入新資訊、評論、推測、俏皮語氣、誇張修辭或宣傳式文字。",
        apiKey
      );
      setToast("AI polished preview updated");
      return response || source;
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : "AI polishing failed";
      setToast(message);
      return "";
    }
  }

  async function generateTitle(content: string) {
    const fallback = fallbackArticleTitle(content);
    if (!content.trim()) return fallback;
    try {
      const apiKey = await llmApiKey.ensureApiKey(settingsQuery.data || {});
      const response = await chatWithLocalLlm(
        settingsQuery.data || {},
        `找出重點給我30個字左右的標題，不該有冒號，不要給選擇直接回應。\n\n${content}`,
        "",
        apiKey
      );
      const title = normalizeGeneratedTitle(response);
      if (title) {
        setToast("AI title generated");
        return title;
      }
      return fallback;
    } catch {
      setToast("AI title unavailable; using fallback title");
      return fallback;
    }
  }

  async function generateAiTags(content: string, title: string) {
    const source = content.trim();
    if (!source) return "";
    try {
      const apiKey = await llmApiKey.ensureApiKey(settingsQuery.data || {});
      const response = await chatWithLocalLlm(
        settingsQuery.data || {},
        `請根據以下文章產生 5 到 8 組 Obsidian hashtag。\n\n要求：\n1. 每一組包含一個繁體中文 hashtag 與一個對應英文 hashtag。\n2. 英文若有常見縮寫，請優先使用縮寫，例如 AI、LLM、API、GPU、CPU、SaaS。\n3. hashtag 不要有空格、標點或解釋文字。\n4. 每行只輸出一組，格式固定為：#中文標籤 #EnglishTag\n5. 不要輸出編號、前言、結語、Markdown code block。\n\n標題：${title || "未命名"}\n\n文章：\n${source}`,
        "你是擅長資訊整理的繁體中文知識管理助手。只輸出可直接貼進 Obsidian 的 hashtag 清單。",
        apiKey
      );
      const tags = normalizeAiTags(response);
      if (tags) setToast("AI tags generated");
      return tags;
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : "AI tags unavailable";
      setToast(message);
      return "";
    }
  }

  function saveToObsidian() {
    if (!draft) {
      setToast("Capture a post before saving");
      return;
    }
    openObsidianDraft(draft, settingsQuery.data?.obsidian?.default_folder);
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
              gridTemplateColumns: { xs: "1fr", md: "minmax(0, 1fr) minmax(0, 1fr)" },
              minWidth: 0
            }}
          >
            <Box sx={{ alignContent: "center", minWidth: 0, overflowX: "auto", pb: 0.5 }}>
              <WorkflowSteps step={step} />
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
                    {activeProgress}%
                  </Typography>
                </Stack>
                <LinearProgress value={activeProgress} variant="determinate" />
              </Stack>
              <Button
                variant="contained"
                disabled={isWorking}
                onClick={capturePost}
                sx={{ gridRow: { sm: "1 / span 2" }, height: 40, whiteSpace: "nowrap", flexShrink: 0 }}
              >
                Capture
              </Button>
              <TextField
                fullWidth
                size="small"
                sx={{ "& .MuiOutlinedInput-root": { height: 40 } }}
                value={postUrl}
                onChange={(event) => setPostUrl(event.target.value)}
                placeholder="Paste post URL, Threads, ..."
                InputProps={{
                  startAdornment: <LinkOutlinedIcon color="disabled" fontSize="small" sx={{ mr: 1 }} />
                }}
              />
            </Box>
          </Box>
          <Divider />
          {error ? <Alert severity="error">{error}</Alert> : null}
        </Stack>
      </WorkspacePanel>

      <WorkspacePanel>
        <Stack spacing={1.5}>
          <Stack direction={{ xs: "column", sm: "row" }} justifyContent="space-between" alignItems={{ xs: "stretch", sm: "center" }} spacing={1}>
            <Typography variant="h3">Obsidian Preview</Typography>
            <Button variant="contained" disabled={!draft} onClick={saveToObsidian} sx={{ whiteSpace: "nowrap" }}>
              Save to Obsidian
            </Button>
          </Stack>
          <Divider />
          <PostObsidianPreview draft={draft} />
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

function WorkflowSteps({ step }: { step: CaptureStep }) {
  return (
    <Stepper activeStep={stepToIndex(step)} alternativeLabel sx={compactStepperSx}>
      {steps.map((label, index) => (
        <Step key={label} completed={isStepCompleted(index, step)}>
          <StepLabel>{label}</StepLabel>
        </Step>
      ))}
    </Stepper>
  );
}

function PostObsidianPreview({ draft }: { draft: ReturnType<typeof buildPostObsidianDraft> }) {
  return (
    <ObsidianNotePreview
      draft={draft}
      emptyMessage="Capture a public post to preview the note."
      polishedFallback="AI publishing was unavailable for this capture."
      originalTitle="Original Content"
    />
  );
}

function normalizeImportedPosts(payload: unknown, url: string, isThreads: boolean): WovenPost[] {
  if (isThreads) {
    const thread = payload as ThreadsChainResponse;
    return (thread.posts || [])
      .filter((post) => post?.text)
      .map((post) => ({
        text: post.text || "",
        url: post.url || url,
        mediaUrls: Array.isArray(post.media_urls) ? post.media_urls : []
      }));
  }

  const post = payload as { text?: string; url?: string; media_urls?: string[] };
  const text = String(post.text || "").trim();
  if (!text) return [];
  return [{ text, url: post.url || url, mediaUrls: Array.isArray(post.media_urls) ? post.media_urls : [] }];
}

function stepToIndex(step: CaptureStep) {
  if (step === "complete") return 4;
  if (step === "obsidian") return 4;
  if (step === "tags") return 3;
  if (step === "title") return 2;
  if (step === "polish") return 1;
  return 0;
}

function isStepCompleted(index: number, step: CaptureStep) {
  if (step === "complete") return true;
  return index < stepToIndex(step);
}

function captureProgress(step: CaptureStep) {
  if (step === "complete") return 100;
  if (step === "obsidian") return 95;
  if (step === "tags") return 86;
  if (step === "title") return 72;
  if (step === "polish") return 50;
  if (step === "capture") return 22;
  return 0;
}

function captureProgressMessage(step: CaptureStep) {
  if (step === "complete") return "Post ready";
  if (step === "error") return "Capture failed";
  if (step === "obsidian") return "Opening Obsidian";
  if (step === "tags") return "Generating tags";
  if (step === "title") return "Generating title";
  if (step === "polish") return "Polishing captured text";
  if (step === "capture") return "Capturing post";
  return "Ready";
}

function uniquePostBlocks(text = "") {
  const seen = new Set<string>();
  return String(text)
    .split(/\n\s*\n/)
    .map((block) => block.trim())
    .filter((block) => {
      if (!block) return false;
      const key = block.replace(/[\s\u200B-\u200D\uFEFF]+/g, " ").trim();
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .join("\n\n");
}

function titleFromPostText(text = "") {
  return (
    String(text)
      .split(/\n\s*\n/)
      .map((block) => block.trim())
      .find(Boolean) || ""
  ).replace(/\s+/g, " ");
}

function fallbackArticleTitle(text = "") {
  const characters = Array.from(String(text).replace(/\s+/g, " ").trim());
  if (!characters.length) return "TITLE";
  return sanitizeObsidianTitle(characters.slice(0, 30).join("")) || "TITLE";
}

function normalizeGeneratedTitle(text = "") {
  const firstLine = String(text)
    .split(/\r?\n/)
    .find((line) => line.trim()) || "";
  const normalized = firstLine
    .replace(/^\s*(?:標題|title)\s*[:：]\s*/i, "")
    .replace(/^#+\s*/, "")
    .replace(/[「」『』"“”]/g, "")
    .trim();
  return sanitizeObsidianTitle(Array.from(normalized).slice(0, 30).join(""));
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

function sanitizeObsidianTitle(text = "") {
  return String(text)
    .replace(/[\\/:*?"<>|;；：\u0000-\u001F]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function readPersistedCapturePostState(): PersistedCapturePostState {
  const fallback: PersistedCapturePostState = {
    postUrl: "",
    posts: [],
    capturedUrl: "",
    capturedTitle: "",
    polishedContent: "",
    aiTags: "",
    step: "idle",
    error: ""
  };
  if (typeof window === "undefined") return fallback;
  try {
    const value = window.sessionStorage.getItem(CAPTURE_POST_STATE_KEY) || window.localStorage.getItem(CAPTURE_POST_STATE_KEY);
    if (!value) return fallback;
    const parsed = JSON.parse(value) as Partial<PersistedCapturePostState>;
    const step = isPersistableCaptureStep(parsed.step) ? parsed.step : "idle";
    return {
      postUrl: typeof parsed.postUrl === "string" ? parsed.postUrl : "",
      posts: Array.isArray(parsed.posts) ? parsed.posts.filter(isPersistedPost) : [],
      capturedUrl: typeof parsed.capturedUrl === "string" ? parsed.capturedUrl : "",
      capturedTitle: typeof parsed.capturedTitle === "string" ? parsed.capturedTitle : "",
      polishedContent: typeof parsed.polishedContent === "string" ? parsed.polishedContent : "",
      aiTags: typeof parsed.aiTags === "string" ? parsed.aiTags : "",
      step: ["capture", "polish", "title", "tags", "obsidian"].includes(step) ? "idle" : step,
      error: typeof parsed.error === "string" ? parsed.error : ""
    };
  } catch {
    return fallback;
  }
}

function writePersistedCapturePostState(state: PersistedCapturePostState) {
  if (typeof window === "undefined") return;
  try {
    const value = JSON.stringify(state);
    window.sessionStorage.setItem(CAPTURE_POST_STATE_KEY, value);
    window.localStorage.setItem(CAPTURE_POST_STATE_KEY, value);
  } catch {
    // If storage is unavailable, the current in-memory page state still works.
  }
}

function isPersistableCaptureStep(value: unknown): value is CaptureStep {
  return ["idle", "capture", "polish", "title", "tags", "obsidian", "complete", "error"].includes(String(value));
}

function isPersistedPost(value: unknown): value is WovenPost {
  if (!value || typeof value !== "object") return false;
  const post = value as Partial<WovenPost>;
  return typeof post.text === "string" && typeof post.url === "string" && Array.isArray(post.mediaUrls);
}
