import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
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

export function useUpdateSettingsMutation() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (settings: AppSettings) => {
      const payload = await apiRequest<{ settings: AppSettings }>("/api/settings", {
        method: "PUT",
        body: JSON.stringify({ settings })
      });
      return payload.settings;
    },
    onSuccess: (settings) => {
      queryClient.setQueryData(["settings"], settings);
      queryClient.invalidateQueries({ queryKey: ["settings"] });
      queryClient.invalidateQueries({ queryKey: ["auth-status"] });
    }
  });
}
