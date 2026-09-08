"use client";

import { useEffect, useRef, useTransition } from "react";
import { useRouter } from "next/navigation";

import {
  advanceRefreshSchedule,
  createRefreshSchedule,
  type RefreshClock,
  type RefreshScheduleEvent,
  type RefreshScheduleState,
  type RefreshVisibility,
} from "@/telemetry/refresh-schedule";
import type { DisplayRunStatus } from "@/telemetry/run-status";

const browserClock: RefreshClock = { now: () => Date.now() };

export interface AutoRefreshProps {
  displayStatus: DisplayRunStatus | null;
  renderToken: number;
}

export function AutoRefresh({ displayStatus, renderToken }: AutoRefreshProps) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();
  const initial = useRef(
    createRefreshSchedule(displayStatus, "visible", browserClock).state,
  );
  const stateRef = useRef<RefreshScheduleState>(initial.current);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const processEventRef = useRef<(event: RefreshScheduleEvent) => void>(
    () => undefined,
  );
  const renderTokenRef = useRef(renderToken);
  const refreshSawRenderRef = useRef(false);
  const refreshSawPendingRef = useRef(false);

  processEventRef.current = (event) => {
    let outcome = advanceRefreshSchedule(stateRef.current, event, browserClock);

    while (true) {
      stateRef.current = outcome.state;
      if (timerRef.current !== null) {
        clearTimeout(timerRef.current);
        timerRef.current = null;
      }

      if (outcome.refreshNow) {
        refreshSawRenderRef.current = false;
        refreshSawPendingRef.current = false;
        try {
          startTransition(() => router.refresh());
        } catch {
          outcome = advanceRefreshSchedule(
            stateRef.current,
            { type: "settled", succeeded: false },
            browserClock,
          );
          continue;
        }
      }

      if (outcome.scheduleTimer) {
        timerRef.current = setTimeout(
          () => processEventRef.current({ type: "timer" }),
          outcome.nextDelayMs,
        );
      }
      break;
    }
  };

  useEffect(() => {
    processEventRef.current({ type: "status", displayStatus });
  }, [displayStatus]);

  useEffect(() => {
    if (renderToken !== renderTokenRef.current) {
      renderTokenRef.current = renderToken;
      refreshSawRenderRef.current = true;
    }
    if (isPending) {
      refreshSawPendingRef.current = true;
      return;
    }
    if (
      stateRef.current.inFlight &&
      (refreshSawPendingRef.current || refreshSawRenderRef.current)
    ) {
      processEventRef.current({
        type: "settled",
        succeeded: refreshSawRenderRef.current,
      });
    }
  }, [isPending, renderToken]);

  useEffect(() => {
    const visibility = (): RefreshVisibility =>
      document.visibilityState === "hidden" ? "hidden" : "visible";
    const onVisibilityChange = () =>
      processEventRef.current({
        type: "visibility",
        visibility: visibility(),
      });
    const onFocus = () => processEventRef.current({ type: "focus" });
    const onOnline = () => processEventRef.current({ type: "online" });

    onVisibilityChange();
    window.addEventListener("focus", onFocus);
    window.addEventListener("online", onOnline);
    document.addEventListener("visibilitychange", onVisibilityChange);

    return () => {
      if (timerRef.current !== null) {
        clearTimeout(timerRef.current);
        timerRef.current = null;
      }
      window.removeEventListener("focus", onFocus);
      window.removeEventListener("online", onOnline);
      document.removeEventListener("visibilitychange", onVisibilityChange);
    };
  }, []);

  return null;
}
