"""Obsidian hashtag generation shared by URL transcription and the WebUI."""

from __future__ import annotations

import re

AI_TAGS_SYSTEM_PROMPT = (
    "你是擅長資訊整理的繁體中文知識管理助手。只輸出可直接貼進 Obsidian 的 hashtag 清單。"
)

_HASHTAG = re.compile(r"#[^\s#]+")


def build_ai_tags_prompt(content: str, title: str) -> str:
    return (
        "請根據以下文章產生 5 到 8 組 Obsidian hashtag。\n\n"
        "要求：\n"
        "1. 每一組包含一個繁體中文 hashtag 與一個對應英文 hashtag。\n"
        "2. 英文若有常見縮寫，請優先使用縮寫，例如 AI、LLM、API、GPU、CPU、SaaS。\n"
        "3. hashtag 不要有空格、標點或解釋文字。\n"
        "4. 每行只輸出一組，格式固定為：#中文標籤 #EnglishTag\n"
        "5. 不要輸出編號、前言、結語、Markdown code block。\n\n"
        f"標題：{title or '未命名'}\n\n"
        "文章：\n"
        f"{content}"
    )


def normalize_ai_tags(text: str = "") -> str:
    stripped = re.sub(
        r"```[\s\S]*?```",
        lambda block: re.sub(r"```[a-zA-Z]*\n?", "", block.group(0)).replace("```", ""),
        str(text or ""),
    )
    lines: list[str] = []
    for raw in stripped.splitlines():
        line = re.sub(r"^\s*(?:[-*]|\d+[.)])\s*", "", raw).strip()
        if line and "#" in line:
            lines.append(line)
        if len(lines) == 8:
            break
    if lines:
        return "\n".join(lines)

    tags = _HASHTAG.findall(stripped)
    pairs: list[str] = []
    for index in range(0, len(tags), 2):
        pairs.append(" ".join(tags[index : index + 2]))
        if len(pairs) == 8:
            break
    return "\n".join(pairs)
