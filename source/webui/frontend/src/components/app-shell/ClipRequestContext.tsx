import { createContext, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useClipRequestDetailQuery, useClipRequestsQuery, type ClipRequest } from "../../api/clipRequests";

type ClipRequestContextValue = {
  requests: ClipRequest[];
  selectedId: string;
  /** Selected request; the full record once it has loaded, else the list summary. */
  selected: ClipRequest | null;
  /** True while the full record of the selected request is loading. */
  selectedLoading: boolean;
  select: (id: string) => void;
};

const ClipRequestContext = createContext<ClipRequestContextValue | null>(null);

export function ClipRequestProvider({ children }: { children: ReactNode }) {
  const query = useClipRequestsQuery();
  const requests = query.data || [];
  const [selectedId, setSelectedId] = useState("");
  const seenIds = useRef(new Set<string>());

  function select(id: string) {
    setSelectedId(id);
  }

  useEffect(() => {
    requests.forEach((item) => seenIds.current.add(item.id));
    if (!selectedId) {
      const next = requests.find((item) => item.status === "completed") || requests[0];
      if (next) setSelectedId(next.id);
      return;
    }
    if (requests.some((item) => item.id === selectedId)) return;
    if (!seenIds.current.has(selectedId)) return;
    const next = requests.find((item) => item.status === "completed") || requests[0];
    setSelectedId(next?.id || "");
  }, [requests, selectedId]);

  const selectedSummary = useMemo(
    () => requests.find((item) => item.id === selectedId) || null,
    [requests, selectedId]
  );
  // Opening (selecting) a request loads its full body; the list only has summaries.
  const detail = useClipRequestDetailQuery(selectedSummary);
  const selected = useMemo(() => {
    if (!selectedSummary) return null;
    const full = detail.data;
    if (full && full.id === selectedSummary.id) return { ...selectedSummary, ...full, summary: false };
    return selectedSummary;
  }, [selectedSummary, detail.data]);
  const selectedLoading = detail.isFetching && !detail.data;

  const value = useMemo(
    () => ({
      requests,
      selectedId,
      selected,
      selectedLoading,
      select
    }),
    [requests, selected, selectedId, selectedLoading]
  );

  return <ClipRequestContext.Provider value={value}>{children}</ClipRequestContext.Provider>;
}

export function useClipRequestSelection() {
  const context = useContext(ClipRequestContext);
  if (!context) throw new Error("useClipRequestSelection must be used inside ClipRequestProvider");
  return context;
}
