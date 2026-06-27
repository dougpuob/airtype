import { createContext, type PropsWithChildren, useCallback, useContext, useEffect, useMemo, useRef, useState } from "react";
import {
  Button,
  Dialog,
  DialogActions,
  DialogContent,
  DialogContentText,
  DialogTitle
} from "@mui/material";

type GuardedWork = {
  id: string;
  label?: string;
  isActive: boolean;
  onConfirmLeave?: () => Promise<void> | void;
};

type PendingLeave = {
  action: () => void;
};

type WorkGuardContextValue = {
  hasActiveWork: boolean;
  requestLeave: (action: () => void) => void;
  registerWork: (work: GuardedWork) => () => void;
};

const WorkGuardContext = createContext<WorkGuardContextValue | null>(null);

export function WorkGuardProvider({ children }: PropsWithChildren) {
  const [workItems, setWorkItems] = useState<Map<string, GuardedWork>>(() => new Map());
  const [pendingLeave, setPendingLeave] = useState<PendingLeave | null>(null);
  const [confirming, setConfirming] = useState(false);
  const currentHashRef = useRef(typeof window === "undefined" ? "" : window.location.hash);
  const allowNextHashChangeRef = useRef(false);

  const activeWork = useMemo(() => Array.from(workItems.values()).filter((work) => work.isActive), [workItems]);
  const hasActiveWork = activeWork.length > 0;

  const registerWork = useCallback((work: GuardedWork) => {
    setWorkItems((current) => {
      const next = new Map(current);
      next.set(work.id, work);
      return next;
    });

    return () => {
      setWorkItems((current) => {
        const next = new Map(current);
        next.delete(work.id);
        return next;
      });
    };
  }, []);

  const requestLeave = useCallback(
    (action: () => void) => {
      if (!hasActiveWork) {
        action();
        return;
      }
      setPendingLeave({ action });
    },
    [hasActiveWork]
  );

  useEffect(() => {
    if (!hasActiveWork) return;

    function handleBeforeUnload(event: BeforeUnloadEvent) {
      event.preventDefault();
      event.returnValue = "";
    }

    window.addEventListener("beforeunload", handleBeforeUnload);
    return () => window.removeEventListener("beforeunload", handleBeforeUnload);
  }, [hasActiveWork]);

  useEffect(() => {
    function handleHashChange() {
      const nextHash = window.location.hash;
      if (allowNextHashChangeRef.current) {
        allowNextHashChangeRef.current = false;
        currentHashRef.current = nextHash;
        return;
      }

      if (!hasActiveWork) {
        currentHashRef.current = nextHash;
        return;
      }

      const previousHash = currentHashRef.current;
      if (nextHash === previousHash) return;

      allowNextHashChangeRef.current = true;
      window.location.hash = previousHash;
      setPendingLeave({
        action: () => {
          allowNextHashChangeRef.current = true;
          window.location.hash = nextHash;
        }
      });
    }

    window.addEventListener("hashchange", handleHashChange);
    return () => window.removeEventListener("hashchange", handleHashChange);
  }, [hasActiveWork]);

  async function confirmLeave() {
    if (!pendingLeave) return;
    setConfirming(true);
    const workToStop = activeWork;
    try {
      await Promise.all(workToStop.map((work) => work.onConfirmLeave?.()));
    } finally {
      const action = pendingLeave.action;
      setConfirming(false);
      setPendingLeave(null);
      allowNextHashChangeRef.current = true;
      action();
    }
  }

  const value = useMemo(
    () => ({ hasActiveWork, requestLeave, registerWork }),
    [hasActiveWork, requestLeave, registerWork]
  );

  return (
    <WorkGuardContext.Provider value={value}>
      {children}
      <Dialog open={Boolean(pendingLeave)} onClose={confirming ? undefined : () => setPendingLeave(null)} maxWidth="xs" fullWidth>
        <DialogTitle>Interrupt Current Work?</DialogTitle>
        <DialogContent>
          <DialogContentText>
            AirType is still processing. Leaving now will stop the current work and keep the latest saved page state.
          </DialogContentText>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setPendingLeave(null)} disabled={confirming}>
            Stay
          </Button>
          <Button color="error" variant="contained" onClick={() => void confirmLeave()} disabled={confirming}>
            {confirming ? "Stopping..." : "Stop and Leave"}
          </Button>
        </DialogActions>
      </Dialog>
    </WorkGuardContext.Provider>
  );
}

export function useWorkGuard() {
  const context = useContext(WorkGuardContext);
  if (!context) throw new Error("useWorkGuard must be used inside WorkGuardProvider");
  return context;
}

export function useGuardedWork(work: GuardedWork) {
  const { registerWork } = useWorkGuard();
  const workRef = useRef(work);
  workRef.current = work;

  useEffect(
    () =>
      registerWork({
        ...work,
        onConfirmLeave: () => workRef.current.onConfirmLeave?.()
      }),
    [registerWork, work.id, work.label, work.isActive]
  );
}
