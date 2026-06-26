import { useQuery } from "@tanstack/react-query";
import { apiRequest } from "./client";
import type { AppSettings } from "../types/settings";

export function useSettingsQuery() {
  return useQuery({
    queryKey: ["settings"],
    queryFn: async () => {
      const payload = await apiRequest<{ settings: AppSettings }>("/api/settings");
      return payload.settings;
    }
  });
}
