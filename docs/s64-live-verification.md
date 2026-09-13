# §6.4 live verification runbook (player lives / escalation / messages)

Closes the parked queue item `s64-live-verification`. §6.4 (per-identity lives,
wave escalation, in-fiction messages) is implemented and **offline-verified**
(unit tests + line-by-line review); what remains is a live human-in-seat pass to
confirm the behaviour against real player slots and real player deaths.

## Why this is human-in-seat

A *life* is only consumed by a real player **death** (a `Dead`/`Crash` event on
a blue player slot). Ejecting is a *leave* (`PlayerLeaveUnit`) — it releases the
slot **without** consuming a life. `TEST_COMBAT` spawns AI blue and drives its
own wave logic (it bypasses `spawnWave` and uses no player slots), so it does
**not** exercise §6.4. This pass therefore needs at least one human in an
`Aerial-*` seat who can actually die.

## Setup

1. **Server** — dedicated server on the `Saved Games\DCS.dcs_serverrelease`
   profile, or full-client SP with `LeftShift+R`.
   - For the §6.4 logic alone, the **development loader** (de-sanitized
     `MissionScripting.lua`, dynamic `src/` load) lets you tweak the knobs
     without repacking. To validate exact shipping behaviour, load the
     self-contained shipping `.miz` on a **stock** (sanitized) server instead.
2. **Knobs** — `src/missions/duel-dynamic/main.lua` lines 222–224:
   `LIVES_PER_PLAYER = 3`, `WAVE_ESCALATION_EVERY = 3`,
   `MAX_PACKAGE_SIZE = 8`.
3. **Tacview** (optional, recommended for multi-player geometry) —
   `spec-duel-dynamic.md §9`.
4. **Tail the log** — `Saved Games\DCS.dcs_serverrelease\Logs\dcs.log`
   (timestamps are UTC).

## In-fiction messages (exact strings; all use an em-dash `—`)

| Event | In-game message (BLUE coalition) |
|---|---|
| Wave spawns | `Wave N — K hostiles inbound` (singular `hostile` when K=1) |
| Player loses an aircraft, lives remain | `Aircraft lost — N lives left.` / `Aircraft lost — 1 life left.` |
| Player loses last life | `Aircraft lost — out of lives.` |
| Zero-life identity re-enters any slot | `Out of lives — excluded from the package.` |
| All identities at zero | `All pilots down — mission over.` |
| Bandit killed | `Bandit down — team T, K hostiles left` |
| F10 forced reset, new wave | `New bandit wave inbound.` (else `No players in the air.`) |
| F10 forced reset after terminal | `Mission over — no more waves.` |

**Primary live check — F10 `Duel Dynamic` → `Show lives`:** posts the current
per-identity life table to the BLUE coalition:

