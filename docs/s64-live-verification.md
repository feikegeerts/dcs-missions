# §6.4 live verification runbook (aircraft allowance / escalation / messages)

Closes the parked queue item `s64-live-verification`. §6.4 (per-identity aircraft,
wave escalation, in-fiction messages) is implemented and **offline-verified**
(unit tests + line-by-line review); what remains is a live human-in-seat pass to
confirm the behaviour against real player slots and real player deaths.

## Why this is human-in-seat

An aircraft is consumed by a real player loss (`Dead`, `Crash`, or `Ejection`)
on a blue player slot. `PlayerLeaveUnit` only releases the slot after the loss;
the matching loss callbacks are deduplicated. `TEST_COMBAT` spawns AI blue and
drives its own wave logic (it bypasses `spawnWave` and uses no player slots), so
it does **not** exercise §6.4. This pass therefore needs at least one human in
an `Aerial-*` seat who can actually lose aircraft.

## Setup

1. **Server** — dedicated server on the `Saved Games\DCS.dcs_serverrelease`
   profile, or full-client SP with `LeftShift+R`.
   - For the §6.4 logic alone, the **development loader** (de-sanitized
     `MissionScripting.lua`, dynamic `src/` load) lets you tweak the knobs
     without repacking. To validate exact shipping behaviour, load the
     self-contained shipping `.miz` on a **stock** (sanitized) server instead.
2. **Knobs** — `src/missions/duel-dynamic/main.lua`:
    `aircraft_per_player = 3` (legacy `lives_per_player` is accepted),
    `WAVE_ESCALATION_EVERY = 3`,
   `MAX_PACKAGE_SIZE = 8`, `WAVE_TIER_EVERY = 3` with `WAVE_DONOR_TIERS`
   (waves 1–3: `Bandit-10`/`Bandit-3`/`Bandit-6`; waves 4–6:
   `Bandit-3`/`Bandit-6`/`Bandit-4`/`Bandit-5`; waves 7+:
   `Bandit-1`/`Bandit-2`/`Bandit-4`/`Bandit-5`/`Bandit-8`/`Bandit-9`;
   `Bandit-7` excluded).
3. **Tacview** (optional, recommended for multi-player geometry) —
   `spec-duel-dynamic.md §9`.
4. **Tail the log** — `Saved Games\DCS.dcs_serverrelease\Logs\dcs.log`
   (timestamps are UTC).

## In-fiction messages (exact strings; all use an em-dash `—`)

| Event | In-game message (BLUE coalition) |
|---|---|
| Wave spawns | `Wave N — K hostiles inbound` (singular `hostile` when K=1) |
| Player loses an aircraft, aircraft remain | `Aircraft lost — N aircraft remaining.` |
| Player loses last aircraft | `Aircraft lost — out of aircraft.` |
| Zero-aircraft identity re-enters any slot | `Out of aircraft — excluded from the package.` |
| All identities at zero | `All aircraft lost — mission ending in 60 seconds.` |
| Bandit killed | `Bandit down — team T, K hostiles left` |
| F10 forced reset, new wave | `New bandit wave inbound.` (else `No players in the air.`) |
| F10 forced reset after terminal | `Mission over — no more waves.` |

**Primary live check — F10 `Air Superiority Survival` → `Show aircraft remaining`:** posts
the current per-identity aircraft table to the BLUE coalition:

```
Aircraft remaining:
  <player name>: 2
  <player name>: 3
```

(`No players yet.` when empty.) Use this to confirm live counts at every step
instead of relying on chat timing. The same F10 menu has **`Respawn bandit
wave`**, which force-spawns the next wave immediately — use it to drive the
escalation cadence (T6) without waiting 30 s between waves.

## Key log anchors (`dcs.log`)

- init: `[duel-dynamic] main start` … `[duel-dynamic] init done — package-wave lifecycle active`
- player join: `[duel-dynamic] player '<name>' entered <slot>`
- UCID fallback (once only, if `IniPlayerUCID` is absent): `[duel-dynamic] player UCID unavailable — using the slot group name as the per-run identity`
- spawn: `[duel-dynamic] spawning K-ship package … (<reason>, donor <X> tier <N>, alt … ft, speed … kt, escalation +E)` — the `escalation +E` suffix appears from wave 4 onward; the `tier <N>` names the difficulty tier (1 for waves 1–3, 2 for waves 4–6, 3 for waves 7+)
- wave defeated: `[duel-dynamic] wave N defeated — next package in 30s`
- terminal: `[duel-dynamic] all tracked player identities are out of aircraft — ending DCS mission in 60 seconds`
- post-terminal spawn suppression: `[duel-dynamic] mission terminal — spawn request ignored (<reason>)` / `mission terminal — wave schedule ignored (<reason>)`
- post-terminal Blue slot rejection: `TELEMETRY_BRIDGE_HOOK ... blue-slot-policy=blocked ...` and `blue-slot-rejected ...`

## Identity model

- **Identity** = the player's UCID (`EventData.IniPlayerUCID`) when present;
  otherwise the slot group name (`Aerial-1`…`Aerial-5`) with the one-time
  warning above.
- **Aircraft allowance is per mission run**: a restart (`LeftShift+R` / WebGUI restart /
  `net.load_mission`) resets every identity to 3 aircraft and `waveNumber` to 0.
- **Reconnect keeps aircraft**: re-entering with the *same identity* (same UCID, or
  the same slot under the fallback) keeps the current count — it is **not**
  reset to 3.

## Test cases

