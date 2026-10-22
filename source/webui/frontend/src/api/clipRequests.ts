import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { apiRequest } from "./client";

export type ClipRequestStatus = "queued" | "running" | "completed" | "failed";

export type ClipRequest = {
  id: string;
  kind: "voice" | "article" | "post" | string;
  source: string;
  origin?: "manual" | "watching" | string;
  notes?: string;
  status: ClipRequestStatus | string;
  step?: number;
  progress: number;
  message: string;
  error: string;
  obsidian_save: "pending" | "complete" | string;
  title: string;
  content: string;
  polished_content: string;
  ai_tags: string;
  sources: string[];
  tags: string[];
  datetime: string;
  guid: string;
  share_url: string;
  note_title: string;
  note: string;
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
