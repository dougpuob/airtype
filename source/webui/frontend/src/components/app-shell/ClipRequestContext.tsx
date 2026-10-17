import { createContext, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useClipRequestsQuery, type ClipRequest } from "../../api/clipRequests";

type ClipRequestContextValue = {
  requests: ClipRequest[];
  selectedId: string;
  selected: ClipRequest | null;
  select: (id: string) => void;
};

const ClipRequestContext = createContext<ClipRequestContextValue | null>(null);

export function ClipRequestProvider({ children }: { children: ReactNode }) {
  const query = useClipRequestsQuery();
  const requests = query.data || [];
  const [selectedId, setSelectedId] = useState("");
  const seenIds = useRef(new Set<string>());

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

  const selected = useMemo(
    () => requests.find((item) => item.id === selectedId) || null,
    [requests, selectedId]
  );

  const value = useMemo(
    () => ({
      requests,
      selectedId,
      selected,
      select: setSelectedId
    }),
    [requests, selected, selectedId]
  );

  return <ClipRequestContext.Provider value={value}>{children}</ClipRequestContext.Provider>;
}

export function useClipRequestSelection() {
  const context = useContext(ClipRequestContext);
  if (!context) throw new Error("useClipRequestSelection must be used inside ClipRequestProvider");
  return context;
}
