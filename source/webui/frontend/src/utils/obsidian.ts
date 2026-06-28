import type { TranscriptionRecord, TranscriptSegment } from "../types/transcription";
import type { WovenPost } from "../types/postWeaver";

const OBSIDIAN_TRANSCRIPT_TEMPLATE = `---
title: {{DATE}} {{TITLE}}
sources:
{{sources}}
datetime: {{DATETIME}}
tags:
{{tags}}
---

---

# Title

{{TITLE}}

---

# Notes




---

# AI Tags

{{ai_tags}}

---

# AI Polished Article

{{polished_content}}

---

# Original Transcript

{{content}}
`;

export type TranscriptObsidianDraft = {
  title: string;
  noteTitle: string;
  note: string;
  content: string;
  polishedContent: string;
  aiTags: string;
  sources: string[];
  tags: string[];
  datetime: string;
};

export function buildTranscriptObsidianDraft(record?: TranscriptionRecord | null, aiTags = ""): TranscriptObsidianDraft | null {
  if (!record?.transcript?.segments?.length && !record?.transcript?.text) return null;

  const content = transcriptOriginalText(record.transcript?.segments, record.transcript?.text);
  if (!content.trim()) return null;

  const dateParts = localObsidianDateParts();
  const title = sanitizeObsidianTitle(record.title || record.source?.name || "Untitled transcript");
  const sources = transcriptSources(record);
  const tags = [dateParts.date, "airtype", "speech-to-text", ...sourceDomainTags(sources)];
  const polishedContent = record.article?.text?.trim() || "";
  const values: Record<string, string> = {
    sources: yamlSourceList(sources),
    DATETIME: dateParts.datetime,
    DATE: dateParts.date,
    tags: yamlTagList(tags),
    TITLE: title,
    ai_tags: aiTags,
    polished_content: polishedContent,
    content
  };
  const note = OBSIDIAN_TRANSCRIPT_TEMPLATE.replace(
    /{{(sources|DATETIME|DATE|TITLE|tags|ai_tags|polished_content|content)}}/g,
    (_, key: string) => values[key] ?? ""
  );

  return {
    title,
    note,
    noteTitle: `${dateParts.date} ${title}`,
    content,
    polishedContent,
    aiTags,
    sources,
    tags,
    datetime: dateParts.datetime
  };
}

export function openObsidianDraft(draft: { noteTitle: string; note: string }, defaultFolder = "") {
  const noteName = obsidianNotePath(defaultFolder, draft.noteTitle);
  const query = [
    ["name", noteName],
    ["content", draft.note]
  ]
    .map(([key, value]) => `${key}=${encodeURIComponent(value)}`)
    .join("&");
  window.location.href = `obsidian://new?${query}`;
}

function obsidianNotePath(folder: string, noteTitle: string) {
  const cleanFolder = String(folder || "")
    .replace(/\\/g, "/")
    .split("/")
    .map((part) => sanitizeObsidianTitle(part))
    .filter(Boolean)
    .join("/");
  return cleanFolder ? `${cleanFolder}/${noteTitle}` : noteTitle;
}

const OBSIDIAN_POST_TEMPLATE = `---
title: {{DATE}} {{TITLE}}
sources:
{{sources}}
datetime: {{DATETIME}}
tags:
{{tags}}
---

---

# Title

{{TITLE}}

---

# Notes




---

# AI Tags

{{ai_tags}}

---

# AI Polished Article

{{polished_content}}

---

# Original Content

{{content}}

---

END`;

export type PostObsidianDraft = {
  articleTitle: string;
  noteTitle: string;
  note: string;
  content: string;
  polishedContent: string;
  aiTags: string;
  sources: string[];
  tags: string[];
  datetime: string;
};

