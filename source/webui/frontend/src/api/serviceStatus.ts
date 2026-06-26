import { useQuery } from "@tanstack/react-query";
import { apiRequest } from "./client";
import type { AppSettings } from "../types/settings";

export type WhisperServerStatus = {
  ok?: boolean;
  running?: boolean;
  endpoint?: string;
  model?: string;
  model_path?: string;
  mode?: string;
};

export function useWhisperServerStatusQuery() {
  return useQuery({
    queryKey: ["service-status", "whisper"],
    refetchInterval: 10_000,
    queryFn: async () => apiRequest<WhisperServerStatus>("/api/whisper-server/status")
  });
}

export function useLocalLlmHealthQuery(settings?: AppSettings) {
  const llm = settings?.llm || {};
  const provider = llm.provider || "";
  const endpoint = llm.endpoint || "";
  return useQuery({
    queryKey: ["service-status", "llm", provider, endpoint, llm.api_key || ""],
    enabled: Boolean(provider && endpoint),
    refetchInterval: 10_000,
    queryFn: async () =>
      apiRequest<{ ok?: boolean }>("/api/local-llm/health", {
        method: "POST",
        body: JSON.stringify({
          provider,
          endpoint,
          api_key: llm.api_key || null
        })
      })
  });
}