**T1 — baseline wave size (1 player).** One human in `Aerial-1`.
Expected: wave 1 spawns a 1-ship package (log `spawning 1-ship package …`).
F10 `Show aircraft remaining` shows the identity at `3`.

**T2 — one aircraft removed per real loss (Dead/Crash/Ejection dedup).** Get the
player killed once. Expected: exactly one aircraft removed → F10 `2`; in-game
`Aircraft lost — 2 aircraft remaining.` A single loss must produce exactly
**one** decrement despite the callback pair. Re-enter the same native slot and
lose the replacement aircraft: DCS may reuse `Aerial-*-1`, but its distinct
incarnation must consume another aircraft.

**T3 — UCID identity.** Check the log for the one-time UCID warning. Present →
identity is the slot name (fallback); absent → UCID identity is in use. Record
which, since it keys reconnect. (Residual risk: `IniPlayerUCID` availability on
this dedicated-server build is unproven; the slot fallback covers its absence.)

**T4 — reconnect keeps aircraft.** After T2 (2 aircraft left), the player leaves
the slot and re-enters the same slot (same identity). Expected: F10 still shows
`2` (**not** reset to 3). If the identity has 0 aircraft at re-entry, expect
`Out of aircraft — excluded from the package.` and exclusion from
sizing instead.

**T5 — zero-aircraft exclusion from package sizing.** Bring one player to 0
aircraft (3 losses) while another still has aircraft. Expected: the zero-aircraft identity
contributes 0 to the next package size (size is based on the other player(s)
only), and on re-entry shows `Out of aircraft — excluded from the package.`

**T6 — escalation cadence.** With a fixed N live players, watch successive wave
sizes (force them with F10 `Respawn bandit wave`). Expected size =
`min(N + floor(waveNumber/3), 8)` where `waveNumber` is the number of waves
already spawned (the 1st wave has `waveNumber = 0`, so `extra = 0`):

| N players | wave sizes (1st, 2nd, 3rd, …) |
|---|---|
| 1 | 1,1,1,2,2,2,3,3,3,4,4,4,5,… (cap 8) |
| 2 | 2,2,2,3,3,3,4,4,4,5,… |
| 4 | 4,4,4,5,5,5,6,6,6,7,7,7,8 (cap hit at wave 13) |
| 5 | 5,5,5,6,6,6,7,7,7,8 (cap hit at wave 10) |

The `escalation +E` log suffix appears starting at wave 4 (E=1) and steps up
every 3 waves.

**T6b — tiered donor progression.** With any fixed N live players, force waves
with F10 `Respawn bandit wave` and check the `donor <X> tier <N>` log token
per wave: waves 1–3 donors are only `Bandit-10`/`Bandit-3`/`Bandit-6`
(tier 1); waves 4–6 only `Bandit-3`/`Bandit-6`/`Bandit-4`/`Bandit-5`
(tier 2); waves 7+ only `Bandit-1`/`Bandit-2`/`Bandit-4`/`Bandit-5`/
`Bandit-8`/`Bandit-9` (tier 3, fewer if a Su-33 spawner failed to
initialize). `Bandit-7` must never appear as a donor. Package sizes still
follow the T6 formula — tiers change only the donor pool, not the size.

**T7 — terminal state.** Drive **all** tracked identities to 0 aircraft.
Expected: one `All aircraft lost — mission ending in 60 seconds.` message, log
`… out of aircraft — ending DCS mission in 60 seconds`, and **no further package
spawns**. The current red wave remains for 60 seconds. The installed server
hook rejects subsequent Blue native slot changes, then the mission ends with
Blue as the survival winner. F10 `Respawn bandit wave` reports
`Mission over — no more waves.`

**T8 (optional) — multi-player geometry.** 2–5 players; inspect in Tacview: one
red group per wave, aircraft in formation, red lead 55–85 sm from the blue
centroid (`spec-duel-dynamic.md §9`).

## Reset between tests

- `LeftShift+R` (SP) or WebGUI restart / `net.load_mission` resets aircraft to 3
  and `waveNumber` to 0.
- WebGUI force-slot / kick-to-slot controls (or the in-mission slot selector)
  add/remove players mid-mission.

## Known residual risks to watch

- **(a)** Loss deduplication now keys the MOOSE event's native DCS object ID as
  well as its unit name. The 2026-09-14 live log confirmed that native re-entry
  reused `Aerial-1-1` while assigning a new object ID to each aircraft. If a
  future DCS/MOOSE build omits that documented object ID, the loss is logged and
  ignored rather than risking a duplicate decrement.
- **(b)** Live availability of `EventData.IniPlayerUCID` on this dedicated-server
  build is unproven; the slot-name fallback covers absence (one-time warning).
- **(c)** The GameGUI hook must be installed and loaded for native Blue slot
  rejection; mission-side events alone are too late (`spec-duel-dynamic.md §6.6`).

## PASS / FAIL

- **PASS:** T1–T7 all match the expected behaviour (including the T6b tier
  progression: correct tier token per wave, `Bandit-7` never a donor);
  F10 `Show aircraft remaining` counts never drift from observed losses; exactly
  one decrement per aircraft; terminal suppresses all further spawns and Blue
  slot requests.
- **FAIL:** any of — a single loss removes more/less than one aircraft; a
  reconnect resets a non-zero identity to 3; a zero-aircraft identity contributes
  to package size; a spawn occurs after terminal; or a same-human reconnect
  (same UCID) gets fresh aircraft.

On PASS, record the run in `progress.md` and flip queue item
`s64-live-verification` to `completed` with the run key and evidence.
