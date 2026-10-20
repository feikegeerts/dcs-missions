# Operation Hidden Passage — Hatay transport test

**Historical development record.** The owner accepted short-range testing and
approved the operational port. Current mission names, behaviour and build commands
are in **[Operation Hidden Passage](hidden-passage.md)**. Older pending gates,
Chinook-only restrictions and Short Voice Test filenames below are historical.

Status: **extraction-1: Chinook updated for the user's southern pickup layout;
new-site hosted acceptance pending.** The user successfully completed the
revision-3 transport loop at the original location. The client log also records
the successful delivery. This does not validate the relocated LZ or UH-60L.
Date: 2026-10-20

## Current layout and flight instructions

### Short-range voice-test copy (2026-10-20)

**Current revision `transport-test-6` (short mission only):** Both **Mule One /
CH-47F** and **Raven One / UH-60L** have independent four-command F10 menus,
including landing-area smoke. Either can collect and deliver the single party.
Land within 105 m of the party, keep at least 35 m clear of **every** person, and
remain stopped for two seconds: boarding and the aircraft-specific crew-chief
call begin automatically. If too close, a one-time crew-only message asks you to
reposition. Movement, hover or leaving range restarts the settling period. Ramp
and door positions are not checked. The extraction menu remains a fallback.

Entering a slot does **not** claim the objective. The first helicopter whose
boarding actually begins becomes the carrier; the other retains smoke/status
access but cannot steal or duplicate the party. If both qualify in the same
observer tick, Mule is evaluated first. After boarding begins, carrier loss or
replacement still requires a restart; there is no reset or automatic handover.
Off-site unloading can be recovered by that same carrier.

Stay landed until disappearance and the aboard confirmation. UH-60 boarding uses
its own boarding/doors-closing recordings plus the shared HVT-aboard recording.
Return to Hatay, land and stop, then use **Unload personnel** in that aircraft's
menu. Unloading remains manual. Either carrier can trigger the Blue-wide mission
success recording. Both can independently trigger their own takeoff call and the
shared halfway warning. Raven's support call now uses the corrected Overlord
recording (`raven1-cleared-for-support.mp3`, 11.04 s, latest Downloads version).

The client log confirmed the previous failure when leaving the Chinook before
pickup; it also recorded Raven's takeoff call. Early Chinook ownership was removed
here, rather than interpreting that slot switch as package loss. Automatic pickup
was missing through `voice-test-4`; it is now exercised with the pinned CTLD
methods for **both** aircraft. 68 source/shipping mocks pass, including complete
UH-60 delivery, slot switching before pickup, competing carriers, proximity,
independent settling, casualty/loss/replacement and duplicate callback checks.
**Live acceptance of both aircraft is still required before approving a long-range
port.** The long-range archive remains unchanged.

Update this revision with explicit permission to replace only Raven's old audio:

```powershell
python build/update-hidden-passage-short-voice.py --input 'C:\Users\g_for\Saved Games\DCS\Missions\Operation Hidden Passage - Short Voice Test.miz' --replace-audio raven-one-cleared-for-support.ogg --deploy
```

The updater preserves mission/editor tables and other recordings byte-for-byte;
only the embedded payload, known automatic/dual-aircraft briefing sentences and
the explicitly allowed Raven recording are changed. It backs up the short archive
and rejects the long layout. Older revision notes below describe historical scope.

**Voice revision `voice-test-4` (short mission only):** The supplied
`hidden-passage-success.mp3` now plays once to all Blue crews on confirmed mission
success: the intact three-person party is unloaded at Hatay while the carrier is
landed. Boarding alone, off-site/airborne unloads, failed attempts and unrelated
troop deployments cannot trigger it. Duplicate delivery callbacks cannot repeat
it. The existing voice queue prevents overlap; no forced mission end is added.
48 source/shipping mocks pass. Live success-audio acceptance remains pending;
the long-range archive remains unchanged.

