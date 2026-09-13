"use client";

import { usePathname, useSearchParams } from "next/navigation";
import { useEffect, useState } from "react";

function isInternalNavigation(event: MouseEvent, anchor: HTMLAnchorElement) {
  return (
    event.button === 0 &&
    !event.metaKey &&
    !event.ctrlKey &&
    !event.shiftKey &&
    !event.altKey &&
    anchor.target !== "_blank" &&
    anchor.download === ""
  );
}

export function NavigationFeedback() {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const routeKey = `${pathname}?${searchParams.toString()}`;
  const [pending, setPending] = useState(false);

  useEffect(() => {
    setPending(false);
  }, [routeKey]);

  useEffect(() => {
    const handleClick = (event: MouseEvent) => {
      const target = event.target;
      if (!(target instanceof Element)) {
        return;
      }
      const anchor = target.closest("a");
      if (
        !(anchor instanceof HTMLAnchorElement) ||
        !isInternalNavigation(event, anchor)
      ) {
        return;
      }
      const url = new URL(anchor.href);
      const locationChanged =
        url.pathname !== window.location.pathname ||
        url.search !== window.location.search;
      if (url.origin === window.location.origin && locationChanged) {
        setPending(true);
      }
    };

    document.addEventListener("click", handleClick);
    return () => document.removeEventListener("click", handleClick);
  }, [pathname]);

  return (
    <div
      className={`hud-route-progress${pending ? " hud-route-progress-visible" : ""}`}
      role="status"
      aria-label={pending ? "Loading page" : undefined}
      aria-hidden={!pending}
    />
  );
}
