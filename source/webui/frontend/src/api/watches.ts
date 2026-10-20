import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { apiRequest } from "./client";

export type WatchPostSummary = {
  code: string;
  url: string;
  title: string;
  post_created_at: string | null;
  text_length: number;
  image_count: number;
  video_count: number;
  pinned: boolean;
  seen?: boolean;
};

export type WatchPostLog = WatchPostSummary & {
  discovered_at: string;
  queued_at: string | null;
  baseline: boolean;
  clip_request_id: string | null;
  status: string;
  error: string;
};

export type WatchCheckResult = {
  checked_at: string;
  ok: boolean;
  dry_run: boolean;
  code: string;
  message: string;
  fetch?: string;
  posts_found: number;
  new_posts: number;
  latest?: WatchPostSummary[];
};

export type WatchTarget = {
  id: string;
  site: string;
  username: string;
  profile_url: string;
  label: string;
  interval_minutes: number;
  enabled: boolean;
  initial_queue_latest: number;
  baseline_done: boolean;
  created_at: string;
  updated_at: string;
  last_checked_at: string | null;
  next_check_at: string | null;
  last_result: WatchCheckResult | null;
  posts: WatchPostLog[];
  post_count: number;
  queued_count: number;
};

type WatchList = { watches: WatchTarget[]; min_interval_minutes: number; scheduler_running: boolean };
type CheckResponse = { target: WatchTarget | null; result: WatchCheckResult | null };

export function useWatchesQuery() {
  return useQuery({
    queryKey: ["watches"],
    refetchInterval: 30_000,
    queryFn: async () => apiRequest<WatchList>("/api/watches")
  });
}

function useInvalidateWatches() {
  const queryClient = useQueryClient();
  return () => {
    void queryClient.invalidateQueries({ queryKey: ["watches"] });
    void queryClient.invalidateQueries({ queryKey: ["clip-requests"] });
  };
}

export function useProbeWatchMutation() {
  return useMutation({
    mutationFn: (target: string) =>
      apiRequest<{ username: string; profile_url: string; result: WatchCheckResult }>("/api/watches/probe", {
        method: "POST",
        body: JSON.stringify({ target })
      })
  });
}

export function useCreateWatchMutation() {
  const invalidate = useInvalidateWatches();
  return useMutation({
    mutationFn: (body: { target: string; label: string; interval_minutes: number; enabled: boolean; queue_latest: number }) =>
      apiRequest<CheckResponse>("/api/watches", { method: "POST", body: JSON.stringify(body) }),
    onSuccess: invalidate
  });
}

export function useUpdateWatchMutation() {
  const invalidate = useInvalidateWatches();
  return useMutation({
    mutationFn: ({ id, ...body }: { id: string; label?: string; interval_minutes?: number; enabled?: boolean }) =>
      apiRequest<{ target: WatchTarget }>(`/api/watches/${encodeURIComponent(id)}`, {
        method: "PATCH",
        body: JSON.stringify(body)
      }),
    onSuccess: invalidate
  });
}

export function useDeleteWatchMutation() {
  const invalidate = useInvalidateWatches();
  return useMutation({
    mutationFn: (id: string) => apiRequest<{ deleted: boolean }>(`/api/watches/${encodeURIComponent(id)}`, { method: "DELETE" }),
    onSuccess: invalidate
  });
}

export function useRunWatchMutation() {
  const invalidate = useInvalidateWatches();
  return useMutation({
    mutationFn: ({ id, mode }: { id: string; mode: "test" | "check" }) =>
      apiRequest<CheckResponse>(`/api/watches/${encodeURIComponent(id)}/${mode}`, { method: "POST" }),
    onSuccess: invalidate
  });
}
