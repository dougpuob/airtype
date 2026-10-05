export const AI_TAGS_SYSTEM_PROMPT =
  "你是擅長資訊整理的繁體中文知識管理助手。只輸出可直接貼進 Obsidian 的 hashtag 清單。";

export function buildAiTagsPrompt(content: string, title: string) {
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

export function normalizeAiTags(text = "") {
  const stripped = String(text)
    .replace(/```[\s\S]*?```/g, (block) => block.replace(/```[a-zA-Z]*\n?/g, "").replace(/```/g, ""));
  const lines = stripped
    .split(/\r?\n/)
    .map((line) => line.replace(/^\s*(?:[-*]|\d+[.)])\s*/, "").trim())
    .filter(Boolean)
    .filter((line) => line.includes("#"))
    .slice(0, 8);
  if (lines.length) return lines.join("\n");

  const tags = stripped.match(/#[^\s#]+/g) || [];
  const pairs: string[] = [];
  for (let index = 0; index < tags.length && pairs.length < 8; index += 2) {
    pairs.push(tags.slice(index, index + 2).join(" "));
  }
  return pairs.join("\n");
}

export function yamlTagsFromAiTags(text = "") {
  const tags: string[] = [];
  const seen = new Set<string>();
  for (const line of normalizeAiTags(text).split("\n")) {
    const matches = line.match(/#[^\s#]+/g) || [];
    for (const raw of matches) {
      const value = raw.replace(/^#+/, "").trim();
      if (!value || seen.has(value)) continue;
      seen.add(value);
      tags.push(value);
    }
  }
  return tags;
}
