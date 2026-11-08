import { useMutation, useQueryClient } from "@tanstack/react-query";
import { watchObsidianExport } from "./clipRequests";
import { apiRequest } from "./client";

export type ObsidianExportResult = {
  export_id: string;
  download_url: string;
  open_url: string;
  note_count: number;
  note_ids: string[];
};

/** Create a Local App import manifest for one id, several ids, or every ready note. */
export function createObsidianExport(ids?: string[]) {
  return apiRequest<ObsidianExportResult>("/api/obsidian-exports", {
    method: "POST",
    body: JSON.stringify(ids ? { ids } : {})
  });
}

/** Create the export and open `airtype://obsidian-import?url=…`. */
export async function handoffObsidianExport(ids?: string[]) {
  const result = await createObsidianExport(ids);
  watchObsidianExport();
  if (typeof window !== "undefined") {
    window.location.href = result.open_url;
  }
  return result;
}

export function useObsidianExportMutation() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (ids?: string[]) => handoffObsidianExport(ids),
    onSettled: () => {
      void queryClient.invalidateQueries({ queryKey: ["clip-requests"] });
    }
  });
}
