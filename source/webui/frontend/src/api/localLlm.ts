import { apiRequest } from "./client";
import type { AppSettings } from "../types/settings";

export async function chatWithLocalLlm(settings: AppSettings, prompt: string, system = "", apiKey?: string) {
  const llm = settings.llm || {};
  const model = llm.model || llm.selected_model || "";
  const payload = await apiRequest<{ response: string }>("/api/local-llm/chat", {
    method: "POST",
    body: JSON.stringify({
      provider: llm.provider || "llama.cpp",
      endpoint: llm.endpoint || "http://127.0.0.1:8080",
      model,
      api_key: apiKey ?? llm.api_key ?? "",
      temperature: llm.temperature ?? 0.4,
      context_length: llm.contextLength,
      system,
      prompt
    })
  });
  return payload.response || "";
}