```
Lives:
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
- spawn: `[duel-dynamic] spawning K-ship package … (<reason>, donor <X>, alt … ft, speed … kt, escalation +E)` — the `escalation +E` suffix appears from wave 4 onward
- wave defeated: `[duel-dynamic] wave N defeated — next package in 30s`
- terminal: `[duel-dynamic] all tracked player identities are out of lives — mission terminal`
- post-terminal spawn suppression: `[duel-dynamic] mission terminal — spawn request ignored (<reason>)` / `mission terminal — wave schedule ignored (<reason>)`

## Identity model

- **Identity** = the player's UCID (`EventData.IniPlayerUCID`) when present;
  otherwise the slot group name (`Aerial-1`…`Aerial-4`) with the one-time
  warning above.
- **`lives` is per mission run**: a restart (`LeftShift+R` / WebGUI restart /
  `net.load_mission`) resets every identity to 3 lives and `waveNumber` to 0.
- **Reconnect keeps lives**: re-entering with the *same identity* (same UCID, or
  the same slot under the fallback) keeps the current count — it is **not**
  reset to 3.

## Test cases

**T1 — baseline wave size (1 player).** One human in `Aerial-1`.
Expected: wave 1 spawns a 1-ship package (log `spawning 1-ship package …`).
F10 `Show lives` shows the identity at `3`.

**T2 — one life removed per real loss (Dead+Crash dedup).** Get the player
killed once (shot down / crash — do **not** just eject). Expected: exactly one
life removed → F10 `2`; in-game `Aircraft lost — 2 lives left.`; no
`initialized missing lives` log line. A single death must produce exactly **one**
decrement despite the Dead/Crash event pair.

**T3 — UCID identity.** Check the log for the one-time UCID warning. Present →
identity is the slot name (fallback); absent → UCID identity is in use. Record
which, since it keys reconnect. (Residual risk: `IniPlayerUCID` availability on
this dedicated-server build is unproven; the slot fallback covers its absence.)

**T4 — reconnect keeps lives.** After T2 (2 lives left), the player ejects (slot
released, no life lost) and re-enters the same slot (same identity). Expected:
F10 still shows `2` (**not** reset to 3). If the identity has 0 lives at
re-entry, expect `Out of lives — excluded from the package.` and exclusion from
sizing instead.

**T5 — zero-life exclusion from package sizing.** Bring one player to 0 lives
(3 deaths) while another still has lives. Expected: the 0-life identity
contributes 0 to the next package size (size is based on the other player(s)
only), and on re-entry shows `Out of lives — excluded from the package.`

**T6 — escalation cadence.** With a fixed N live players, watch successive wave
sizes (force them with F10 `Respawn bandit wave`). Expected size =
`min(N + floor(waveNumber/3), 8)` where `waveNumber` is the number of waves
already spawned (the 1st wave has `waveNumber = 0`, so `extra = 0`):

| N players | wave sizes (1st, 2nd, 3rd, …) |
|---|---|
| 1 | 1,1,1,2,2,2,3,3,3,4,4,4,5,… (cap 8) |
| 2 | 2,2,2,3,3,3,4,4,4,5,… |
| 4 | 4,4,4,5,5,5,6,6,6,7,7,7,8 (cap hit at wave 13) |

The `escalation +E` log suffix appears starting at wave 4 (E=1) and steps up
every 3 waves.

**T7 — terminal state.** Drive **all** tracked identities to 0 lives. Expected:
one `All pilots down — mission over.` message, log `… out of lives — mission
terminal`, and **no further package spawns** (any spawn request logs
`mission terminal — spawn request ignored`). The current red wave is **not**
force-despawned. F10 `Respawn bandit wave` then reports
`Mission over — no more waves.`

**T8 (optional) — multi-player geometry.** 2–4 players; inspect in Tacview: one
red group per wave, aircraft in formation, red lead 55–85 sm from the blue
centroid (`spec-duel-dynamic.md §9`).

## Reset between tests

- `LeftShift+R` (SP) or WebGUI restart / `net.load_mission` resets lives to 3
  and `waveNumber` to 0.
- WebGUI force-slot / kick-to-slot controls (or the in-mission slot selector)
  add/remove players mid-mission.

## Known residual risks to watch (from offline review)

- **(a)** `countedPlayerUnits` is never cleared within a run: if DCS reuses a
  unit name for a native respawn, that later loss is **under-counted** (a life
  not consumed), never double-counted.
- **(b)** Live availability of `EventData.IniPlayerUCID` on this dedicated-server
  build is unproven; the slot-name fallback covers absence (one-time warning).
- **(c)** DCS-native respawn cannot be blocked per identity: a 0-life identity
  that re-enters is announced + excluded but the slot is not blocked
  (`spec-duel-dynamic.md §6.6`).

## PASS / FAIL

- **PASS:** T1–T7 all match the expected behaviour; F10 `Show lives` counts
  never drift from the observed deaths; exactly one decrement per death;
  terminal suppresses all further spawns.
- **FAIL:** any of — a single death removes more/less than one life; a reconnect
  resets a non-zero identity to 3; a 0-life identity contributes to package
  size; a spawn occurs after terminal; a same-human reconnect (same UCID) gets
  fresh lives.

On PASS, record the run in `progress.md` and flip queue item
`s64-live-verification` to `completed` with the run key and evidence.