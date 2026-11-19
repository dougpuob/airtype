import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { apiRequest } from "./client";

export type HistoryItem = {
  request_id: string;
  guid: string;
  url: string;
  title: string;
  kind: string;
  origin: string;
  status: string;
  message: string;
  created_at: string;
  finished_at: string;
  content_at: string;
};

export type HistoryPage = {
  items: HistoryItem[];
  total: number;
  page: number;
  page_size: number;
  pages: number;
  page_sizes: number[];
};

export function useHistoryQuery(query: string, page: number, pageSize: number) {
  const params = new URLSearchParams({
    q: query,
    page: String(page),
    page_size: String(pageSize)
  });
  return useQuery({
    queryKey: ["history", query, page, pageSize],
    placeholderData: keepPreviousData,
    queryFn: () => apiRequest<HistoryPage>(`/api/history?${params.toString()}`)
  });
}
