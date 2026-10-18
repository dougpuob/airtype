import { useQuery } from "@tanstack/react-query";
import { apiRequest } from "./client";

export type SiteStats = {
  site: string;
  total: number;
  completed: number;
  failed: number;
  cancelled: number;
  other: number;
  success_rate: number | null;
};

export type FailureReason = { reason: string; count: number; sites: Record<string, number> };

export type RecentCapture = {
  id: string;
  kind: string;
  site: string;
  title: string;
  url: string;
  status: string;
  error: string;
  created_at: string;
};

export type TokenBucket = {
  calls: number;
  prompt_tokens: number;
  completion_tokens: number;
  total_tokens: number;
  input_chars: number;
  output_chars: number;
};

export type UsageStats = {
  generated_at: string;
  days: number;
  captures: {
    total: number;
    completed: number;
    failed: number;
    cancelled: number;
    other: number;
    success_rate: number | null;
    first_capture_at: string | null;
    by_site: SiteStats[];
    failure_reasons: FailureReason[];
    by_day: { date: string; count: number }[];
    by_week: { week: string; count: number }[];
    recent: RecentCapture[];
  };
  ime: {
    count: number;
    total_duration_seconds: number;
    total_chars: number;
    by_day: { date: string; count: number }[];
  };
  llm: {
    logged_since: string | null;
    totals: TokenBucket & { failed_calls: number; calls_without_usage: number; duration_ms: number };
    by_step: (TokenBucket & { step: string })[];
    by_model: (TokenBucket & { model: string })[];
    by_day: (TokenBucket & { date: string })[];
    historical_estimate: { is_estimate: boolean; note: string; captures: number; input_chars: number };
  };
};

export function useUsageStatsQuery(days = 30) {
  return useQuery({
    queryKey: ["usage-stats", days],
    refetchInterval: 60_000,
    queryFn: async () => apiRequest<UsageStats>(`/api/stats?days=${days}`)
  });
}