**Voice revision `voice-test-3` (short mission only):** The recording imported from
Downloads `mule1-hvt-under-fire.mp3` is broadcast once to **all Blue aircraft**
when either named helicopter first crosses halfway outbound. Halfway means
remaining straight-line distance to the editor LZ is at most half the
Hatay-return-to-LZ distance (about **1.53 NM remaining** in this layout), not
accumulated distance flown. A one-second observer watches each recognized
departure independently, including Raven when the Chinook slot is unoccupied.
It requires a live airborne aircraft crossing from outside that threshold; an
initial takeoff already near the LZ does not arm it. It cannot repeat for the
second helicopter or after pickup/failure/completion. Ground movement, detours,
dead/replaced aircraft and off-site recovery do not manufacture a trigger.
The recording is narrative only: no enemies, actual incoming fire, or objective
damage are added. Existing takeoff/crew calls remain aircraft-specific.
45 source/shipping mocks pass; live timing/audio acceptance remains pending.

**Voice revision `voice-test-2` (short mission only):** Mule's departure call now
requires takeoff by `Mule-1-1` (CH-47F), and Raven's new support call requires
`Raven-1-1` (UH-60L). Each plays once independently per mission; unrelated aircraft
cannot trigger or consume either call. Voice and subtitles target the originating
aircraft rather than all Blue players. Multicrew audibility still needs live QA.
Boarding calls likewise target the carrier. Shared audio helpers select UH-60
boarding/doors-closing recordings and reuse **HVT aboard**, but **UH-60 extraction
ownership is not enabled by this change**. Automatic boarding is not implemented
yet; the current F10 transport procedure remains in place. No door/ramp check is
added.

For this revision, update the **existing short archive**, not the long-range one:

```powershell
python build/update-hidden-passage-short-voice.py --input 'C:\Users\g_for\Saved Games\DCS\Missions\Operation Hidden Passage - Short Voice Test.miz' --deploy
```

Omit `--deploy` for a candidate build. This updater requires the ~3 NM layout and
named Mule/Raven slots, backs up before deployment, and leaves all editor tables
and existing audio byte-identical. It replaces only the embedded mission payload
and adds missing source audio assets. There are 37 mocked source/shipping checks,
including independent takeoff order, duplicate events, recipient targeting, stale
recipients and shared UH-60 aboard audio. Evidence is in
`out/operation-hidden-passage-short-voice-evidence.json`.
**Do not port these source changes to the long-range archive until approved after
short-mission flight testing.**

For quick audio/boarding tests, load **`Operation Hidden Passage - Short Voice
Test.miz`** from the full client's Missions directory. It copies the current
voice-enabled mission, with pickup waypoint 4 and the HVTs relocated **3.06 NM
northeast of Hatay**, near the earlier test area. Allow roughly **2 minutes at
100–120 knots**, plus takeoff/approach. Use the same F10 extraction and return
procedure below. The party remains 83.1 m from the landing mark; check the LZ
visually before landing.

At initial copy creation, the original 33 NM mission and the older `Operation Hidden Passage - voice
test.miz` are untouched. All four audio files, embedded playback/mission scripts,
aircraft, Hatay placements, return zone, weather and triggers are preserved.
Only the two pickup zones, party-template coordinates (and any named pickup
support), Chinook waypoint 4, title and travel briefing are edited in the copy.
Embedded coordinate snapshots remain unchanged; runtime uses the relocated zones.
Offline checks include 30 adapter/voice tests using the copy's actual zone layout;
live audio/terrain acceptance remains pending.

To make another copy after editing the main mission, choose a **new** output name:

```powershell
python build/copy-hidden-passage-short-test.py --input 'C:\Users\g_for\Saved Games\DCS\Missions\Operation Hidden Passage.miz' --output 'C:\Users\g_for\Saved Games\DCS\Missions\Operation Hidden Passage - Short Voice Test 2.miz'
```

This dedicated copy tool never rebuilds scripts/audio from `src/` and refuses to
overwrite existing files. Evidence: `out/operation-hidden-passage-voice-test-evidence.json`.