export function buildPostObsidianDraft(input: {
  posts: WovenPost[];
  capturedUrl: string;
  capturedTitle: string;
  polishedContent: string;
  aiTags?: string;
}): PostObsidianDraft | null {
  const content = uniquePostBlocks(input.posts.map((post) => post.text.trim()).filter(Boolean).join("\n\n"));
  if (!content) return null;

  const dateParts = localObsidianDateParts();
  const sources = postSources(input.posts, input.capturedUrl);
  const tags = [dateParts.date, "airtype", ...sourceDomainTags(sources)];
  const articleTitle =
    sanitizeObsidianTitle(input.capturedTitle || fallbackArticleTitle(input.polishedContent || content)) || "TITLE";
  const values: Record<string, string> = {
    sources: yamlSourceList(sources),
    DATETIME: dateParts.datetime,
    DATE: dateParts.date,
    tags: yamlTagList(tags),
    TITLE: articleTitle,
    ai_tags: input.aiTags || "",
    polished_content: input.polishedContent,
    content
  };
  const note = OBSIDIAN_POST_TEMPLATE.replace(
    /{{(sources|DATETIME|DATE|TITLE|tags|ai_tags|polished_content|content)}}/g,
    (_, key: string) => values[key] ?? ""
  );

  return {
    articleTitle,
    note,
    noteTitle: `${dateParts.date} ${articleTitle}`,
    content,
    polishedContent: input.polishedContent,
    aiTags: input.aiTags || "",
    sources,
    tags,
    datetime: dateParts.datetime
  };
}

function transcriptOriginalText(segments?: TranscriptSegment[], fallbackText?: string) {
  if (!segments?.length) return fallbackText || "";
  return segments
    .map((segment) => (segment.text || "").trim().replace(/\r\n?/g, "\n"))
    .filter(Boolean)
    .map((text) => `${text}    \n`)
    .join("");
}

function postSources(posts: WovenPost[], capturedUrl: string) {
  const candidates = [
    capturedUrl,
    ...posts.flatMap((post) => [
      post.url,
      ...urlsInPostText(post.text),
      ...(Array.isArray(post.mediaUrls) ? post.mediaUrls : [])
    ])
  ];
  const seen = new Set<string>();
  return candidates
    .map((value) => String(value || "").trim())
    .filter((value) => {
      if (!value || seen.has(value)) return false;
      seen.add(value);
      return true;
    });
}

function urlsInPostText(text = "") {
  return (String(text).match(/https?:\/\/\S+/gi) || [])
    .map((url) => url.replace(/[\])}>，。！？；：】【、.,;:!?]+$/g, ""))
    .filter(Boolean);
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

function fallbackArticleTitle(text = "") {
  const characters = Array.from(String(text).replace(/\s+/g, " ").trim());
  if (!characters.length) return "TITLE";
  return sanitizeObsidianTitle(characters.slice(0, 30).join("")) || "TITLE";
}

function transcriptSources(record: TranscriptionRecord) {
  const metadata = record.source?.metadata || {};
  const requestUrl = typeof record.request?.url === "string" ? record.request.url : "";
  const candidates = [
    record.source?.url,
    requestUrl,
    metadata.webpage_url,
    metadata.url,
    metadata.original_url,
    metadata.resolved_url
  ];
  const seen = new Set<string>();
  return candidates
    .map((value) => String(value || "").trim())
    .filter((value) => {
      if (!value || seen.has(value)) return false;
      seen.add(value);
      return true;
    });
}

function localObsidianDateParts(date = new Date()) {
  const pad = (value: number) => String(value).padStart(2, "0");
  const day = `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  return {
    date: day,
    datetime: `${day} ${pad(date.getHours())}:${pad(date.getMinutes())}`
  };
}

function sanitizeObsidianTitle(text = "") {
  return String(text)
    .replace(/[\\/:*?"<>|;；：\u0000-\u001F]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function yamlSourceList(urls: string[]) {
  return urls
    .map((url) => {
      const escaped = String(url).split("\\").join("\\\\").split('"').join('\\"');
      return `  - "${escaped}"`;
    })
    .join("\n");
}

function yamlTagList(tags: string[]) {
  return tags.map((tag) => `  - ${tag}`).join("\n");
}

function sourceDomainTags(urls: string[]) {
  const tags = new Set<string>();
  urls.forEach((value) => {
    try {
      const url = new URL(String(value || "").trim());
      if (!/^https?:$/.test(url.protocol) || !url.hostname) return;
      const hostname = url.hostname.toLowerCase().replace(/^www\./, "");
      const serviceName = hostname.split(".")[0];
      if (serviceName) tags.add(serviceName);
    } catch {
      // Local files and non-URL sources do not need domain tags.
    }
  });
  return [...tags];
}
