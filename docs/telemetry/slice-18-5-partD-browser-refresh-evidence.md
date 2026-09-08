# Slice 18.5 part D — browser refresh evidence

Date: 2026-09-07

Status: offline-complete; live browser verification remains in S18.5-e.

## Mechanism and lifecycle reasoning

All five public dashboard pages remain server components and continue reading
`NeonTelemetryStore` directly. Each renders one small `AutoRefresh` client
component. That component calls only `router.refresh()`: it does not call a
public API, navigate, reload, assign `window.location`, or key/remount page
content. Therefore each refresh re-runs the current server component at the
same URL. Existing classification/status filters, `runsPage`/`eventsPage`, and
the player search query remain in `searchParams`; no changed code clears them
or scroll/client input state.

The installed Next declaration at
`web/node_modules/next/dist/shared/lib/app-router-context.shared-runtime.d.ts`
declares `refresh(): void` (line 108). It is not awaitable. `AutoRefresh`
therefore wraps `router.refresh()` in React 19 `startTransition`, holds an
explicit in-flight flag in the pure schedule state, and allows no timer or
focus/online/visibility event to issue another refresh until the transition
settles. A changing server-generated `renderToken` distinguishes a successful
RSC render from a transition that settles without a new tree. Success resets
the failure count; a failed settle advances exponential backoff to the 60 s
cap. The previous server tree is not copied into client state or cleared.
Page-level database catches now rethrow, rather than returning a successful
"database unavailable" replacement tree during a refresh, so the router can
retain the last successful tree when an RSC pass errors.

`refresh-schedule.ts` owns cadence, visibility gating, immediate-event,
single-flight, and failure-backoff decisions. It has no ambient clock access:
creation and transitions require a `RefreshClock`. The browser component is
only timer/event/transition wiring. It clears the one timer before processing
every decision and on unmount, then schedules at most one replacement timer.
Status and visibility changes consequently reschedule rather than accumulate
timers. Hidden active views use the slow tier, while returning to visible,
focus, and reconnect (`online`) request an immediate single-flight refresh.

The owner-tunable exports are:

- `AGGRESSIVE_REFRESH_INTERVAL_MS = 2000`
- `SLOW_REFRESH_INTERVAL_MS = 30000`
- `MAX_REFRESH_BACKOFF_MS = 60000`

Every successful or failed settle produces a finite next delay. Stale,
aborted, ended, empty, hidden-active, and both players views continue polling
at the slow tier; polling never intentionally terminates for a terminal-looking
display state.

## Page wiring

| Page | Status source passed to `AutoRefresh` | Normal tier |
|---|---|---|
| `/` | Existing latest in-scope run and existing `latestDisplay` derivation | 2 s only for `active`; otherwise 30 s |
| `/missions/[missionName]` | First/latest run in the mission's updated-at-ordered scoped list, using its existing per-run display derivation | 2 s only for `active`; otherwise 30 s |
| `/runs/[runId]` | Displayed run, derived with unchanged `displayRunStatus` | 2 s only for `active`; otherwise 30 s; not-found is 30 s |
| `/players` | No run status (`null`) | Always 30 s |
| `/players/[playerId]` | No run status (`null`) | Always 30 s, including not-found |

`web/src/telemetry/run-status.ts` and its 10-minute
`STALE_AFTER_MS` threshold were not changed.

## Query-cost measurement

A refresh performs the same server render and store calls as initial load. The
refresh component itself performs zero store calls and adds no API fetch.
Inspection gives these per-render query counts, where `N` and `M` are scoped
run counts described below:

| Page | Store queries per refresh |
|---|---|
| `/` | **1**: `listRuns` |
| `/missions/[missionName]` | **1 + 4N**, where N is the number of runs matching mission, classification, and status filters: one `listRuns`, then expenditures, losses, kills, and participants for every matching run |
| `/runs/[runId]` | **7** for a found run: `getRunByRunKey` plus six parallel fact reads; **1** if not found |
| `/players` | **1 + N**, where N is the selected classification's run count: one `listRuns` and participants once per run |
| `/players/[playerId]` | **1 + N + 6M**, where N is the selected classification's run count and M is runs containing the resolved pilot: directory participant reads plus six detailed reads per matching run |

`home-refresh-query-cost.test.ts` executes the home server component twice with
a counting store. It proves exactly one `listRuns` call for each render (one
after initial render, two after the second render), hence zero additional store
queries from refresh wiring.

A visible active browser schedules about 30 refreshes/minute at 2 s, so its
load is approximately `30 × page-query-count` queries/minute. The requested
slow-tier planning approximation was about 1 refresh/minute; the exact steady
state of the pinned 30 s interval is about 2 refreshes/minute, or
`2 × page-query-count`, before transition duration and browser throttling.