### Operational layout (unchanged)

- `OHP-Pickup`: the user-selected landing area, **33.06 NM / 61.23 km south of
  Hatay** in a straight line; Chinook navigation waypoint 4 is now **PICKUP**.
- `OHP-HVTs`: the three-person party's spawn zone, **83.1 m southwest** of the LZ.
  The internal late-activated template remains `OHP-TestParty` for compatibility.
- `OHP-Hatay-Return`: the user's return zone; waypoint 5 **HATAY RETURN** matches it.
- The editor layout is preserved: Chinook setup/guns, first three waypoints,
  relocated ground support, zones, weather, coalitions, and the added UH-60L slot.
  **UH-60L extraction is deliberately not enabled.** No new enemies or SAMs.

Reload the mission from disk and enter **Mule-1**. Use **F10 → Operation Hidden
Passage → Mark landing area (green smoke)**. Smoke marks the actual editor LZ,
not an assumed point south of the party. Land, keep at least **35 m clear of every
person**, stop, then select **Extract waiting personnel**. Remain grounded until
the party disappears and **Three personnel aboard** appears together. Return to
`OHP-Hatay-Return`, land and stop, then select **Unload personnel**. Success says
**Operation complete: all three personnel delivered to Hatay**.

The setup spacing check now uses the existing **35–105 m** clearance/extraction
envelope instead of the prototype's arbitrary 50–80 m constraint. CTLD's maximum
extraction range is still 105 m; the per-person 35 m safety check is unchanged.
Runtime reads the actual named zones for smoke and distance, not build snapshots.
After an off-site unload, smoke follows the recovered party using the editor LZ's
relative direction/separation. The original map marks remain fixed.

At **100–120 knots groundspeed**, 33 NM takes roughly **17–20 minutes** each way;
allow approximately **20–25 minutes per leg** for detours and approaches. These
are planning estimates, not a flight-tested terrain-masked route. Buildings,
trees, slope, troop pathfinding, and ingress/return exposure still need live checks.
Restart the mission after failure or completion; there is **no in-mission reset**.

## Historical prototype scope (superseded by the layout above)

The user-authored `Operation Hidden Passage.miz` starts a Blue CH-47F at Hatay.
This transport-only extension preserves its original unit, parking, hot start,
fuel, guns, radios, and original three route points. It appends navigation points
4 **TEST PICKUP** and 5 **HATAY RETURN**.

Added:

- Hatay detachment: fuel tanker, supply truck, Hummer and two ground personnel.
- One Blue Hummer near the test pickup, clear of the party's immediate area.
- One three-person Blue extraction party, injected once through MOOSE CTLD,
  waiting **60 m north of the landing mark**, not directly on it.
- Separate landing/personnel/return zones and Blue F10 map marks.
- One focused F10 menu: instructions/status, landing smoke, extract, unload.
  Generic CTLD logistics menus are not shown.
- Landed pickup/unload accounting and a single success notification.
- A three-line boarding sequence, played DCS-native through
  `trigger.action.outSoundForCoalition` (no SRS): crew chief calls the package
  in, HVT reports in, crew chief confirms the count. Cabin/intercom lines, so
  they ship dry with no radio processing.
- A takeoff radio call, played once when the first Blue aircraft leaves the
  ground: `Sounds/OHP/mule-one-cleared-for-pickup.ogg`.

No enemies, SAMs, other flyable aircraft, hoist interaction, persistence, new
telemetry integration, or native mission end. The friends' aircraft is confirmed
as **A-10C II Tank Killer**; it is not added to this Chinook-only prototype.

## Boarding voice sequence

Three ElevenLabs lines, all cabin/intercom, all shipped dry (no radio chain, no
squelch tail):

1. `boarding_start` — `Sounds/OHP/boarding-start.ogg` — crew chief, played when
   `begin_boarding` first transitions. Subtitle keeps the "Personnel boarding..."
   instruction.
