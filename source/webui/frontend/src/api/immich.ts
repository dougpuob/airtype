import { apiRequest } from "./client";

export type NoteMediaImage = {
  url: string;
  asset_id: string;
  status: "uploaded" | "remote";
  warning: string;
  embedded_url?: string;
};

export type NoteMediaResult = {
  images: NoteMediaImage[];
  share_url: string;
  album_id: string;
  warnings: string[];
};

export function uploadNoteMedia(input: { guid: string; urls: string[]; sourceUrl?: string; title?: string }) {
  return apiRequest<NoteMediaResult>("/api/immich/note-media", {
    method: "POST",
    body: JSON.stringify({
      guid: input.guid,
      urls: input.urls,
      source_url: input.sourceUrl || "",
      title: input.title || ""
    })
  });
}