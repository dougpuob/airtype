export const DEFAULT_AI_TITLE_SYSTEM_PROMPT =
  "你是擅長提煉文章重點的繁體中文標題編輯。請根據使用者提供的文章產生一個約 30 個字的標題；不要使用冒號、不要提供多個選項、不要加入引號或解釋，只輸出標題。";

export function fallbackAiTitle(text = "") {
  const characters = Array.from(String(text).replace(/\s+/g, " ").trim());
  if (!characters.length) return "TITLE";
  return sanitizeAiTitle(characters.slice(0, 30).join("")) || "TITLE";
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
  return sanitizeAiTitle(Array.from(normalized).slice(0, 30).join(""));
}

function sanitizeAiTitle(text = "") {
  return String(text)
    .replace(/[\\/:*?"<>|;；：\u0000-\u001F]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}
