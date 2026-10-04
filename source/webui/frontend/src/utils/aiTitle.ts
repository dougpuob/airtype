export const DEFAULT_AI_TITLE_SYSTEM_PROMPT =
  "你是擅長提煉文章重點的繁體中文標題編輯。請根據使用者提供的文章產生一個約 30 個字的標題；不要使用冒號、不要提供多個選項、不要加入引號或解釋，只輸出標題。";

const MAX_TITLE_CHARS = 40;

export function fallbackAiTitle(text = "", preferred = "") {
  const preferredTitle = sanitizeAiTitle(preferred);
  if (preferredTitle) return preferredTitle;
  const characters = Array.from(String(text).replace(/\s+/g, " ").trim());
  if (!characters.length) return "TITLE";
  return trimTitle(sanitizeAiTitle(characters.slice(0, MAX_TITLE_CHARS).join(""))) || "TITLE";
}

export function normalizeAiTitle(text = "") {
  const firstLine =
    String(text)
      .split(/\r?\n/)
      .find((line) => line.trim()) || "";
  const normalized = firstLine
    .replace(/^\s*(?:標題|title)\s*[:：]\s*/i, "")
    .replace(/^#+\s*/, "")
    .replace(/[「」『』"“”]/g, "")
    .trim();
  const title = sanitizeAiTitle(normalized);
  const characters = Array.from(title);
  if (characters.length <= MAX_TITLE_CHARS) return trimTitle(title);
  return trimTitle(sanitizeAiTitle(characters.slice(0, MAX_TITLE_CHARS).join("")));
}

function trimTitle(text = "") {
  return String(text)
    .replace(/[與及和的而或、，。：:\s]+$/g, "")
    .trim();
}

function sanitizeAiTitle(text = "") {
  return String(text)
    .replace(/[\\/:*?"<>|;；：\u0000-\u001F]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}