2. `boarding_hvt_aboard` — `Sounds/OHP/boarding-hvt-aboard.ogg` — HVT team leader,
   played on the extraction receipt. Subtitle: "All three aboard."
3. `boarding_confirm` — `Sounds/OHP/boarding-confirm.ogg` — crew chief, queued
   straight after the HVT line. Subtitle keeps the "Three personnel aboard..."
   return instruction.

The playback module is `src/missions/operation-hidden-passage/voice.lua`; the
build copies `src/missions/operation-hidden-passage/sounds/*.ogg` into the `.miz`
under `Sounds/OHP/`. Replacing a line means dropping a new Ogg and updating its
duration in the manifest.

DCS `outSoundForCoalition` is deliberate: scripted audio must be heard without
requiring the player to tune a radio, and the group does not use SRS.
`radioTransmission` is not used for these beats.

## Takeoff voice call

The first Blue aircraft to take off triggers
`Sounds/OHP/mule-one-cleared-for-pickup.ogg` once per mission. The handler is a
`world.addEventHandler` `S_EVENT_TAKEOFF` subscription in `transport-test.lua`;
any Blue aircraft counts, not only the Chinook. If friendly AI aircraft are added
later and the call should be pilot-only, gate on `unit:getPlayerName()` instead
of `unit:getCoalition()`. The line ships as the raw ElevenLabs render — no radio
chain, no squelch tail — transcoded to 48 kHz mono Ogg Vorbis only.

**Handler shape matters:** this DCS build's dispatcher calls
`handler:onEvent(event)`, so the argument to `world.addEventHandler` must be a
table exposing `onEvent`. Passing a plain function raises
`EventHandlers.lua:13: attempt to index local 'handler' (a function value)` on
every event and aborts the rest of the handler chain, including MOOSE's.

Initial deployment updated the user's `Operation Hidden Passage.miz` and
preserved its original 9,221-byte seed at:

```text
C:\Users\g_for\Saved Games\DCS\Backups\Operation-Hidden-Passage\Operation Hidden Passage-before-transport-20261020T095724614760Z.miz
```

Original SHA-256:
`c3f9985b5d3f726273bec4ae4bd9eec1133974671b399593a6fd5c7cf3c6741e`.

Updated builds deploy at the same mission path. The tested revision 1 was also
preserved as `Operation Hidden Passage-before-transport-20261020T102702349576Z.miz`
in the same backup directory; the original Chinook-only seed remains unchanged.

## Historical prototype flight instructions (old location)

1. **Reload** `Saved Games\DCS\Missions\Operation Hidden Passage.miz` in DCS.
   If an earlier copy remains open in the editor, reopen it before saving;
   otherwise that stale editor copy could overwrite the scripted update.
2. Enter the existing **Mule-1** Client slot. The **Operation Hidden Passage**
   F10 menu appears shortly after joining. There is no generic CTLD submenu.
3. Open F10 and find **OHP TEST LANDING**, approximately **3.05 NM northeast** of
   the original parking. The approximate bearing is a convenience, not a route
   clearance or guarantee of obstacle-free terrain.
4. F10 → **Operation Hidden Passage** → **Mark landing area (green smoke)**.
   Smoke can be requested from any distance; no CTLD logistics-zone registration
   is needed. Check the field for trees, buildings, wires, and slope.
5. **Land at the smoke, not on the personnel mark.** The party waits 60 m north;
   keep at least 35 m clear of every person and stop moving. F10 → **Operation
   Hidden Passage** → **Extract waiting personnel**. CTLD handles boarding
   internally; do not use native troop-transport commands.
6. Remain landed until **Three personnel aboard**, typically about 20–45 seconds
   depending on distance. The party now disappears in the **same callback** that
   confirms boarding and permits takeoff. Taking off before that still fails.
7. Return to the Blue **OHP HATAY RETURN** mark at the original parking. Land
   inside the 180 m return area and stop moving. F10 → **Operation Hidden
   Passage** → **Unload personnel**.
