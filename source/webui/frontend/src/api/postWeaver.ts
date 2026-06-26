import { useMutation } from "@tanstack/react-query";
import { apiRequest } from "./client";
import type { PostImportResponse, ThreadsChainResponse } from "../types/postWeaver";

export function useImportPostMutation() {
  return useMutation({
    mutationFn: async (url: string) => {
      const endpoint = isThreadsUrl(url) ? "/api/post-weaver/threads-chain" : "/api/post-weaver/import";
      const payload = await apiRequest<PostImportResponse | ThreadsChainResponse>(endpoint, {
        method: "POST",
        body: JSON.stringify({ url })
      });
      return { payload, isThreads: isThreadsUrl(url) };
    }
  });
}

export function isThreadsUrl(url: string) {
  return /https?:\/\/(?:www\.)?threads\.(?:com|net)\//i.test(url);
}
