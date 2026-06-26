import ArticleOutlinedIcon from "@mui/icons-material/ArticleOutlined";
import AutoFixHighOutlinedIcon from "@mui/icons-material/AutoFixHighOutlined";
import LinkOutlinedIcon from "@mui/icons-material/LinkOutlined";
import {
  Alert,
  Box,
  Button,
  Chip,
  Divider,
  Grid,
  LinearProgress,
  Paper,
  Snackbar,
  Stack,
  TextField,
  Typography
} from "@mui/material";
import { useMemo, useState } from "react";
import { chatWithLocalLlm } from "../api/localLlm";
import { useImportPostMutation } from "../api/postWeaver";
import { useSettingsQuery } from "../api/settings";
import { LlmApiKeyDialog } from "../components/llm/LlmApiKeyDialog";
import { useLlmApiKey } from "../hooks/useLlmApiKey";
import type { ThreadsChainResponse, WovenPost } from "../types/postWeaver";
import { buildPostObsidianDraft, openObsidianDraft } from "../utils/obsidian";
import { PageScaffold, WorkspacePanel } from "./PageScaffold";

const steps = ["capturing", "polishing", "titled", "done"];

type CaptureStep = "idle" | "capture" | "polish" | "title" | "obsidian" | "complete" | "error";

export function CapturePostPage() {
  const [postUrl, setPostUrl] = useState("");
  const [posts, setPosts] = useState<WovenPost[]>([]);
  const [capturedUrl, setCapturedUrl] = useState("");
  const [capturedTitle, setCapturedTitle] = useState("");
  const [polishedContent, setPolishedContent] = useState("");
  const [step, setStep] = useState<CaptureStep>("idle");
  const [toast, setToast] = useState("");
  const [error, setError] = useState("");

  const settingsQuery = useSettingsQuery();
  const importPost = useImportPostMutation();
  const llmApiKey = useLlmApiKey();
  const isWorking = importPost.isPending || ["capture", "polish", "title", "obsidian"].includes(step);
  const draft = useMemo(
    () => buildPostObsidianDraft({ posts, capturedUrl, capturedTitle, polishedContent }),
    [posts, capturedUrl, capturedTitle, polishedContent]
  );

  async function capturePost() {
    const url = postUrl.trim();
    if (!url) {
      setToast("Paste a public post URL first");
      return;
    }

    setError("");
    setPosts([]);
    setPolishedContent("");
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

  function saveToObsidian() {
    if (!draft) {
      setToast("Capture a post before saving");
      return;
    }
    openObsidianDraft(draft);
    setToast("Opening Obsidian to create the note");
  }

  return (
    <PageScaffold title="Capture Post" eyebrow="Post workflow">
      <WorkspacePanel>
        <Stack spacing={2}>
          <WorkflowSteps step={step} />
          <Divider />
          <Stack direction={{ xs: "column", md: "row" }} spacing={1.5}>
            <TextField
              fullWidth
              size="small"
              value={postUrl}
              onChange={(event) => setPostUrl(event.target.value)}
              placeholder="Paste post URL, Threads, ..."
              InputProps={{
                startAdornment: <LinkOutlinedIcon color="disabled" fontSize="small" sx={{ mr: 1 }} />
              }}
            />
            <Button variant="contained" disabled={isWorking} onClick={capturePost}>
              Capture
            </Button>
          </Stack>
          {isWorking ? <LinearProgress /> : null}
          {error ? <Alert severity="error">{error}</Alert> : null}
        </Stack>
      </WorkspacePanel>

      <Grid container spacing={2}>
        <Grid size={{ xs: 12, lg: 6 }}>
          <WorkspacePanel>
            <Stack spacing={1.5} sx={{ minHeight: 360 }}>
              <Stack direction="row" justifyContent="space-between" alignItems="center">
                <Typography variant="h3">Original Post</Typography>
                <Chip size="small" label={`${posts.length} posts`} variant="outlined" />
              </Stack>
              <Divider />
              <PostList posts={posts} />
            </Stack>
          </WorkspacePanel>
        </Grid>
        <Grid size={{ xs: 12, lg: 6 }}>
          <WorkspacePanel>
            <Stack spacing={1.5} sx={{ minHeight: 360 }}>
              <Stack direction="row" spacing={1} alignItems="center">
                <AutoFixHighOutlinedIcon color="primary" fontSize="small" />
                <Typography variant="h3">AI Polished Preview</Typography>
              </Stack>
              <Divider />
              <Typography sx={{ whiteSpace: "pre-wrap", lineHeight: 1.75 }} color={polishedContent ? "text.primary" : "text.secondary"}>
                {polishedContent || "Polished content will appear here."}
              </Typography>
            </Stack>
          </WorkspacePanel>
        </Grid>
      </Grid>

      <WorkspacePanel>
        <Stack spacing={1.5}>
          <Stack direction="row" justifyContent="space-between" alignItems="center">
            <Typography variant="h3">Obsidian Preview</Typography>
            <Button variant="contained" disabled={!draft} onClick={saveToObsidian}>
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
  const activeIndex = stepToIndex(step);
  return (
    <Stack direction="row" spacing={1} sx={{ overflowX: "auto", pb: 0.5 }}>
      {steps.map((label, index) => (
        <Stack key={label} direction="row" alignItems="center" spacing={1} sx={{ minWidth: 150, flex: 1 }}>
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
            {label}
          </Typography>
        </Stack>
      ))}
    </Stack>
  );
}

function PostList({ posts }: { posts: WovenPost[] }) {
  if (!posts.length) {
    return (
      <Stack alignItems="center" justifyContent="center" spacing={1} sx={{ minHeight: 260, color: "text.secondary" }}>
        <ArticleOutlinedIcon />
        <Typography>No post captured yet.</Typography>
      </Stack>
    );
  }

  return (
    <Stack spacing={1} sx={{ maxHeight: 460, overflow: "auto", pr: 0.5 }}>
      {posts.map((post, index) => (
        <Paper key={`${post.url || "post"}-${index}`} variant="outlined" sx={{ p: 1.5 }}>
          <Typography variant="body2" color="text.secondary" fontWeight={800} gutterBottom>
            Post {index + 1}
            {post.url ? ` · ${postHost(post.url)}` : ""}
          </Typography>
          <Typography sx={{ whiteSpace: "pre-wrap", lineHeight: 1.7 }}>{post.text}</Typography>
        </Paper>
      ))}
    </Stack>
  );
}

function PostObsidianPreview({ draft }: { draft: ReturnType<typeof buildPostObsidianDraft> }) {
  if (!draft) {
    return (
      <Stack alignItems="center" justifyContent="center" sx={{ minHeight: 260, color: "text.secondary" }}>
        <Typography>Capture a public post to preview the note.</Typography>
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
          {draft.polishedContent || "AI publishing was unavailable for this capture."}
        </PreviewSection>
        <PreviewSection title="Original Content">{draft.content}</PreviewSection>
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
  if (step === "complete") return 3;
  if (step === "obsidian") return 3;
  if (step === "title") return 2;
  if (step === "polish") return 1;
  return 0;
}

function postHost(url: string) {
  try {
    return new URL(url).hostname || "source";
  } catch {
    return "source";
  }
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

function sanitizeObsidianTitle(text = "") {
  return String(text)
    .replace(/[\\/:*?"<>|;；：\u0000-\u001F]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}
