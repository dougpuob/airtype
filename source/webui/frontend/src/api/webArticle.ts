import { useMutation, useQuery } from "@tanstack/react-query";
import { apiRequest } from "./client";

export type WebArticleImage = {
  url: string;
  asset_id: string;
  status: "uploaded" | "remote";
  warning: string;
  embedded_url?: string;
};

export type WebArticleJob = {
  job_id: string;
  url: string;
  status: "queued" | "running" | "completed" | "error";
  progress: number;
  message: string;
  guid: string;
  title: string;
  markdown: string;
  images: WebArticleImage[];
  share_url: string;
  album_id: string;
  warnings: string[];
  error: string;
  created_at: string;
  updated_at: string;
};

export type KnownSourceEntry = {
  host: string;
  pipeline: string;
  label: string;
};

export type KnownSourcesResponse = {
  sources: KnownSourceEntry[];
  shorts_path_marker: string;
  media_file_extensions: string[];
  web_article_pipeline: string;
};

export function startWebArticleJob(url: string, guid = "") {
  return apiRequest<WebArticleJob>("/api/web-article/jobs", {
    method: "POST",
    body: JSON.stringify(guid ? { url, guid } : { url })
  });
}

export function fetchWebArticleJob(jobId: string) {
  return apiRequest<WebArticleJob>(`/api/web-article/jobs/${encodeURIComponent(jobId)}`);
}

export function fetchKnownSources() {
  return apiRequest<KnownSourcesResponse>("/api/web-article/known-sources");
}

export function useKnownSourcesQuery() {
  return useQuery({
    queryKey: ["web-article-known-sources"],
    queryFn: fetchKnownSources,
    staleTime: 5 * 60 * 1000
  });
}

export function useStartWebArticleJobMutation() {
  return useMutation({ mutationFn: (url: string) => startWebArticleJob(url) });
}