8. Confirm **Test complete: all three personnel delivered to Hatay**. Merely
   visiting the area or flying over it is not a successful delivery.

The rear gun is retained. This probe deliberately has no ramp/door interlock
and no claim of native cabin passenger animation. A wrong-location unload does
not succeed; the deployed party can be recovered through CTLD. Aircraft/party
loss requires a **mission restart**, not merely re-slotting. Failure feedback
now explicitly states this, and extraction/unloading commands are blocked once
failed. Status remains available after a re-slot. **There is no reset command or
in-mission reset logic**, per the user's instruction. The terminal policy is only
for this probe, not a final decision about full-mission respawns.

If recovering an off-site unload, the smoke command suggests a point 60 m south
of the party's current position; visually check it before landing. Original F10
landing/return marks remain at their original locations.

### Placement limits

The pickup is a **provisional test field**, not a visually validated LZ. Setup
checks reject water and a gross slope across a 60 m sample, but cannot establish
tree/building clearance. Ground-support placements likewise need an editor/live
check for collisions and taxiway clearance.

If needed, move **OHP-Test-Pickup** (landing) and **OHP-Test-Personnel** (waiting
party) together to a clear field; keep the party 60 m north of the landing point.
CTLD spawns the party at the personnel zone. Also move the nearby Hummer and
TEST PICKUP route point for consistency. Do not activate the late-activation
**OHP-TestParty** template manually; CTLD supplies the single actual party.

### First hosted-run findings (revision 1)

The user's normal client-hosted multiplayer run successfully loaded MOOSE, the
mission scripts and the test party. It was not a full transport acceptance pass:

- Generic CTLD smoke could not find a registered logistics zone; the mission
  had a trigger zone but not a CTLD logistics zone.
- Both Load troops and Extract troops were visible, although only extraction
  of the existing party made sense for this test.
- DCS recorded a Chinook hit on a Blue soldier, helicopter crash, and soldier
  death before pickup. This establishes a hit/collision sequence, not the exact
  contact geometry. The user confirmed the death occurred before boarding.
- The objective failed on the aircraft loss. Re-slotting permitted further CTLD
  interaction, but did not restore objective eligibility; the later unload was
  rejected as not confirmed aboard.

Revision 2 addresses spacing/marking, focused command gating, smoke access, and
failure feedback. It does **not** add a reset mechanism or make personnel immune
to helicopter collisions. Repeat the full loop on a normal hosted server first;
the dedicated-server gate can follow later.

### Second hosted-run finding and revision 3

The user reached the LZ, requested extraction, watched the party move toward the
Chinook and disappear, then lifted off and received an early-departure failure.
The client log records boarding at 11:43:30 and failure at 11:44:04, without an
onboard confirmation. Pinned CTLD independently schedules removal after a random
10–20 seconds and its boarding receipt after `floor(distance / 4) + 20` seconds.
The mission's strict takeoff gate therefore disagreed with the visual cue.

Revision 3 retains CTLD's routing, cargo accounting and boarding-receipt timing.
Only during the guarded extraction call, the party's delayed `Destroy` request
is intercepted and deferred; its original method is restored even on an error.
The native boarding receipt validates the carrier and intact party, completes
objective boarding, removes the visible group immediately and announces clearance
in one callback. No global MOOSE class or pinned library is changed. Casualties
during boarding, aircraft loss and genuinely premature takeoff still fail; a late
receipt cannot revive the attempt. No reset mechanism is added.

Revision 3 deployment preserved the user's editor re-save, including repositioned
Hatay ground support. Only `l10n/DEFAULT/OHP-main.lua` and the two boarding
instruction lines in `l10n/DEFAULT/dictionary` changed; every other archive member
is byte-identical to the pre-update mission. The re-saved revision 2 is backed up
as `Operation Hidden Passage-before-transport-20261020T115725897166Z.miz` in the
existing backup directory. Deployed SHA-256:
`a186df38521eff9ea3867948be5d8b9ad7ef0480257c06ea395b341f59ad5c6c`.

