import { useMutation, useQuery, useQueryClient, type QueryClient } from "@tanstack/react-query";
import { apiRequest } from "./client";

export type ClipRequestStatus = "queued" | "running" | "completed" | "failed";

/**
 * A clip request. The queue list (`GET /api/clip-requests`) sends a summary:
 * `note`, `content`, `polished_content` and `external_content` are left out and
 * `has_note` / `has_content` / `summary` are set. Load the full record with
 * `GET /api/clip-requests/{id}` (see `loadFullClipRequest`) when it is opened or saved.
 */
export type ClipRequest = {
  id: string;
  kind: "voice" | "article" | "post" | string;
  source: string;
  origin?: "manual" | "watching" | string;
  notes?: string;
  external_content?: string;
  has_note?: boolean;
  has_content?: boolean;
  summary?: boolean;
  status: ClipRequestStatus | string;
  step?: number;
  progress: number;
  message: string;
  error: string;
  obsidian_save: "pending" | "complete" | string;
  title: string;
  content?: string;
  polished_content?: string;
  ai_tags: string;
  sources: string[];
  tags: string[];
  datetime: string;
  guid: string;
  share_url: string;
  note_title: string;
  note?: string;
  created_at: string;
  updated_at: string;
};

export function useClipRequestsQuery() {
  return useQuery({
    queryKey: ["clip-requests"],
    queryFn: async () => {
      const payload = await apiRequest<{ requests: ClipRequest[] }>("/api/clip-requests");
      return payload.requests;
    },
    refetchInterval: (query) => {
      const requests = query.state.data;
      if (!requests?.some((item) => item.status === "queued" || item.status === "running")) return false;
      return 2000;
    }
  });
}

/** True when the request has a note to save (works for summaries and full records). */
export function clipHasNote(request: ClipRequest | null | undefined) {
  if (!request) return false;
  return Boolean(request.note) || Boolean(request.has_note);
}

/** True when the record carries the heavy body fields (not a list summary). */
export function isFullClipRequest(request: ClipRequest | null | undefined) {
  return Boolean(request) && !request?.summary && request?.note !== undefined;
}

function clipRequestDetailKey(request: Pick<ClipRequest, "id" | "updated_at">) {
  return ["clip-request", request.id, request.updated_at] as const;
}

function fetchClipRequest(id: string) {
  return apiRequest<ClipRequest>(`/api/clip-requests/${encodeURIComponent(id)}`);
}

/** Full record for one request, cached per `updated_at`. */
export function useClipRequestDetailQuery(request: ClipRequest | null) {
  const wanted = Boolean(request && (request.has_note || request.has_content));
  return useQuery({
    queryKey: request ? clipRequestDetailKey(request) : ["clip-request", "", ""],
    queryFn: () => fetchClipRequest(request!.id),
    enabled: Boolean(request) && wanted && !isFullClipRequest(request),
    staleTime: Infinity,
    gcTime: 5 * 60 * 1000
  });
}

/** Return the full record, fetching it only when `request` is a list summary. */
export async function loadFullClipRequest(queryClient: QueryClient, request: ClipRequest): Promise<ClipRequest> {
  if (isFullClipRequest(request)) return request;
  return queryClient.fetchQuery({
    queryKey: clipRequestDetailKey(request),
    queryFn: () => fetchClipRequest(request.id),
    staleTime: Infinity
  });
}

export function useCreateClipRequestMutation() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (input: { url: string; notes?: string }) =>
      apiRequest<ClipRequest>("/api/clip-requests", {
        method: "POST",
        body: JSON.stringify({ url: input.url, notes: input.notes || "" })
      }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["clip-requests"] });
    }
  });
}

export function useCancelClipRequestMutation() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => apiRequest<ClipRequest>(`/api/clip-requests/${id}/cancel`, { method: "POST" }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["clip-requests"] });
    }
  });
}

export function useDeleteClipRequestMutation() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => apiRequest<{ deleted: boolean }>(`/api/clip-requests/${id}`, { method: "DELETE" }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["clip-requests"] });
    }
  });
}

export function useSaveClipRequestMutation() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => apiRequest<ClipRequest>(`/api/clip-requests/${id}/save`, { method: "POST" }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["clip-requests"] });
    }
  });
}
