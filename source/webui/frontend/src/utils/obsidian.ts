import type { TranscriptionRecord, TranscriptSegment } from "../types/transcription";
import type { WovenPost } from "../types/postWeaver";

const OBSIDIAN_TRANSCRIPT_TEMPLATE = `---
title: {{DATE}} {{TITLE}}
guid: {{GUID}}
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
  guid: string;
};

export function buildTranscriptObsidianDraft(
  record?: TranscriptionRecord | null,
  aiTags = "",
  titleOverride = "",
  guid = ""
): TranscriptObsidianDraft | null {
  if (!record?.transcript?.segments?.length && !record?.transcript?.text) return null;

  const content = transcriptOriginalText(record.transcript?.segments, record.transcript?.text);
  if (!content.trim()) return null;

  const dateParts = localObsidianDateParts();
  const title = sanitizeObsidianTitle(titleOverride || record.title || record.source?.name || "Untitled transcript");
  const sources = transcriptSources(record);
  const tags = [dateParts.date, "airtype", "speech-to-text", ...sourceDomainTags(sources)];
  const polishedContent = record.article?.text?.trim() || "";
  const values: Record<string, string> = {
    sources: yamlSourceList(sources),
    DATETIME: dateParts.datetime,
    DATE: dateParts.date,
    tags: yamlTagList(tags),
    TITLE: title,
    GUID: guid,
    ai_tags: aiTags,
    polished_content: polishedContent,
    content
  };
  const note = OBSIDIAN_TRANSCRIPT_TEMPLATE.replace(
    /{{(sources|DATETIME|DATE|TITLE|tags|GUID|ai_tags|polished_content|content)}}/g,
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
    datetime: dateParts.datetime,
    guid
  };
}

type ObsidianOpenOptions = {
  defaultFolder?: string;
  vaultName?: string;
};

export async function openObsidianDraft(
  draft: { noteTitle: string; note: string },
  options: ObsidianOpenOptions = {}
) {
  const notePath = obsidianNotePath(options.defaultFolder || "", draft.noteTitle);
  await copyTextToClipboard(draft.note);
  // Full articles overflow macOS/Obsidian URI limits. Obsidian then reports
  // "Unable to find a vault" even when the vault exists. Clipboard keeps the
  // URI short. Omit vault to use the currently open vault; vault_name must
  // match the vault switcher, not a folder inside the vault.
  window.location.href = obsidianNewUri({
    vaultName: options.vaultName,
    file: notePath,
    clipboard: true
  });
}

export function obsidianNewUri(options: { vaultName?: string; file: string; content?: string; clipboard?: boolean }) {
  const vaultName = String(options.vaultName || "").trim();
  const parts: string[] = [];
  if (vaultName) parts.push(`vault=${encodeURIComponent(vaultName)}`);
  parts.push(`file=${encodeURIComponent(options.file)}`);
  if (options.clipboard) parts.push("clipboard=true");
  else if (options.content) parts.push(`content=${encodeURIComponent(options.content)}`);
  return `obsidian://new?${parts.join("&")}`;
}

async function copyTextToClipboard(text: string) {
  if (typeof navigator !== "undefined" && navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text);
      return;
    } catch {
      // Fall through to the execCommand path used on older Safari.
    }
  }
  if (typeof document === "undefined") {
    throw new Error("Clipboard is unavailable");
  }
  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.setAttribute("readonly", "");
  textarea.style.position = "fixed";
  textarea.style.top = "0";
  textarea.style.left = "0";
  textarea.style.opacity = "0";
  document.body.appendChild(textarea);
  textarea.focus();
  textarea.select();
  const copied = document.execCommand("copy");
  textarea.remove();
  if (!copied) throw new Error("Could not copy the note to the clipboard");
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
guid: {{GUID}}
sources:
{{sources}}
immich_share: {{IMMICH_SHARE}}
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
  guid: string;
  shareUrl: string;
};