## Current source and build

Source: `src/missions/operation-hidden-passage/`. The new entry does not import
package-wave gameplay. `src/.current-mission`, bootstrap, the wave packager,
installed hooks/services and DCS sanitization are unchanged.

Update the current, editor-authored mission with the explicit preservation mode:

```powershell
python build/pack-hidden-passage.py --input 'C:\Users\g_for\Saved Games\DCS\Missions\Operation Hidden Passage.miz' --update-existing --deploy
```

Outputs:

- `out/operation-hidden-passage.miz`
- `out/operation-hidden-passage-build/` — inspectable payload and mission tables.
- `out/operation-hidden-passage-build-evidence.json` — input/output fingerprints,
  verification scope, and initial deployment backup path when applicable.

Omit `--deploy` for a candidate-only build. The updater validates the known
Chinook/template/startup resources and zone snapshots, then updates scripts,
voice assets, briefing/title, pickup/return waypoint coordinates and the startup
comment. It does not recreate units or zones. Artifact checks compare the entire
mission table against the input, allowing only those waypoint/comment changes;
the UH-60L and other editor settings must match exactly. Other archive members
are retained. Deployment backs up the input outside Missions and refuses to
replace it if it changes during the build.

Without `--update-existing`, the legacy recipe still requires the original
Chinook-only seed and creates a fresh layout. **Do not deploy that seed-based
output over the current mission:** it omits the user's editor changes and UH-60L.
Keep the original seed backup unchanged. Later zone moves require synchronizing
the build/test coordinate snapshots in `config.lua`; runtime itself uses zones.

Both MOOSE and the selected mission entry/dependencies are embedded as resource-
keyed DO SCRIPT FILE actions. The artifact needs no runtime disk loading or
de-sanitized DCS environment. No installed campaign scripts/assets are copied.

## Verification and remaining gate

Commands:

```powershell
lua5.1 tests/lua/run-hidden-passage-operation.lua
lua5.1 tests/lua/run-hidden-passage-adapter.lua
python build/pack-hidden-passage.py --input '<edited Operation Hidden Passage.miz>' --update-existing
```

Verified offline:

- 11 pure objective-accounting checks.
- 28 source adapter checks and the same 28 against the generated shipping
  payload in a no-filesystem environment. These include invoking the actual
  extraction/unload methods sliced from pinned MOOSE with mocked world services,
  focused menus with an empty CTLD pilot set, safe clearance, distant smoke,
  and failure/re-slot command gating. A time-aware scheduler regression checks
  visibility up to the receipt and takeoff immediately afterward at 40/60/100 m,
  early takeoff, casualties, duplicate receipts, error-path method restoration,
  and repeated extraction after an off-site unload. New checks cover renamed
  zones, runtime placement/distance, exact LZ smoke, recovery-smoke direction,
  spacing bounds and deferred UH-60L ownership. No reset menu is permitted.
- Original Chinook setup/route preservation; unique group/unit IDs and names;
  Blue Hatay warehouse; three-person template; pickup distance and zone layout.
- Lua 5.1 parsing of generated tables, payload and pinned MOOSE; modern and
  legacy startup wiring/resource resolution; ZIP paths and CRC checks.

Revision 3's original-location loop is **user-reported live-accepted**. Next:
repeat the complete Chinook pickup/return at the **new southern location** on a
normal client-hosted server, checking terrain, placement and boarding together.
Confirm clear failures and no false success on wrong-location unload, then repeat
on the dedicated server later. Do not infer troop pathfinding, collision safety,
visual boarding, or multiplayer acceptance of the fixes from mocks.

Log breadcrumbs: `[hidden-passage] Extraction armed`, `READY extraction-1`, and
`PASS delivered`. A setup problem logs an error and displays a message instead
of silently granting success. Keep existing sanitization settings as they are.
