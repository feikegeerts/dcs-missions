# Survival live findings — 2026-09-15

## Evening two-player retest — follow-up repair

The 17:54–18:40 UTC run still failed: Aerial-1 reached zero at 18:31:54
and Aerial-3 at 18:38:32, but both re-entered and waves continued.
Initialization logged both slots before the UCID entry callbacks. The old
reconciliation only inspected `slotIdentity`, missing allowances created by
init without a slot identity; it also refused to migrate live fallback aircraft.
These phantom positive balances prevented the all-zero terminal transition.

Source repairs now merge the actual slot fallback (including live ownership),
never merge two distinct UCIDs, and synchronously query individual allowance
from the native slot veto rather than waiting for terminal telemetry. The
grace timer sets `DUEL_SURVIVAL_END`; the builder adds a native END MISSION
trigger with Blue winner, replacing the unverified SSE endMission call.

Waves 1–6 used Bandit-6, then Bandit-3 five times: independent replacement
draws allowed the repeated MiG-29s. Selection now uses a without-replacement
bag per tier. Inbound and kill messages no longer reveal enemy counts.

Loadouts/fuel are owner-edited. Do not overwrite the dedicated-server mission
files until those edits have been coordinated. These follow-up changes require
new shipping archives and the new hook, plus another live two-player test.

Offline verification: 46 gameplay scenarios, 15 configuration tests, and 102
production-hook checks (both bridge return mappings) pass. All nine telemetry
Lua suites pass. All three archives were rebuilt in `out/`; each passes the
shipping integration sandbox and the new native-terminal-trigger execution
test. `git diff --check` passes (existing hook line-ending warning only).
These builds have **not** been copied to the dedicated server, and no
post-fix DCS run has been performed. The native action signature is taken from
the installed editor's `me_trigrules.lua` (`a_end_mission`, winner/text/delay),
not inferred from a test mock.

## Root cause confirmed from the 17:54 run (21:00 UTC analysis)

The telemetry spool for the run (`run-20260915T173837Z`) proves the mission
side **does** receive UCIDs post-simulation: `participant.entered` carries
`participant_id` `3e0d…` (James V) and `b567…` (Jazpero), 32-hex UCID format.
But the first `PlayerEnterAircraft` events fired at 17:54:09, *before*
simResume (17:54:40), carried **no** UCID (log: `player UCID unavailable`),
so gameplay keyed the allowances on the slot fallbacks (`Aerial-1`,
`Aerial-3`). The later UCID-bearing entry events found `slotIdentity[idx]`
still nil, so the old merge (guarded on a non-nil previous identity) never
ran: two parallel keys per player — fallback=3 (frozen by init catch-up) and
UCID (decremented by losses). Both UCID keys reached 0 at 18:38:32, but the
terminal scan still saw the fallback keys at 3, so the terminal never fired,
the hook's global block never engaged, and the native slot entry was
unvetoable. This single race explains both observed symptoms (re-spawn after
zero **and** no mission end).

Fix in `src/gameplay/package-waves.lua`:

- `setSlotIdentity` treats the slot fallback name as the previous identity
  even when `slotIdentity[idx]` is nil, so the first UCID sighting merges the
  fallback allowance (min of balances, never additive) and migrates live
  aircraft ownership. Two distinct UCIDs are never merged.
- The hook's `onPlayerTryChangeSlot` veto now queries the mission
  **synchronously** (`net.dostring_in` → `a_do_script`, the same transport as
  the telemetry handshake) on every Blue slot request, instead of waiting for
  the asynchronous terminal telemetry event.
- `duel_can_enter_blue_slot(ucid, slotID)`: the mission-keyed UCID allowance
  is authoritative; when that key is unknown it resolves the requested seat
  from the server slot ID (numeric-part match against the runtime slot unit
  IDs, observed Aerial-1..5 = 1/6/9/13/20; probe slot format `101_1`) and
  checks that seat's current identity. Unknown players/unknown slots fail
  open; the global terminal block remains as last resort.
- The 60-second grace timer sets the `DUEL_SURVIVAL_END` user flag; the
  shipping builder appends a native ONCE trigger (`c_flag_is_true` →
  `a_end_mission("blue", "", 0)`), verified by executing the generated
  trigger in `tests/lua/run-shipping-terminal-trigger.lua`. The SSE
  `trigger.action.endMission` call is gone.

Slot IDs 1/6/9/13/20 are unique, and the constant `101` prefix in the probe's
slot format matches no unit ID, so the numeric-part matcher cannot misbind a
seat. The gate logs the raw slot ID once per mission run
(`slot gate: slotID=…`) to confirm the format live.