export function buildPostObsidianDraft(input: {
  posts: WovenPost[];
  capturedUrl: string;
  capturedTitle: string;
  polishedContent: string;
  aiTags?: string;
  guid?: string;
  shareUrl?: string;
  mediaMap?: Record<string, string>;
  extraTags?: string[];
}): PostObsidianDraft | null {
  const content = uniquePostBlocks(
    input.posts
      .flatMap((post) => [
        post.text.trim(),
        ...(Array.isArray(post.mediaUrls) ? post.mediaUrls : []).map((url) => embeddedPhotoMarkdown(url, input.mediaMap))
      ])
      .filter(Boolean)
      .join("\n\n")
  );
  if (!content) return null;

  const dateParts = localObsidianDateParts();
  const sources = postSources(input.posts, input.capturedUrl);
  const tags = uniqueTags([dateParts.date, "airtype", ...sourceDomainTags(sources), ...(input.extraTags || [])]);
  const articleTitle =
    sanitizeObsidianTitle(input.capturedTitle || fallbackArticleTitle(input.polishedContent || content)) || "TITLE";
  const values: Record<string, string> = {
    sources: yamlSourceList(sources),
    DATETIME: dateParts.datetime,
    DATE: dateParts.date,
    tags: yamlTagList(tags),
    TITLE: articleTitle,
    GUID: input.guid || "",
    IMMICH_SHARE: input.shareUrl || "",
    ai_tags: input.aiTags || "",
    polished_content: input.polishedContent,
    content
  };
  const note = OBSIDIAN_POST_TEMPLATE.replace(
    /{{(sources|DATETIME|DATE|TITLE|tags|GUID|IMMICH_SHARE|ai_tags|polished_content|content)}}/g,
    (_, key: string) => values[key] ?? ""
  ).replace(/^immich_share:\s*\n/m, "");

  return {
    articleTitle,
    note,
    noteTitle: `${dateParts.date} ${articleTitle}`,
    content,
    polishedContent: input.polishedContent,
    aiTags: input.aiTags || "",
    sources,
    tags,
    datetime: dateParts.datetime,
    guid: input.guid || "",
    shareUrl: input.shareUrl || ""
  };
}

function transcriptOriginalText(segments?: TranscriptSegment[], fallbackText?: string) {
  if (!segments?.length) return fallbackText || "";
  return segments
    .map((segment) => (segment.text || "").trim().replace(/\r\n?/g, "\n"))
    .filter(Boolean)
    .map((text) => `${text}${" ".repeat(4)}\n`)
    .join("");
}

function embeddedPhotoMarkdown(url: string, mediaMap?: Record<string, string>) {
  const clean = String(url || "").trim();
  if (!clean) return "";
  return `![](${mediaMap?.[clean] || clean})`;
}

function postSources(posts: WovenPost[], capturedUrl: string) {
  // Provenance only: the captured page and each post permalink.
  // Body hyperlinks, TOC anchors, Wikipedia asides, and Immich image URLs
  // must not land in frontmatter — they bloated tags (sec, zh, immich-app)
  // and leaked broken markdown fragments like "url)，單季營收".
  const candidates = [capturedUrl, ...posts.map((post) => post.url)];
  const seen = new Set<string>();
  return candidates
    .map((value) => canonicalSourceUrl(value))
    .filter((value) => {
      if (!value || seen.has(value)) return false;
      seen.add(value);
      return true;
    });
}

function canonicalSourceUrl(value?: string) {
  const trimmed = String(value || "").trim();
  if (!trimmed) return "";
  try {
    const url = new URL(trimmed);
    if (!/^https?:$/.test(url.protocol) || !url.hostname) return "";
    url.hash = "";
    let href = url.toString();
    if (url.pathname !== "/" && href.endsWith("/")) href = href.slice(0, -1);
    return href;
  } catch {
    return "";
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
      if (hostname.endsWith(".ts.net")) return;
      const serviceName = hostname.split(".")[0];
      if (serviceName) tags.add(serviceName);
    } catch {
      // Local files and non-URL sources do not need domain tags.
    }
  });
  return [...tags];
}

function uniqueTags(tags: string[]) {
  const seen = new Set<string>();
  return tags.filter((tag) => {
    const value = String(tag || "").trim();
    if (!value || seen.has(value)) return false;
    seen.add(value);
    return true;
  });
}
