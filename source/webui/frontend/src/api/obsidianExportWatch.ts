/** How long the unsaved queue keeps refetching after an Obsidian handoff. */
export const OBSIDIAN_EXPORT_WATCH_MS = 10 * 60 * 1000;

export type ObsidianExportWatch = {
  ids: string[];
  untilMs: number;
};

/** Start or extend a watch for the note ids in one export. */
export function startObsidianExportWatch(
  current: ObsidianExportWatch | null,
  ids: readonly string[] | undefined,
  nowMs: number,
  durationMs = OBSIDIAN_EXPORT_WATCH_MS
): ObsidianExportWatch {
  const incoming: string[] = [];
  for (const id of ids ?? []) {
    const cleaned = id.trim();
    if (cleaned && !incoming.includes(cleaned)) incoming.push(cleaned);
  }
  const untilMs = nowMs + durationMs;
  if (current && nowMs < current.untilMs) {
    const merged = [...current.ids];
    for (const id of incoming) {
      if (!merged.includes(id)) merged.push(id);
    }
    return { ids: merged, untilMs: Math.max(current.untilMs, untilMs) };
  }
  return { ids: incoming, untilMs };
}

export function obsidianExportWatchActive(watch: ObsidianExportWatch | null, nowMs: number): boolean {
  return Boolean(watch && nowMs < watch.untilMs);
}

export type ObsidianSaveStatus = {
  tone: "info" | "success" | "error";
  text: string;
};

/** Current handoff status for the in-page queue notice. */
export function obsidianSaveStatusText(
  watch: ObsidianExportWatch | null,
  pendingIds: readonly string[],
  nowMs: number
): ObsidianSaveStatus | null {
  if (!watch) return null;
  const pending = new Set(pendingIds);
  const remaining = watch.ids.filter((id) => pending.has(id));
  if (watch.ids.length > 0 && remaining.length === 0) {
    return { tone: "success", text: "Saved to Obsidian" };
  }
  if (nowMs >= watch.untilMs) {
    return { tone: "error", text: "AirType has not confirmed this save yet" };
  }
  if (remaining.length === 0) {
    return { tone: "info", text: "Waiting for AirType" };
  }
  const noun = remaining.length === 1 ? "note" : "notes";
  return { tone: "info", text: `Waiting for AirType · ${remaining.length} ${noun} still unsaved` };
}

/**
 * Stop watching once every exported id has left the pending queue.
 * An empty id list stays active until the deadline so a handoff with no ids
 * still refreshes for a bounded time. New pending ids do not keep the watch alive.
 */
export function settleObsidianExportWatch(
  watch: ObsidianExportWatch | null,
  pendingIds: readonly string[],
  nowMs: number
): ObsidianExportWatch | null {
  if (!watch || nowMs >= watch.untilMs) return null;
  if (watch.ids.length === 0) return watch;
  const pending = new Set(pendingIds);
  if (watch.ids.some((id) => pending.has(id))) return watch;
  return null;
}
