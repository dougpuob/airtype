import { useCallback, useState } from "react";
import type { AppSettings } from "../types/settings";

type PendingRequest = {
  endpoint: string;
  provider: string;
  resolve: (value: string) => void;
  reject: (reason?: unknown) => void;
};

export function useLlmApiKey() {
  const [sessionKeys, setSessionKeys] = useState<Record<string, string>>({});
  const [pendingRequest, setPendingRequest] = useState<PendingRequest | null>(null);

  const ensureApiKey = useCallback(
    (settings: AppSettings) => {
      const llm = settings.llm || {};
      const configured = String(llm.api_key || "").trim();
      if (configured) return Promise.resolve(configured);

      const slot = llmApiKeySlot(settings);
      if (sessionKeys[slot]) return Promise.resolve(sessionKeys[slot]);

      const endpoint = String(llm.endpoint || "").trim();
      if (!shouldAskForLlmApiKey(endpoint)) return Promise.resolve("");

      return new Promise<string>((resolve, reject) => {
        setPendingRequest({
          endpoint,
          provider: llm.provider || "OpenAI compatible",
          resolve,
          reject
        });
      });
    },
    [sessionKeys]
  );

  const submitApiKey = useCallback(
    (value: string) => {
      if (!pendingRequest) return;
      const trimmed = value.trim();
      setSessionKeys((current) => ({
        ...current,
        [apiKeySlot(pendingRequest.provider, pendingRequest.endpoint)]: trimmed
      }));
      pendingRequest.resolve(trimmed);
      setPendingRequest(null);
    },
    [pendingRequest]
  );

  const cancelApiKey = useCallback(() => {
    if (!pendingRequest) return;
    pendingRequest.reject(new Error("API key is required for this endpoint"));
    setPendingRequest(null);
  }, [pendingRequest]);

  return {
    pendingRequest,
    ensureApiKey,
    submitApiKey,
    cancelApiKey
  };
}

function llmApiKeySlot(settings: AppSettings) {
  const llm = settings.llm || {};
  return apiKeySlot(llm.provider || "", llm.endpoint || "");
}

function apiKeySlot(provider: string, endpoint: string) {
  return `${provider}|${String(endpoint).trim().replace(/\/+$/, "")}`;
}

function shouldAskForLlmApiKey(endpoint: string) {
  if (!endpoint) return false;
  try {
    const url = new URL(endpoint);
    return url.protocol === "https:" && !["localhost", "127.0.0.1", "::1"].includes(url.hostname);
  } catch {
    return false;
  }
}
