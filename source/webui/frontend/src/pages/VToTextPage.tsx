import LinkOutlinedIcon from "@mui/icons-material/LinkOutlined";
import {
  Alert,
  Box,
  Button,
  Chip,
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
import { useQueryClient } from "@tanstack/react-query";
import { useEffect, useMemo, useRef, useState } from "react";
import { chatWithLocalLlm } from "../api/localLlm";
import { uploadNoteMedia } from "../api/immich";
import type { NoteMediaImage } from "../api/immich";
import { chainWarningsFromPayload, useImportPostMutation } from "../api/postWeaver";
import { useSettingsQuery } from "../api/settings";
import { fetchClipId, fetchWebArticleJob, startWebArticleJob } from "../api/webArticle";
import type { WebArticleImage, WebArticleJob } from "../api/webArticle";
import {
  useCancelTranscriptionJobMutation,
  useCreateUrlTranscriptionJobMutation,
  useTranscriptionJobQuery,
  useTranscriptionRecordQuery,
  useUploadTranscriptionJobMutation
} from "../api/transcription";
import { LlmApiKeyDialog } from "../components/llm/LlmApiKeyDialog";
import { ObsidianNotePreview } from "../components/obsidian/ObsidianNotePreview";
import { compactStepperSx } from "../components/workflow/stepperStyles";
import { useLlmApiKey } from "../hooks/useLlmApiKey";
import { useGuardedWork } from "../hooks/useWorkGuard";
import type { ThreadsChainResponse, WovenPost } from "../types/postWeaver";
import type { TranscriptionJob, TranscriptionRecord } from "../types/transcription";
import { AI_TAGS_SYSTEM_PROMPT, buildAiTagsPrompt, normalizeAiTags } from "../utils/aiTags";
import { DEFAULT_AI_TITLE_SYSTEM_PROMPT, fallbackAiTitle, normalizeAiTitle } from "../utils/aiTitle";
import {
  buildPostObsidianDraft,
  buildTranscriptObsidianDraft,
  openObsidianDraft,
  postsToMarkdown
} from "../utils/obsidian";
import { PageScaffold, WorkspacePanel } from "./PageScaffold";

const OBSIDIAN_CLIPPER_STATE_KEY = "airtype:obsidian-clipper:state";
const ARTICLE_POLL_INTERVAL_MS = 1500;
// Threads/media providers attach og:video to posts; those files are not
// uploaded to Immich (the pipeline only stores images) and keep their links.
const NON_IMAGE_MEDIA_EXTENSIONS = /\.(?:aac|aif|aiff|avi|flac|m4a|m4v|mkv|mov|mp3|mp4|mpeg|mpg|ogg|opus|wav|webm)(?:$|[?#])/i;

type ClipperRoute = "auto" | "post" | "voice" | "article";
type PostStep = "idle" | "capture" | "photos" | "polish" | "title" | "tags" | "complete" | "error";
type CaptureKind = "post" | "article";

type PersistedObsidianClipperState = {
  activeRoute: ClipperRoute;
  activeJobId: string | null;
  selectedRecordId: string | null;
  sourceUrl: string;
  aiTitle: string;
  aiTitleSourceKey: string;
  aiTags: string;
  aiTagsSourceKey: string;
  postUrl: string;
  posts: WovenPost[];
  capturedUrl: string;
  capturedTitle: string;
  polishedContent: string;
  postAiTags: string;
  postStep: PostStep;
  postError: string;
  chainWarnings: string[];
  guid: string;
  captureKind: CaptureKind;
  shareUrl: string;
  mediaMap: Record<string, string>;
  mediaImages: NoteMediaImage[];
  articleJobId: string | null;
  articleImages: WebArticleImage[];
};

export function VToTextPage() {
  const queryClient = useQueryClient();
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const sourceUrlInputRef = useRef<HTMLInputElement | null>(null);
  const restoredState = useMemo(readPersistedObsidianClipperState, []);
  const [activeRoute, setActiveRoute] = useState<ClipperRoute>(restoredState.activeRoute);
  const [sourceUrl, setSourceUrl] = useState(restoredState.sourceUrl || restoredState.postUrl);
  const [selectedRecordId, setSelectedRecordId] = useState<string | null>(restoredState.selectedRecordId);
  const [activeJobId, setActiveJobId] = useState<string | null>(restoredState.activeJobId);
  const [uploadProgress, setUploadProgress] = useState<number | null>(null);
  const [aiTitle, setAiTitle] = useState(restoredState.aiTitle);
  const [aiTitleSourceKey, setAiTitleSourceKey] = useState(restoredState.aiTitleSourceKey);
  const [isGeneratingAiTitle, setIsGeneratingAiTitle] = useState(false);
  const [aiTags, setAiTags] = useState(restoredState.aiTags);
  const [aiTagsSourceKey, setAiTagsSourceKey] = useState(restoredState.aiTagsSourceKey);
  const [isGeneratingAiTags, setIsGeneratingAiTags] = useState(false);
  const [posts, setPosts] = useState<WovenPost[]>(restoredState.posts);
  const [capturedUrl, setCapturedUrl] = useState(restoredState.capturedUrl);
  const [capturedTitle, setCapturedTitle] = useState(restoredState.capturedTitle);
  const [polishedContent, setPolishedContent] = useState(restoredState.polishedContent);
  const [postAiTags, setPostAiTags] = useState(restoredState.postAiTags);
  const [postStep, setPostStep] = useState<PostStep>(restoredState.postStep);
  const [postError, setPostError] = useState(restoredState.postError);
  const [chainWarnings, setChainWarnings] = useState<string[]>(restoredState.chainWarnings);
  const [guid, setGuid] = useState(restoredState.guid);
  const [captureKind, setCaptureKind] = useState<CaptureKind>(restoredState.captureKind);
  const [shareUrl, setShareUrl] = useState(restoredState.shareUrl);
  const [mediaMap, setMediaMap] = useState<Record<string, string>>(restoredState.mediaMap);
  const [mediaImages, setMediaImages] = useState<NoteMediaImage[]>(restoredState.mediaImages);
  const [articleJobId, setArticleJobId] = useState<string | null>(restoredState.articleJobId);
  const [articleJob, setArticleJob] = useState<WebArticleJob | null>(null);
  const [articleImages, setArticleImages] = useState<WebArticleImage[]>(restoredState.articleImages);
  const [toast, setToast] = useState("");
  const captureSeqRef = useRef(0);
  const postStepRef = useRef(restoredState.postStep);
  const ingestedArticleJobsRef = useRef<Set<string>>(new Set());

  const settingsQuery = useSettingsQuery();
  const jobQuery = useTranscriptionJobQuery(activeJobId, Boolean(activeJobId));
  const recordLookupId = selectedRecordId || activeJobId;
  const recordQuery = useTranscriptionRecordQuery(recordLookupId, Boolean(activeJobId));
  const createUrlJob = useCreateUrlTranscriptionJobMutation();
  const uploadJob = useUploadTranscriptionJobMutation();
  const cancelJob = useCancelTranscriptionJobMutation();
  const importPost = useImportPostMutation();
  const llmApiKey = useLlmApiKey();

  const whisper = settingsQuery.data?.whisper || {};
  const aiTitleEnabled = settingsQuery.data?.capture_post?.ai_title_enabled ?? true;
  const aiTitleSystemPrompt =
    settingsQuery.data?.capture_post?.title_system_prompt ?? DEFAULT_AI_TITLE_SYSTEM_PROMPT;
  const activeJob = jobQuery.data;
  const selectedRecord = recordQuery.data;
  const detectedRoute = routeForUrl(sourceUrl);
  const visibleRoute = activeRoute === "auto" ? detectedRoute : activeRoute;
  const voiceJobWorking =
    Boolean(activeJobId && !isTerminalStatus(selectedRecord?.status)) || createUrlJob.isPending || uploadJob.isPending;
  const voiceIsWorking = voiceJobWorking || isGeneratingAiTitle || isGeneratingAiTags;
  const postIsWorking = importPost.isPending || ["capture", "photos", "polish", "title", "tags"].includes(postStep);
  const isWorking = voiceIsWorking || postIsWorking;

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
  const storedAiTags = selectedRecord?.status === "completed" ? String(selectedRecord.ai_tags || "").trim() : "";
  const visibleAiTags = aiTags || storedAiTags;
  const transcriptDraft = useMemo(
    () => buildTranscriptObsidianDraft(selectedRecord, visibleAiTags, effectiveAiTitle, guid),
    [effectiveAiTitle, guid, selectedRecord, visibleAiTags]
  );
  const postDraft = useMemo(
    () =>
      buildPostObsidianDraft({
        kind: captureKind === "article" ? "article" : "post",
        posts,
        capturedUrl,
        capturedTitle,
        polishedContent,
        aiTags: postAiTags,
        guid,
        shareUrl,
        mediaMap
      }),
    [captureKind, capturedTitle, capturedUrl, guid, mediaMap, polishedContent, postAiTags, posts, shareUrl]
  );
  const activeDraft = visibleRoute === "voice" ? transcriptDraft : postDraft;
  const originalTitle =
    activeDraft?.originalHeading || (visibleRoute === "voice" ? "Original Transcript" : "Original Content");
  const emptyMessage = visibleRoute === "voice"
    ? "Complete a transcript to preview the note."
    : visibleRoute === "article"
      ? "Capture a web article to preview the note."
      : "Capture a public post to preview the note.";
  const polishedFallback = visibleRoute === "voice"
    ? "AI article is not available for this transcript."
    : "AI publishing was unavailable for this capture.";

  const workflowStepIndex = visibleRoute === "voice"
    ? voiceWorkflowStepIndex({
        status: activeJob?.status || selectedRecord?.status,
        hasRecord: Boolean(selectedRecord),
        hasTitleSource: Boolean(aiTitleSource.key),
        titleDone: aiTitleDone,
        hasTagSource: Boolean(storedAiTags || aiTagsSource.key),
        tagsDone:
          Boolean(storedAiTags) ||
          !aiTagsRequestKey ||
          (aiTagsSourceKey === aiTagsRequestKey && !isGeneratingAiTags),
        isSubmitting: uploadProgress !== null || createUrlJob.isPending || uploadJob.isPending,
        isGeneratingAiTitle,
        isGeneratingAiTags
      })
    : postStepToIndex(postStep, visibleRoute === "article");
  const activeProgress = visibleRoute === "voice"
    ? voiceProgress({
        activeJob,
        selectedRecord,
        uploadProgress,
        isGeneratingAiTitle,
        isGeneratingAiTags
      })
    : visibleRoute === "article" && postStep === "capture" && articleJob
      ? Math.max(2, articleJob.progress)
      : postProgress(postStep, visibleRoute === "article");
  const activeMessage = visibleRoute === "voice"
    ? voiceProgressMessage({
        activeJob,
        selectedRecord,
        uploadProgress,
        isGeneratingAiTitle,
        isGeneratingAiTags
      })
    : visibleRoute === "article" && postStep === "capture" && articleJob?.message
      ? articleJob.message
      : postProgressMessage(postStep, visibleRoute === "article");

  useEffect(() => {
    postStepRef.current = postStep;
  }, [postStep]);

  useGuardedWork({
    id: "obsidian-clipper",
    label: "Obsidian Clipper",
    isActive: isWorking,
    onConfirmLeave: async () => {
      if (activeJobId) {
        await cancelJob.mutateAsync(activeJobId);
        setActiveJobId(null);
        setUploadProgress(null);
      }
      if (postIsWorking) {
        setPostStep("idle");
        setArticleJobId(null);
        setArticleJob(null);
      }
    }
  });

  useEffect(() => {
    writePersistedObsidianClipperState({
      activeRoute,
      activeJobId,
      selectedRecordId,
      sourceUrl,
      aiTitle,
      aiTitleSourceKey,
      aiTags,
      aiTagsSourceKey,
      postUrl: sourceUrl,
      posts,
      capturedUrl,
      capturedTitle,
      polishedContent,
      postAiTags,
      postStep,
      postError,
      chainWarnings,
      guid,
      captureKind,
      shareUrl,
      mediaMap,
      mediaImages,
      articleJobId,
      articleImages
    });
  }, [
    activeRoute,
    activeJobId,
    selectedRecordId,
    sourceUrl,
    aiTitle,
    aiTitleSourceKey,
    aiTags,
    aiTagsSourceKey,
    posts,
    capturedUrl,
    capturedTitle,
    polishedContent,
    postAiTags,
    postStep,
    postError,
    chainWarnings,
    guid,
    captureKind,
    shareUrl,
    mediaMap,
    mediaImages,
    articleJobId,
    articleImages
  ]);

  useEffect(() => {
    if (!isWorking) return;
    function handlePageHide() {
      if (activeJobId) {
        navigator.sendBeacon?.(`/api/transcribe/jobs/${activeJobId}/cancel`, new Blob());
      }
      writePersistedObsidianClipperState({
        activeRoute,
        activeJobId: null,
        selectedRecordId,
        sourceUrl,
        aiTitle,
        aiTitleSourceKey,
        aiTags,
        aiTagsSourceKey,
        postUrl: sourceUrl,
        posts,
        capturedUrl,
        capturedTitle,
        polishedContent,
        postAiTags,
        postStep: postIsWorking ? "idle" : postStep,
        postError,
        chainWarnings,
        guid,
        captureKind,
        shareUrl,
        mediaMap,
        mediaImages,
        articleJobId,
        articleImages
      });
    }

    window.addEventListener("pagehide", handlePageHide);
    return () => window.removeEventListener("pagehide", handlePageHide);
  }, [
    activeJobId,
    activeRoute,
    aiTags,
    aiTagsSourceKey,
    aiTitle,
    aiTitleSourceKey,
    capturedTitle,
    capturedUrl,
    chainWarnings,
    isWorking,
    polishedContent,
    postAiTags,
    postError,
    postIsWorking,
    postStep,
    posts,
    selectedRecordId,
    sourceUrl,
    guid,
    captureKind,
    shareUrl,
    mediaMap,
    mediaImages,
    articleJobId,
    articleImages
  ]);

  function pasteClipboardUrl() {
    const input = sourceUrlInputRef.current;
    if (input) { input.focus(); input.select(); }
    setToast("Press ⌘V / Ctrl+V to paste the URL");
  }

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

  // Web-article job polling: the backend fetches the page as Markdown,
  // stores the article images in Immich under the note GUID, and rewrites
  // the links before the job completes.
  useEffect(() => {
    if (!articleJobId) return;
    let cancelled = false;
    async function pollArticleJob() {
      try {
        const updated = await fetchWebArticleJob(articleJobId as string);
        if (cancelled) return;
        setArticleJob(updated);
      } catch (caught) {
        if (cancelled) return;
        const message = caught instanceof Error ? caught.message : "Could not refresh the article capture job";
        setArticleJobId(null);
        setArticleJob(null);
        if (postStepRef.current === "capture") {
          setPostStep("error");
          setPostError(message);
          setToast(message);
        }
      }
    }
    void pollArticleJob();
    const timer = window.setInterval(() => void pollArticleJob(), ARTICLE_POLL_INTERVAL_MS);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [articleJobId]);

  useEffect(() => {
    if (!articleJob) return;
    if (articleJob.status === "completed") {
      if (ingestedArticleJobsRef.current.has(articleJob.job_id)) return;
      ingestedArticleJobsRef.current.add(articleJob.job_id);
      setArticleJobId(null);
      ingestCompletedArticleJob(articleJob);
    }
    if (articleJob.status === "error") {
      setArticleJobId(null);
      setArticleJob(null);
      const message = articleJob.error || "The capture job failed.";
      setPostStep("error");
      setPostError(message);
      setToast(message);
    }
  }, [articleJob]);

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
    aiTitleSource.content,
    aiTitleSource.title,
    aiTitleSourceKey,
    aiTitleSystemPrompt,
    llmApiKey.ensureApiKey,
    settingsQuery.data
  ]);

  useEffect(() => {
    if (storedAiTags) {
      setAiTags(storedAiTags);
      setIsGeneratingAiTags(false);
      return;
    }
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
          AI_TAGS_SYSTEM_PROMPT,
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
  }, [
    aiTagsRequestKey,
    aiTagsSource.content,
    aiTagsSource.key,
    aiTagsSource.title,
    aiTagsSourceKey,
    aiTitleDone,
    llmApiKey.ensureApiKey,
    settingsQuery.data,
    storedAiTags
  ]);

  async function runClipperUrl() {
    const url = sourceUrl.trim();
    if (!url) {
      setToast("Paste a URL first");
      return;
    }

    const route = routeForUrl(url);
    setActiveRoute(route);
    if (route === "voice") {
      await startUrlJob(url);
      return;
    }
    if (route === "article") {
      await captureArticle(url);
      return;
    }
    await capturePost(url);
  }

  async function startUrlJob(url: string) {
    setSelectedRecordId(null);
    setUploadProgress(null);
    const captureGuid = (await fetchClipId(url)).guid;
    setGuid(captureGuid);
    const job = await createUrlJob.mutateAsync({
      url,
      language: whisper.language || null,
      whisperEndpoint: whisper.remote_endpoint || null
    });
    writePersistedObsidianClipperState({
      activeRoute: "voice",
      activeJobId: job.job_id,
      selectedRecordId: null,
      sourceUrl: url,
      aiTitle,
      aiTitleSourceKey,
      aiTags,
      aiTagsSourceKey,
      postUrl: sourceUrl,
      posts,
      capturedUrl,
      capturedTitle,
      polishedContent,
      postAiTags,
      postStep,
      postError,
      chainWarnings,
      guid: captureGuid,
      captureKind,
      shareUrl,
      mediaMap,
      mediaImages,
      articleJobId,
      articleImages
    });
    setActiveJobId(job.job_id);
    setToast("URL job started");
  }

  async function startFileJob(file: File) {
    setActiveRoute("voice");
    setSourceUrl("");
    setSelectedRecordId(null);
    setUploadProgress(null);
    const captureGuid = createNoteGuid();
    setGuid(captureGuid);
    const job = await uploadJob.mutateAsync({
      file,
      language: whisper.language || null,
      whisperEndpoint: whisper.remote_endpoint || null,
      onProgress: setUploadProgress
    });
    writePersistedObsidianClipperState({
      activeRoute: "voice",
      activeJobId: job.job_id,
      selectedRecordId: null,
      sourceUrl: "",
      aiTitle,
      aiTitleSourceKey,
      aiTags,
      aiTagsSourceKey,
      postUrl: "",
      posts,
      capturedUrl,
      capturedTitle,
      polishedContent,
      postAiTags,
      postStep,
      postError,
      chainWarnings,
      guid: captureGuid,
      captureKind,
      shareUrl,
      mediaMap,
      mediaImages,
      articleJobId,
      articleImages
    });
    setActiveJobId(job.job_id);
    setToast("Upload complete; transcription queued");
  }

  async function stopActiveJob() {
    if (!activeJobId) return;
    await cancelJob.mutateAsync(activeJobId);
    setToast("Stop requested");
  }

  async function capturePost(url: string) {
    const seq = beginCapture("post");
    setPostError("");
    setChainWarnings([]);
    resetCaptureResults();
    setCapturedUrl(url);
    setPostStep("capture");

    try {
      const { payload, isThreads } = await importPost.mutateAsync(url);
      if (captureSeqRef.current !== seq) return;
      const nextPosts = normalizeImportedPosts(payload, url, isThreads);
      if (!nextPosts.length) throw new Error("No public post text was found");
      const payloadGuid = clipGuidFromPayload(payload);
      const captureGuid = payloadGuid || (await fetchClipId(nextPosts[0]?.url || url)).guid;
      if (captureSeqRef.current !== seq) return;
      setGuid(captureGuid);
      const nextWarnings = chainWarningsFromPayload(payload, isThreads);
      const initialTitle = titleFromPostText(nextPosts[0]?.text || "");
      setPosts(nextPosts);
      setChainWarnings(nextWarnings);
      setCapturedTitle(initialTitle);
      setToast(`Captured ${nextPosts.length} post${nextPosts.length === 1 ? "" : "s"}`);

      setPostStep("photos");
      const photoResult = await storePostPhotos(nextPosts, url, initialTitle, captureGuid, seq);
      if (captureSeqRef.current !== seq) return;
      if (photoResult.warnings.length) {
        setChainWarnings((current) => [...current, ...photoResult.warnings]);
      }

      setPostStep("polish");
      const source = postsToMarkdown(nextPosts, photoResult.mediaMap);
      const polished = await polishPosts(source);
      if (captureSeqRef.current !== seq) return;
      setPolishedContent(polished);

      setPostStep("title");
      const title = settingsQuery.data?.capture_post?.ai_title_enabled === false
        ? initialTitle
        : await generatePostTitle(polished || source);
      if (captureSeqRef.current !== seq) return;
      setCapturedTitle(title || initialTitle);

      setPostStep("tags");
      const generatedTags = await generatePostAiTags(polished || source, title || initialTitle);
      if (captureSeqRef.current !== seq) return;
      setPostAiTags(generatedTags);

      setPostStep("complete");
      setToast("Post ready for Obsidian");
    } catch (caught) {
      if (captureSeqRef.current !== seq) return;
      setPostStep("error");
      const message = caught instanceof Error ? caught.message : "Could not capture this post";
      setPostError(message);
      setToast(message);
    }
  }

  // URL clips get a UUID v5 from the backend (same source → same GUID).
  function beginCapture(kind: CaptureKind) {
    captureSeqRef.current += 1;
    setCaptureKind(kind);
    setGuid("");
    return captureSeqRef.current;
  }

  function resetCaptureResults() {
    setPosts([]);
    setPolishedContent("");
    setPostAiTags("");
    setCapturedTitle("");
    setShareUrl("");
    setMediaMap({});
    setMediaImages([]);
    setArticleJobId(null);
    setArticleJob(null);
    setArticleImages([]);
  }

  // Web-article capture: the backend job fetches the page as Markdown and
  // stores its images in Immich before the AI chain rewrites title and tags.
  async function captureArticle(url: string) {
    const seq = beginCapture("article");
    setPostError("");
    setChainWarnings([]);
    resetCaptureResults();
    setCapturedUrl(url);
    setPostStep("capture");
    setToast("Article capture started");

    try {
      const job = await startWebArticleJob(url);
      if (captureSeqRef.current !== seq) return;
      if (job.guid) setGuid(job.guid);
      setArticleJobId(job.job_id);
      setArticleJob(job);
    } catch (caught) {
      if (captureSeqRef.current !== seq) return;
      const message = caught instanceof Error ? caught.message : "Could not start the article capture job";
      setPostStep("error");
      setPostError(message);
      setToast(message);
    }
  }

  function ingestCompletedArticleJob(job: WebArticleJob) {
    if (job.guid) setGuid(job.guid);
    setArticleJob(null);
    setArticleImages(Array.isArray(job.images) ? job.images : []);
    setShareUrl(job.share_url || "");
    setPosts(job.markdown.trim() ? [{ text: job.markdown, url: job.url, mediaUrls: [] }] : []);
    setCapturedUrl(job.url);
    setCapturedTitle(job.title || "");
    setChainWarnings(Array.isArray(job.warnings) ? job.warnings.filter(Boolean) : []);
    setToast("Article captured");
    void runArticleAiChain(job);
  }

  async function runArticleAiChain(job: WebArticleJob) {
    const seq = captureSeqRef.current;
    const markdown = String(job.markdown || "").trim();
    if (!markdown) {
      const message = "The captured article was empty";
      setPostStep("error");
      setPostError(message);
      setToast(message);
      return;
    }
    try {
      setPostStep("polish");
      const polished = await polishPosts(markdown);
      if (captureSeqRef.current !== seq) return;
      setPolishedContent(polished);

      setPostStep("title");
      const title = settingsQuery.data?.capture_post?.ai_title_enabled === false
        ? job.title
        : await generatePostTitle(polished || markdown, job.title);
      if (captureSeqRef.current !== seq) return;
      setCapturedTitle(title || job.title);

      setPostStep("tags");
      const tags = await generatePostAiTags(polished || markdown, title || job.title);
      if (captureSeqRef.current !== seq) return;
      setPostAiTags(tags);

      setPostStep("complete");
      setToast("Article ready for Obsidian");
    } catch (caught) {
      if (captureSeqRef.current !== seq) return;
      setPostStep("error");
      const message = caught instanceof Error ? caught.message : "Could not process this article";
      setPostError(message);
      setToast(message);
    }
  }

  // Upload the post's photos into Immich under the note GUID and keep the
  // original→embedded mapping so the note renders them from share links.
  async function storePostPhotos(
    nextPosts: WovenPost[],
    sourceUrl: string,
    title: string,
    captureGuid: string,
    seq: number
  ) {
    const photoUrls = [
      ...new Set(
        nextPosts
          .flatMap((post) => (Array.isArray(post.mediaUrls) ? post.mediaUrls : []))
          .map((value) => String(value || "").trim())
          .filter((value) => value && !NON_IMAGE_MEDIA_EXTENSIONS.test(value))
      )
    ];
    if (!photoUrls.length) return { warnings: [], mediaMap: {} };
    try {
      const result = await uploadNoteMedia({ guid: captureGuid, urls: photoUrls, sourceUrl, title });
      if (captureSeqRef.current !== seq) return { warnings: [], mediaMap: {} };
      const nextMap: Record<string, string> = {};
      (result.images || []).forEach((image) => {
        if (image.embedded_url) nextMap[image.url] = image.embedded_url;
      });
      setMediaMap(nextMap);
      setMediaImages(result.images || []);
      if (result.share_url) setShareUrl(result.share_url);
      return { warnings: result.warnings || [], mediaMap: nextMap };
    } catch (caught) {
      if (captureSeqRef.current !== seq) return { warnings: [], mediaMap: {} };
      const message = caught instanceof Error ? caught.message : "Uploading photos to Immich failed";
      setMediaImages(
        photoUrls.map((url) => ({ url, asset_id: "", status: "remote" as const, warning: message }))
      );
      return {
        warnings: [`照片上傳 Immich 失敗，保留原始連結：${message}`],
        mediaMap: {}
      };
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

  async function generatePostTitle(content: string, preferredFallback = "") {
    const fallback = fallbackAiTitle(content, preferredFallback);
    if (!content.trim()) return fallback;
    try {
      const apiKey = await llmApiKey.ensureApiKey(settingsQuery.data || {});
      const response = await chatWithLocalLlm(
        settingsQuery.data || {},
        content,
        settingsQuery.data?.capture_post?.title_system_prompt ?? DEFAULT_AI_TITLE_SYSTEM_PROMPT,
        apiKey
      );
      const title = normalizeAiTitle(response);
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

  async function generatePostAiTags(content: string, title: string) {
    const source = content.trim();
    if (!source) return "";
    try {
      const apiKey = await llmApiKey.ensureApiKey(settingsQuery.data || {});
      const response = await chatWithLocalLlm(
        settingsQuery.data || {},
        buildAiTagsPrompt(source, title),
        AI_TAGS_SYSTEM_PROMPT,
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

  async function saveToObsidian() {
    if (!activeDraft) {
      setToast(
        visibleRoute === "voice"
          ? "Complete a transcript before saving"
          : visibleRoute === "article"
            ? "Capture an article before saving"
            : "Capture a post before saving"
      );
      return;
    }
    try {
      await openObsidianDraft(activeDraft, {
        defaultFolder: settingsQuery.data?.obsidian?.default_folder,
        vaultName: settingsQuery.data?.obsidian?.vault_name
      });
      setToast("Note copied. Opening Obsidian");
    } catch (caught) {
      setToast(caught instanceof Error ? caught.message : "Could not open Obsidian");
    }
  }

  const showError =
    postError ||
    createUrlJob.isError ||
    uploadJob.isError ||
    (jobQuery.isError && !selectedRecord) ||
    (selectedRecordId && recordQuery.isError);
  const mainActionText = voiceJobWorking ? "Stop" : visibleRoute === "voice" ? "Transcribe" : "Capture";
  const mainActionDisabled =
    postIsWorking ||
    isGeneratingAiTitle ||
    isGeneratingAiTags ||
    createUrlJob.isPending ||
    uploadJob.isPending ||
    cancelJob.isPending;

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
              <WorkflowStepper activeStep={workflowStepIndex} route={visibleRoute} aiTitleEnabled={aiTitleEnabled} />
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
                  <Stack direction="row" alignItems="center" spacing={1} sx={{ minWidth: 0 }}>
                    <Typography variant="body2" color="text.secondary" fontWeight={700} noWrap>
                      {activeMessage}
                    </Typography>
                    <Chip
                      size="small"
                      label={`Route: ${routeLabel(visibleRoute)}`}
                      variant="outlined"
                      sx={{ flexShrink: 0, fontWeight: 750 }}
                    />
                  </Stack>
                  <Typography variant="body2" color="text.secondary" fontWeight={700} sx={{ flexShrink: 0 }}>
                    {Math.round(activeProgress)}%
                  </Typography>
                </Stack>
                <LinearProgress value={Math.min(100, activeProgress)} variant="determinate" />
              </Stack>
              <Stack direction={{ xs: "column", sm: "row" }} spacing={1} sx={{ alignSelf: "end", minWidth: 0 }}>
                <Button
                  variant="outlined"
                  disabled={isWorking}
                  onClick={pasteClipboardUrl}
                  sx={{ height: 40, whiteSpace: "nowrap", flexShrink: 0 }}
                >
                  Paste
                </Button>
                <Button
                  variant="contained"
                  color={voiceJobWorking ? "error" : "primary"}
                  disabled={mainActionDisabled}
                  onClick={voiceJobWorking ? stopActiveJob : () => void runClipperUrl()}
                  sx={{ height: 40, whiteSpace: "nowrap", flexShrink: 0 }}
                >
                  {mainActionText}
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
                inputRef={sourceUrlInputRef}
                value={sourceUrl}
                onChange={(event) => {
                  setSourceUrl(event.target.value);
                  setActiveRoute("auto");
                }}
                placeholder="Paste a post, article, video, or audio URL"
                InputProps={{
                  startAdornment: <LinkOutlinedIcon color="disabled" fontSize="small" sx={{ mr: 1 }} />
                }}
              />
            </Box>
          </Box>
          <Divider />
          {showError ? (
            <Alert severity="error">
              {postError || errorMessage(createUrlJob.error || uploadJob.error || (!selectedRecord ? jobQuery.error : null) || recordQuery.error)}
            </Alert>
          ) : null}
          {posts.length > 0 && captureKind === "post" && visibleRoute !== "voice" ? (
            <Typography variant="body2" color="text.secondary">
              Captured {posts.length} post{posts.length === 1 ? "" : "s"}
            </Typography>
          ) : null}
          {shareUrl ? (
            <Typography variant="body2" color="text.secondary">
              Immich share:{" "}
              <Box component="span" sx={{ overflowWrap: "anywhere" }}>
                {shareUrl}
              </Box>
            </Typography>
          ) : null}
          {(visibleRoute === "article" ? articleImages : mediaImages).length ? (
            <Stack direction="row" sx={{ flexWrap: "wrap", gap: 0.75 }}>
              {(visibleRoute === "article" ? articleImages : mediaImages).map((image) => (
                <Chip
                  key={image.url}
                  size="small"
                  color={image.status === "uploaded" ? "success" : "warning"}
                  label={image.status === "uploaded" ? "Image stored in Immich" : "Image kept as original link"}
                />
              ))}
            </Stack>
          ) : null}
          {chainWarnings.map((warning) => (
            <Alert key={warning} severity="warning">
              {warning}
            </Alert>
          ))}
        </Stack>
      </WorkspacePanel>

      <WorkspacePanel>
        <Stack spacing={1.5}>
          <Stack direction={{ xs: "column", sm: "row" }} justifyContent="space-between" alignItems={{ xs: "stretch", sm: "center" }} spacing={1}>
            <Typography variant="h3">Obsidian Preview</Typography>
            <Button variant="contained" disabled={!activeDraft || isWorking} onClick={saveToObsidian} sx={{ whiteSpace: "nowrap" }}>
              Save to Obsidian
            </Button>
          </Stack>
          <Divider />
          <ObsidianNotePreview
            draft={activeDraft}
            emptyMessage={emptyMessage}
            polishedFallback={polishedFallback}
            originalTitle={originalTitle}
          />
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

function WorkflowStepper({
  activeStep,
  route,
  aiTitleEnabled
}: {
  activeStep: number;
  route: ClipperRoute;
  aiTitleEnabled: boolean;
}) {
  const steps = route === "voice"
    ? ["Source", "AI Transcribe", aiTitleEnabled ? "AI Title" : "Title", "AI Tags", "Ready"]
    : route === "article"
      ? ["Capture", "AI Polish", aiTitleEnabled ? "AI Title" : "Title", "AI Tags", "Ready"]
      : ["Capture", "Photos", "AI Polish", aiTitleEnabled ? "AI Title" : "Title", "AI Tags", "Ready"];
  return (
    <Stack spacing={1}>
      <Typography
        variant="body2"
        color="text.primary"
        fontWeight={700}
        sx={{ textAlign: "center" }}
      >
        Obsidian Clipper
      </Typography>
      <LinearProgress aria-hidden value={0} variant="determinate" />
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

function routeForUrl(value: string): ClipperRoute {
  const url = value.trim();
  if (!url) return "auto";
  if (isThreadsUrl(url)) return "post";
  return isVoiceUrl(url) ? "voice" : "article";
}

function routeLabel(route: ClipperRoute) {
  if (route === "voice") return "Voice";
  if (route === "article") return "Article";
  if (route === "post") return "Post";
  return "Auto";
}

function isVoiceUrl(value: string) {
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return false;
  }
  const host = parsed.hostname.toLowerCase();
  const path = parsed.pathname.toLowerCase();
  const mediaExtension = /\.(?:aac|aif|aiff|flac|m4a|m4v|mkv|mov|mp3|mp4|mpeg|mpg|ogg|opus|wav|webm)(?:$|[?#])/i;
  return (
    host === "youtu.be" ||
    host.endsWith(".youtube.com") ||
    host === "youtube.com" ||
    host.includes("bilibili.com") ||
    host === "b23.tv" ||
    host.endsWith(".b23.tv") ||
    host.includes("tiktok.com") ||
    host.includes("instagram.com") ||
    path.includes("/shorts/") ||
    mediaExtension.test(`${path}${parsed.search}`)
  );
}

function isThreadsUrl(url: string) {
  return /https?:\/\/(?:www\.)?threads\.(?:com|net)\//i.test(url);
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

function voiceProgress({
  activeJob,
  selectedRecord,
  uploadProgress,
  isGeneratingAiTitle,
  isGeneratingAiTags
}: {
  activeJob?: TranscriptionJob;
  selectedRecord?: TranscriptionRecord | null;
  uploadProgress: number | null;
  isGeneratingAiTitle: boolean;
  isGeneratingAiTags: boolean;
}) {
  if (isGeneratingAiTags) return Math.max(94, selectedRecord?.progress ?? 0);
  if (isGeneratingAiTitle) return Math.max(86, selectedRecord?.progress ?? 0);
  return uploadProgress ?? activeJob?.progress ?? selectedRecord?.progress ?? 0;
}

function voiceProgressMessage({
  activeJob,
  selectedRecord,
  uploadProgress,
  isGeneratingAiTitle,
  isGeneratingAiTags
}: {
  activeJob?: TranscriptionJob;
  selectedRecord?: TranscriptionRecord | null;
  uploadProgress: number | null;
  isGeneratingAiTitle: boolean;
  isGeneratingAiTags: boolean;
}) {
  if (isGeneratingAiTitle) return "Generating AI title";
  if (isGeneratingAiTags) return "Generating AI tags";
  return jobProgressMessage(activeJob) || selectedRecord?.message || (uploadProgress ? "Uploading media..." : "Ready");
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
  if (!record || record.status !== "completed") return { key: "", title: "", content: "" };
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

function clipGuidFromPayload(payload: unknown) {
  if (!payload || typeof payload !== "object") return "";
  const guid = (payload as { guid?: unknown }).guid;
  return typeof guid === "string" && guid.trim() ? guid.trim() : "";
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

function postStepToIndex(step: PostStep, isArticle = false) {
  if (step === "complete") return isArticle ? 4 : 5;
  if (step === "tags") return isArticle ? 3 : 4;
  if (step === "title") return isArticle ? 2 : 3;
  if (step === "polish") return isArticle ? 1 : 2;
  if (step === "photos") return 1;
  return 0;
}

function postProgress(step: PostStep, isArticle = false) {
  if (step === "complete") return 100;
  if (step === "tags") return 86;
  if (step === "title") return 72;
  if (step === "polish") return isArticle ? 55 : 50;
  if (step === "photos") return 30;
  if (step === "capture") return isArticle ? 10 : 22;
  return 0;
}

function postProgressMessage(step: PostStep, isArticle = false) {
  if (step === "complete") return isArticle ? "Article ready" : "Post ready";
  if (step === "error") return isArticle ? "Article capture failed" : "Capture failed";
  if (step === "tags") return "Generating tags";
  if (step === "title") return "Generating title";
  if (step === "polish") return "Polishing captured text";
  if (step === "photos") return "Uploading photos to Immich…";
  if (step === "capture") return isArticle ? "Capturing article" : "Capturing post";
  return "Ready";
}

function titleFromPostText(text = "") {
  return (
    String(text)
      .split(/\n\s*\n/)
      .map((block) => block.trim())
      .find(Boolean) || ""
  ).replace(/\s+/g, " ");
}

function readPersistedObsidianClipperState(): PersistedObsidianClipperState {
  const fallback: PersistedObsidianClipperState = {
    activeRoute: "auto",
    activeJobId: null,
    selectedRecordId: null,
    sourceUrl: "",
    aiTitle: "",
    aiTitleSourceKey: "",
    aiTags: "",
    aiTagsSourceKey: "",
    postUrl: "",
    posts: [],
    capturedUrl: "",
    capturedTitle: "",
    polishedContent: "",
    postAiTags: "",
    postStep: "idle",
    postError: "",
    chainWarnings: [],
    guid: "",
    captureKind: "post",
    shareUrl: "",
    mediaMap: {},
    mediaImages: [],
    articleJobId: null,
    articleImages: []
  };
  if (typeof window === "undefined") return fallback;
  try {
    const value = window.sessionStorage.getItem(OBSIDIAN_CLIPPER_STATE_KEY) || window.localStorage.getItem(OBSIDIAN_CLIPPER_STATE_KEY);
    if (!value) return fallback;
    const parsed = JSON.parse(value) as Partial<PersistedObsidianClipperState>;
    const postStep = isPersistablePostStep(parsed.postStep) ? parsed.postStep : "idle";
    const hasArticleJobId = typeof parsed.articleJobId === "string" && Boolean(parsed.articleJobId);
    return {
      activeRoute: isClipperRoute(parsed.activeRoute) ? parsed.activeRoute : "auto",
      activeJobId: typeof parsed.activeJobId === "string" && parsed.activeJobId ? parsed.activeJobId : null,
      selectedRecordId: typeof parsed.selectedRecordId === "string" && parsed.selectedRecordId ? parsed.selectedRecordId : null,
      sourceUrl: typeof parsed.sourceUrl === "string" ? parsed.sourceUrl : "",
      aiTitle: typeof parsed.aiTitle === "string" ? parsed.aiTitle : "",
      aiTitleSourceKey: typeof parsed.aiTitleSourceKey === "string" ? parsed.aiTitleSourceKey : "",
      aiTags: typeof parsed.aiTags === "string" ? parsed.aiTags : "",
      aiTagsSourceKey: typeof parsed.aiTagsSourceKey === "string" ? parsed.aiTagsSourceKey : "",
      postUrl: typeof parsed.postUrl === "string" ? parsed.postUrl : "",
      posts: Array.isArray(parsed.posts) ? parsed.posts.filter(isPersistedPost) : [],
      capturedUrl: typeof parsed.capturedUrl === "string" ? parsed.capturedUrl : "",
      capturedTitle: typeof parsed.capturedTitle === "string" ? parsed.capturedTitle : "",
      polishedContent: typeof parsed.polishedContent === "string" ? parsed.polishedContent : "",
      postAiTags: typeof parsed.postAiTags === "string" ? parsed.postAiTags : "",
      postStep: ["capture", "photos", "polish", "title", "tags"].includes(postStep)
        ? hasArticleJobId
          ? "capture"
          : "idle"
        : postStep,
      postError: typeof parsed.postError === "string" ? parsed.postError : "",
      chainWarnings: persistedChainWarnings(parsed.chainWarnings),
      guid: typeof parsed.guid === "string" ? parsed.guid : "",
      captureKind: parsed.captureKind === "article" ? "article" : "post",
      shareUrl: typeof parsed.shareUrl === "string" ? parsed.shareUrl : "",
      mediaMap: persistedMediaMap(parsed.mediaMap),
      mediaImages: persistedImageRecords(parsed.mediaImages),
      articleJobId: hasArticleJobId ? (parsed.articleJobId as string) : null,
      articleImages: persistedImageRecords(parsed.articleImages)
    };
  } catch {
    return fallback;
  }
}

function writePersistedObsidianClipperState(state: PersistedObsidianClipperState) {
  if (typeof window === "undefined") return;
  try {
    const value = JSON.stringify(state);
    window.sessionStorage.setItem(OBSIDIAN_CLIPPER_STATE_KEY, value);
    window.localStorage.setItem(OBSIDIAN_CLIPPER_STATE_KEY, value);
  } catch {
    // If storage is unavailable, the in-memory state still keeps the current page usable.
  }
}

function isClipperRoute(value: unknown): value is ClipperRoute {
  return ["auto", "post", "voice", "article"].includes(String(value));
}

function isPersistablePostStep(value: unknown): value is PostStep {
  return ["idle", "capture", "photos", "polish", "title", "tags", "complete", "error"].includes(String(value));
}

function isPersistedPost(value: unknown): value is WovenPost {
  if (!value || typeof value !== "object") return false;
  const post = value as Partial<WovenPost>;
  return typeof post.text === "string" && typeof post.url === "string" && Array.isArray(post.mediaUrls);
}

function persistedChainWarnings(value: unknown) {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string" && Boolean(item.trim())) : [];
}

function persistedMediaMap(value: unknown): Record<string, string> {
  if (!value || typeof value !== "object") return {};
  const result: Record<string, string> = {};
  for (const [key, entry] of Object.entries(value as Record<string, unknown>)) {
    if (typeof entry === "string" && entry) result[key] = entry;
  }
  return result;
}

// NoteMediaImage and WebArticleImage are structurally identical records, so
// one validator serves both the post photo chips and the article photo chips.
function persistedImageRecords(value: unknown): NoteMediaImage[] {
  if (!Array.isArray(value)) return [];
  return value.filter((item): item is NoteMediaImage => {
    if (!item || typeof item !== "object") return false;
    const record = item as Partial<NoteMediaImage>;
    return (
      typeof record.url === "string" &&
      typeof record.asset_id === "string" &&
      (record.status === "uploaded" || record.status === "remote") &&
      typeof record.warning === "string"
    );
  });
}

function createNoteGuid() {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (char) => {
    const random = Math.floor(Math.random() * 16);
    const value = char === "x" ? random : (random & 0x3) | 0x8;
    return value.toString(16);
  });
}