### Cache verification

This was checked against the actual configuration and installed Next runtime,
not inferred solely from the plan:

- all five pages still export `dynamic = "force-dynamic"`;
- the production build labels all five routes `ƒ (Dynamic) server-rendered on
  demand`, rather than static;
- installed Next 15.5.25 code in
  `dist/server/app-render/create-component-tree.js` sets `workStore.forceDynamic`
  for that export and rejects a static pathway;
- installed Next cache-header code in `dist/server/lib/cache-control.js` maps
  dynamic `revalidate: 0` responses to
  `private, no-cache, no-store, max-age=0, must-revalidate`;
- the existing public telemetry GET routes remain `force-dynamic`; no route was
  added or changed.

Thus the RSC refresh is a dynamic, no-store response and is not reusable from
the browser HTTP cache. No live HTTP request/header capture was made because
this part was explicitly offline and prohibited network/API calls; that browser
observation remains in S18.5-e.

## Test-to-exit map

| Exit concern | Offline evidence | Remaining live evidence |
|---|---|---|
| Browser disconnect/reconnect and focus | Pure tests assert `online` and `focus` immediate decisions and in-flight suppression | Dispatch real browser events and observe one RSC request/catch-up |
| Hidden/visible | Pure test proves hidden active changes to 30 s and suppresses the old aggressive tick; restore is immediate | Browser timer throttling/devtools request timing |
| Navigation and preserved filters/pagination/scroll | Inspection proves only `router.refresh()` at the same URL and effect cleanup removes timer/listeners; no key/navigation/reset code | Navigate among all pages and confirm scroll/input behavior |
| Slow request/single flight | Pure test rejects timer, focus, online, and visibility refresh decisions while in flight | Throttle an RSC request and confirm only one network request |
| Failure/backoff/last good data | Pure tests prove 4/8/16/32/60/60 s active failure delays, finite rescheduling, and success reset; inspection proves no client replacement state and RSC errors are rethrown | Force a browser RSC failure and visually confirm old tree remains |
| Late final facts/stale resume | Tests prove stale/ended/aborted/empty retain 30 s finite schedules and active/stale tier transitions reschedule | Deliver late final facts and resume a stale run against hosted data |
| Honest active gate | Tests cover all display statuses; pages pass server-derived display status using unchanged threshold | Observe active-to-stale and stale-to-active timing in a real run |
| Query cost | Counting-store test plus per-page call-site inspection above | Measure render duration and hosted database load at concurrency |

Node-only Vitest does not claim real scroll preservation, actual RSC patching,
browser event delivery, request headers, or live 2 s timing. Those are explicit
S18.5-e leftovers.

## File-set audit

Final `git status --porcelain` output after the acceptance battery:

```text
 M .gitignore
 M collector/package.json
 M collector/src/cli.ts
 M collector/src/collector.ts
 M collector/src/delivery-cli.ts
 M collector/src/spool.ts
 M docs/telemetry/slice-18-5-near-live-plan.md
 M web/src/app/missions/[missionName]/page.tsx
 M web/src/app/page.tsx
 M web/src/app/players/[playerId]/page.tsx
 M web/src/app/players/page.tsx
 M web/src/app/runs/[runId]/page.tsx
 M web/src/telemetry/expenditures.ts
 M web/tests/expenditures.test.ts
?? collector/src/ownership.ts
?? collector/src/service.ts
?? collector/tests/ownership.test.ts
?? collector/tests/service-collection.test.ts
?? collector/tests/service.test.ts
?? docs/telemetry/slice-18-5-partA-persistent-collection-evidence.md
?? docs/telemetry/slice-18-5-partD-browser-refresh-evidence.md
?? web/src/components/auto-refresh.tsx
?? web/src/telemetry/refresh-schedule.ts
?? web/tests/home-refresh-query-cost.test.ts
?? web/tests/refresh-schedule.test.ts
```

Pre-existing owner/orchestrator work, including the frozen
`web/src/telemetry/expenditures.ts` and `web/tests/expenditures.test.ts`, was
left untouched by this task.

## Residual risks

- React transition settlement and last-tree retention are verified by type and
  lifecycle inspection plus pure scheduling tests, not a DOM/browser harness.
- A browser process or request that never settles intentionally remains
  single-flight rather than issuing an overlapping request. Real network
  timeout behavior must be observed in S18.5-e.
- Mission/player dossier query fan-out is unchanged and can be expensive at
  larger public concurrency; no compact read/cache/schema work was in scope.
- Millisecond render tokens are generated server-side. Normal 2 s/30 s refresh
  spacing makes collision negligible, but live transition observation remains
  part of S18.5-e.
