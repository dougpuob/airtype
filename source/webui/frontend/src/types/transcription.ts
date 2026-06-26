export type TranscriptSegment = {
  id?: number | string;
  start?: number | null;
  end?: number | null;
  time?: string;
  duration_text?: string;
  has_timestamps?: boolean;
  text?: string;
  text_length?: number;
};

export type TranscriptionJob = {
  job_id: string;
  status: "queued" | "downloading" | "running" | "completed" | "failed" | "cancelled" | string;
  progress: number;
  message?: string;
  title?: string;
  source_name?: string;
  source_size?: number | null;
  source_type?: string;
  source_url?: string | null;
  source_metadata?: Record<string, unknown> | null;
  partial_segments?: TranscriptSegment[];
  result?: {
    text?: string;
    language?: string;
    duration?: number;
    segments?: TranscriptSegment[];
  } | null;
  error?: string | null;
};

export type TranscriptionRecordSummary = {
  job_id: string;
  title?: string;
  status?: string;
  progress?: number;
  message?: string;
  source?: {
    name?: string;
    type?: string;
    size?: number | null;
    url?: string | null;
    metadata?: Record<string, unknown> | null;
  };
  result?: {
    segment_count?: number;
    text_length?: number;
    duration?: number;
  } | null;
  updated_at?: string;
  created_at?: string;
};

export type TranscriptionRecord = TranscriptionRecordSummary & {
  request?: Record<string, unknown>;
  transcript?: {
    text?: string;
    language?: string;
    duration?: number;
    segments?: TranscriptSegment[];
  } | null;
  article?: {
    text?: string;
    title?: string;
    updated_at?: string;
  } | null;
};
