import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { apiRequest } from "./client";
import type { TranscriptionJob, TranscriptionRecord, TranscriptionRecordSummary } from "../types/transcription";

type UrlJobInput = {
  url: string;
  language?: string | null;
  whisperEndpoint?: string | null;
};

type UploadJobInput = {
  file: File;
  language?: string | null;
  whisperEndpoint?: string | null;
  onProgress?: (progress: number) => void;
};

export function useTranscriptionRecordsQuery() {
  return useQuery({
    queryKey: ["transcription-records", "transcript"],
    queryFn: async () => {
      const payload = await apiRequest<{ records: TranscriptionRecordSummary[] }>("/api/transcribe/records");
      return payload.records;
    }
  });
}

export function useTranscriptionRecordQuery(jobId?: string | null) {
  return useQuery({
    queryKey: ["transcription-record", jobId],
    enabled: Boolean(jobId),
    queryFn: async () => {
      const payload = await apiRequest<{ record: TranscriptionRecord }>(`/api/transcribe/records/${jobId}`);
      return payload.record;
    }
  });
}

export function useTranscriptionJobQuery(jobId?: string | null, enabled = true) {
  return useQuery({
    queryKey: ["transcription-job", jobId],
    enabled: Boolean(jobId) && enabled,
    refetchInterval: Boolean(jobId) && enabled ? 1000 : false,
    queryFn: async () => apiRequest<TranscriptionJob>(`/api/transcribe/jobs/${jobId}`)
  });
}

export function useCreateUrlTranscriptionJobMutation() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ url, language, whisperEndpoint }: UrlJobInput) =>
      apiRequest<TranscriptionJob>("/api/transcribe/url/jobs", {
        method: "POST",
        body: JSON.stringify({
          url,
          language: language || null,
          whisper_endpoint: whisperEndpoint || null
        })
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["transcription-records"] });
    }
  });
}

export function useUploadTranscriptionJobMutation() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ file, language, whisperEndpoint, onProgress }: UploadJobInput) =>
      uploadTranscriptionJob(file, { language, whisperEndpoint, onProgress }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["transcription-records"] });
    }
  });
}

export function useCancelTranscriptionJobMutation() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (jobId: string) =>
      apiRequest<{ ok?: boolean }>(`/api/transcribe/jobs/${jobId}/cancel`, {
        method: "POST"
      }),
    onSuccess: (_, jobId) => {
      queryClient.invalidateQueries({ queryKey: ["transcription-job", jobId] });
      queryClient.invalidateQueries({ queryKey: ["transcription-records"] });
    }
  });
}

function uploadTranscriptionJob(
  file: File,
  options: {
    language?: string | null;
    whisperEndpoint?: string | null;
    onProgress?: (progress: number) => void;
  }
) {
  const form = new FormData();
  form.append("file", file, file.name);
  if (options.whisperEndpoint) {
    form.append("whisper_endpoint", options.whisperEndpoint);
  }
  if (options.language) {
    form.append("language", options.language);
  }

  return new Promise<TranscriptionJob>((resolve, reject) => {
    const request = new XMLHttpRequest();
    request.open("POST", "/api/transcribe/jobs");
    request.upload.onprogress = (event) => {
      if (!event.lengthComputable) return;
      options.onProgress?.(Math.max(2, Math.round((event.loaded / event.total) * 12)));
    };
    request.onload = () => {
      if (request.status >= 200 && request.status < 300) {
        resolve(JSON.parse(request.responseText) as TranscriptionJob);
        return;
      }
      const error = parseErrorResponse(request.responseText);
      reject(new Error(error || "Upload failed"));
    };
    request.onerror = () => reject(new Error("Upload failed"));
    request.send(form);
  });
}

function parseErrorResponse(value: string) {
  try {
    const payload = JSON.parse(value) as { detail?: string };
    return payload.detail;
  } catch {
    return value;
  }
}