Deployment: all three archives (Survival rebuilt from the owner-edited
`Saved Games\DCS\Missions\Telemetry\air-superiority-survival.miz`, preserving
the low-fuel + BVR loadouts) and the hook were deployed to the dedicated
server at 21:44 UTC with backups suffix `.pre-slotgate-20260915-214405.bak`;
deployed SHA-256 verified against `out/`. Owner-edited loadout verified in the
staged build: F-16C slots carry exactly 4× AIM-120C; FA-18C slots carry
2× AIM-9 + 4× AIM-120C pylons (two of them `LAU-115_2*LAU-127` dual-launcher
racks — 4 or 6 missiles depending on rack fill, confirm in the ME); all five
player slots have reduced fuel (490 kg Hornets / 325 kg Vipers).

Still required: server restart + fresh two-player three-loss live test.
Expected log evidence: `reconciled slot identity Aerial-N from Aerial-N to
<ucid>`, `slot gate: slotID=…`, `all tracked player identities are out of
aircraft`, `ending DCS mission with Blue`, `blue-slot-rejected …
reason=aircraft-exhausted` on any post-zero slot request, and the DCS mission
ending with Blue as winner 60 s after the final loss.

Owner is testing missions sequentially, not concurrently. These findings are
open; no mission, collector service, or production database was changed during
the initial investigation.

## Collector health missing

Owner reports dashboard text: “No collector status received yet.”

The staged collector at
`C:\Users\g_for\dcs-telemetry-service\dist\src\service.js` lacks the health
posting integration present in `collector/src/service.ts`: its delivery
completion only clears `deliveryInFlight`, without posting collector health.
The dashboard store reads the latest global health row, not a mission-filtered
row. This points to a stale service deployment rather than survival-specific
health routing. Confirm the running service's executable arguments before
upgrading; preserve its state, credentials, and single-owner arrangement.
The repository now includes `build/update-collector-service.ps1`, which performs
that narrow distribution upgrade only after checking the source build,
dependencies, schema, and running service, and leaves the durable state and
private settings untouched. Deployment and the resulting health row still need
to be verified in an owner-approved service window.

## Aircraft allowance and terminal-state failure

Owner reports that a player could re-enter the native slot after the allowance
reached zero, and the mission did not end after the expected grace period.

Local hook output for `run-20260915T063120Z-0cf1b60f` identifies the mission as
`air-superiority-survival` and records:

- Sequence 37: `asset.dead` for `aerial-1.u1.g1`.
- Sequence 39: a new spawn, `aerial-1.u1.g2`.
- Sequence 51: `asset.dead` for `aerial-1.u1.g2`.
- Sequence 53: a new spawn, `aerial-1.u1.g3`.

Thus at least two distinct aircraft losses were captured locally; it is not
simply a missing second telemetry death event. Production ingestion and the
specific dashboard counter have not yet been verified. Only one `pilot.dead`
event appears in this run, which must not be conflated with aircraft losses.

The latest run confirms two separate gameplay issues. First, the gameplay
handler initially used the slot group as a fallback identity while the
telemetry handler received a UCID. Later respawns could therefore create a
second three-aircraft allowance, preventing the all-zero terminal condition.
Second, DCS emitted a fourth `asset.spawned`/`participant.entered` pair after
the third logged loss because the mission-side event handler cannot veto a
native slot change. The final aircraft only emitted an eject/dead telemetry
fact, not the gameplay Dead/Crash pair.

The source now reconciles a late UCID with the prior fallback allowance,
preserves aircraft-incarnation identity across Birth/Dead/Crash/Ejection, and
the production hook vetoes later Blue slot requests after the terminal
`gameplay.ended` event. Rebuild all three mission archives and perform a fresh
live three-loss test. Coordinate any service deployment/restart with the owner
separately.

## Resolution in source

The follow-up fix tracks aircraft incarnations from `Birth`, reconciles
fallback and UCID identities (including the pre-simulation race above), and
counts an ejection as an aircraft loss. Once every tracked human identity has
zero aircraft remaining, wave replacement is disabled immediately; the current
red group remains for a 60-second missile grace period, the server hook
rejects later Blue slot changes (synchronous per-pilot query plus the global
terminal block), and the grace timer's `DUEL_SURVIVAL_END` flag drives the
native END MISSION trigger, which ends the DCS mission with Blue retained as
the survival winner.
