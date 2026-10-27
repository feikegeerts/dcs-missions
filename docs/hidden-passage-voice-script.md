# Operation Hidden Passage — voice-generation script

Recording script drafted 2026-10-26; **integrated and deployed 2026-10-27**.
This file specifies speakers, playback cues and copy-ready recording text.
The retained recordings' quoted text comes from the existing code, not a fresh
transcription of those audio files. Deployment evidence is in `hidden-passage.md`.

## Recording/import and integration status — 2026-10-27

**Current Hind handoff gate:** The Hind still spawns with the MiGs on radar
destruction, but its existing launch-preparation recording/text is sent only
after all spawned fighters are confirmed destroyed, plus the normal 20-second
reporting pause. It is not announced at Hind spawn/readiness anymore. The owner
explicitly chose to keep the existing wording/take despite the Hind potentially
already being airborne. The cue is once-only and suppressed if the Hind is
lost or the mission becomes terminal. See `hidden-passage.md` for deployment.

**Current reporting latency:** Overlord outcome recordings and their matching
text wait at least 20 seconds for observed events: Kub radar destruction,
fighter/Hind launch preparation, mission success and failure. The owner approved
a **five-second exception for checkpoint package-aboard tasking**, so CAS is
warned before the helicopter reaches it. Queue priority prevents that task from
waiting behind routine 20-second intelligence; existing/urgent crew audio still
finishes first. Initial tasking, helicopter clearances and direct crew/pilot/HVT
calls keep their timing. Actual mission transitions/spawns do not wait. These
are scheduling changes only; all recordings retain their existing content and
approved volume. Build/deployment: `hidden-passage.md`.

**Later removal of fighter departure acknowledgements:** O1 and O2 are now
disabled at the owner's request because they speak for the human CAS/CAP pilots.
Their takes remain registered/archived for preservation, but no mission hook
plays them and the queue rejects even direct requests for either cue. There are
**25 enabled cues plus these two disabled assets**. Other pilot destruction
reports and Overlord/crew calls remain enabled; historical integration notes
below describe the prior 27-cue build.

**Sequential CAS revision:** The owner supplied three new `(2).mp3` takes for
CAS departure, convoy tasking and checkpoint tasking. These are imported at the
approved 90% level. Convoy tasking remains first; checkpoint troops and tasking
now wait for confirmed full boarding in either helicopter, not takeoff or boarding
start. A clearly labelled temporary solo CAS F10 bypass can simulate this stage
release without changing the actual extraction objective. See the
[solo-test procedure](hidden-passage.md#temporary-solo-cas-pickup-simulation).
The three replacement durations/queue lengths are updated; other 24 clips are
unchanged from the volume revision.

**Later volume-only revision:** At the owner's request, all 27 deployed clips
now play at 90% of their prior volume. Lines, speakers, cues and durations are
unchanged. This includes retained entries 15/18/19/20: their content remains,
but the quieter files are no longer byte-identical to the originals. The
byte-preservation statements below describe the earlier import/integration.
Original assets are backed up; per-file hashes/gain measurements are in
`src/missions/operation-hidden-passage/voice-gain.json`. See
[deployment details](hidden-passage.md).

The owner retained the existing recordings for **15, 18, 19 and 20**. Do not
regenerate or replace those four; their entries below now show the retained code
transcripts rather than the earlier proposed replacements.

Imported **17 MP3s** from Downloads as validated mono, 48 kHz Ogg Vorbis:
entries 01–10, 21 and O1–O6. Entries 01, 02 and 09 replace existing clips;
the other 14 are new assets. The other ten existing recordings, including the
four explicitly retained clips, were preserved byte-for-byte. Original MP3s
were not modified. Existing audio and `voice.lua` were backed up under
`out/hidden-passage-audio-import-20261027T085705525201Z/backup/`; conversion
hashes, durations and codec details are in the adjacent `evidence.json`.

The three replacement clips' transcripts and queue durations have been updated
in `voice.lua`; the approach-warning caption now describes the enemy closing in,
not shots already fired. The owner subsequently requested **all recordings be
included at their matching cues**: the eight new core hooks and six fighter-role
hooks are now implemented, and all 27 clips are registered and embedded in the
client operational mission. The original CAS/CAP activation rules are unchanged.

Calls are queued without overlap. Boarding and urgent pickup warnings precede
queued routine intel. Stale calls are checked again at playback, and mission
failure clears pending crew/success/intel calls before its once-only abort report.
An already playing clip finishes first; DCS outSound cannot be cancelled here.
Target-destroyed reports require all tracked spawned units to be destroyed, with
life checks and death/crash/unit-lost events; disappearance alone does not count.
Pilot reports require a human in the matching role at detection and playback.
Offline checks pass; actual radio delivery and pacing still need a live run.

## Cast

Keep the four existing voice presets and add two, rather than a different voice
for every aircraft. No provider-specific voice IDs are assumed here.

| Voice / preset | Character and delivery | Use |
|---|---|---|
| **Overlord** — existing | Calm, concise mission controller. Urgent without shouting. | Assignments, intelligence, threat updates, success and failure. |
| **Heli Pilot** — existing | Professional cockpit/radio voice. Short, clear requests. | Mule One and Raven One smoke requests; record the correct callsign variant. |
| **Heli Crew Chief** — existing | Direct cabin/intercom voice. Firm under pressure, easy to understand. | Boarding instructions and permission to lift, for whichever helicopter carries the party. |
| **HVT** — existing | Keep the existing woman's voice. Calm but tense normally; breathless and urgent under fire, not constantly screaming. | Ground-party warnings, smoke replies and passenger headcount. She speaks for all three sources. |
| **CAS Pilot** — new, recommended | Measured, practical fighter/attack pilot. Distinct from the helicopter pilot. | Optional CAS departure and verified ground-target reports. Shared by Hornet and Warthog. |
| **CAP / SEAD Pilot** — new, recommended | Crisp, focused fighter pilot. Distinct from CAS; restrained confidence. | Optional CAP departure and verified air-threat reports. Shared by Hornet and Viper. |

The pilot recordings are scripted radio flavour for **human-occupied roles**, not
new AI Blue aircraft. Their proposed playback needs occupancy checks; do not
play a human pilot's departure/report if that role is unoccupied.

## Recording instructions

- Generate **one clip per filename**. Copy only the quoted line into the speech
  generator; delivery directions and trigger notes are not spoken.
- Preserve the existing voice presets/accents for the four returning speakers.
  Use the same new preset consistently for each fighter role.
- Generate clean speech with no music, gunfire or heavy radio effects. Any radio
  treatment can be applied consistently afterwards; cabin calls should remain
  distinguishable from radio traffic.
- Pronunciation: **Mule One**, **Raven One**, **Overlord**; Hatay approximately
  **hah-TIE**; Kub **koob**; **CAS** as “cass”; **CAP** as “cap”; **SEAD** as
  “seed”; **RPG** as the three letters. Do not speak filenames or internal zone
  names such as `OHP-Hatay-Return`.
- Final mission assets must be **Ogg Vorbis `.ogg`**, not another codec renamed
  `.ogg`. Keep a little breathing room at each end without long silence.
- The source destination is
  `src/missions/operation-hidden-passage/sounds/`; shipping uses `Sounds/OHP/`.
- Existing filenames below deliberately match the current assets. Replacing a
  recording requires measured durations and updated transcripts in `voice.lua`.
  Its audio queue uses durations to prevent overlaps. The guarded updater also
  requires explicit approval to replace differing existing recordings.
- Do not stack all first-takeoff announcements on top of each other. Queue
  applicable calls; suppress absent roles. Keep threat announcements concise.

## What is already wired?

There are **27 wired recordings**, and the source folder contains all **27 clips**
listed here. The departure and early HVT-warning replacements
are imported and their source metadata is updated. The four retained entries
must keep their existing recordings.

The core list contains **21 clips**: 13 existing filenames and 8 new filenames.

| Status below | Meaning |
|---|---|
| **Existing audio cue** | The original event hook remains; the three replacement recordings and their metadata are updated. Other original clips are retained. |
| **Integrated audio cue** | A newly recorded line is connected to its specified event; existing threat/status text is retained. |
| **Integrated fighter-role cue** | A role-specific departure or destruction report, approved with the full voice integration. |

Routine F10 instructions, script errors, re-slot diagnostics and detailed failure
reasons should remain text. This is the mission's spoken script, not a voiced
copy of every status message.

## Filename checklist — save recordings using these exact names

Save final Ogg Vorbis files in
`C:\Projects\dcs-missions\src\missions\operation-hidden-passage\sounds\`.
The entry number below matches the full recording instructions and spoken line.
Do not include the entry number or voice name in the filename.

**If the generator exports only WAV or MP3, use the same basename with its real
extension first, then convert to Ogg Vorbis. Do not just rename it `.ogg`.**
Keep unconverted masters outside the mission's `sounds/` folder.

| Entry | Exact final filename | Voice | Asset |
|---|---|---|---|
| 01 | `mule-one-cleared-for-pickup.ogg` | Overlord | Existing; revised line |
| 02 | `raven-one-cleared-for-support.ogg` | Overlord | Existing; revised line |
| 03 | `overlord-cas-convoy-tasking.ogg` | Overlord | New core |
| 04 | `overlord-cas-checkpoint-tasking.ogg` | Overlord | New core |
| 05 | `overlord-sead-tasking.ogg` | Overlord | New core |
| 06 | `overlord-kub-neutralised.ogg` | Overlord | New core |
| 07 | `overlord-fighters-launching.ogg` | Overlord | New core |
| 08 | `overlord-hind-launching.ogg` | Overlord | New core |
| 09 | `mule-one-hvt-under-fire.ogg` | HVT | Existing; revised line |
| 10 | `hvt-taking-fire.ogg` | HVT | New core |
| 11 | `mule1-smoke-request.ogg` | Heli Pilot | Existing |
| 12 | `raven-smoke-request.ogg` | Heli Pilot | Existing |
| 13 | `popping-green-smoke-normal.ogg` | HVT | Existing |
| 14 | `popping-green-smoke-under-fire.ogg` | HVT | Existing; urgent performance |
| 15 | `boarding-start.ogg` | Heli Crew Chief | Retain existing recording |
| 16 | `uh60-boarding-start.ogg` | Heli Crew Chief | Existing |
| 17 | `boarding-hvt-aboard.ogg` | HVT | Existing |
| 18 | `boarding-confirm.ogg` | Heli Crew Chief | Retain existing recording |
| 19 | `uh60-boarding-complete.ogg` | Heli Crew Chief | Retain existing recording |
| 20 | `hidden-passage-success.ogg` | Overlord | Retain existing recording |
| 21 | `overlord-extraction-failed.ogg` | Overlord | New core |
| O1 | `cas-departure.ogg` | CAS Pilot | Disabled; asset retained |
| O2 | `cap-departure.ogg` | CAP / SEAD Pilot | Disabled; asset retained |
| O3 | `cas-convoy-destroyed.ogg` | CAS Pilot | Integrated fighter-role cue |
| O4 | `cas-checkpoint-cleared.ogg` | CAS Pilot | Integrated fighter-role cue |
| O5 | `cap-fighters-destroyed.ogg` | CAP / SEAD Pilot | Integrated fighter-role cue |
| O6 | `cap-hind-destroyed.ogg` | CAP / SEAD Pilot | Integrated fighter-role cue |

## Core recordings

### 01 — Chinook departure

- **File:** `mule-one-cleared-for-pickup.ogg`
- **Voice:** Overlord — composed assignment.
- **When:** First recognised takeoff of Mule One; once per run, to its crew.
- **Status:** Existing audio cue with the new recording and updated metadata.
- **Why:** Departure does not prove that the SAM or checkpoint is neutralised.
  The legacy filename does not mean this is clearance to enter a safe LZ.

> Mule One, Overlord. The package is standing by at the pickup. Coordinate your approach with the flight.

### 02 — Blackhawk departure

- **File:** `raven-one-cleared-for-support.ogg`
- **Voice:** Overlord — same controller and tone as 01.
- **When:** First recognised takeoff of Raven One; once per run, to its crew.
- **Status:** Existing audio cue with the new recording and updated metadata.
- **Why:** Raven can perform the extraction itself, even without Mule occupied.

> Raven One, Overlord. You're assigned to the extraction package. Cover the approach and departure, and stand by for pickup.

### 03 — CAS convoy assignment

- **File:** `overlord-cas-convoy-tasking.ogg`
- **Voice:** Overlord — calm, professional, routine intelligence update; no panic
  or theatrical urgency. Replaced with the supplied calmer take.
- **When:** The CAS convoy successfully spawns under the frozen first-Blue-takeoff
  decision. Once, to Blue; silent if CAS is disabled or the spawn fails.
- **Status:** Integrated audio cue at the existing convoy-spawn event.

> CAS, Overlord. An armed convoy is moving toward the pickup. Intercept it along the road. Keep your attacks clear of the extraction party.

### 04 — RPG checkpoint assignment

- **File:** `overlord-cas-checkpoint-tasking.ogg`
- **Voice:** Overlord — emphasise the threat, not theatrical urgency.
- **When:** The CAS RPG checkpoint successfully spawns after validated confirmation
  that all three HVTs are aboard either helicopter. Once, to Blue, after queued
  crew confirmation; independent of convoy spawn/destruction. The temporary
  solo-test bypass deliberately simulates only this CAS stage release.
- **Status:** Replaced recording and delayed checkpoint-spawn cue.

> CAS, Overlord. The package is aboard. RPG infantry are holding the north-road checkpoint. Clear that position and cover the helicopters' departure.

### 05 — SEAD assignment

- **File:** `overlord-sead-tasking.ogg`
- **Voice:** Overlord — measured warning and task.
- **When:** A CAP role was occupied at the first Blue takeoff, the Kub successfully
  spawned, and its tracking radar was identified. Once, to Blue.
- **Status:** Integrated audio cue at the existing SAM-spawn/radar-tracking event.

> CAP, Overlord. A Kub SAM site is active near the pickup. Destroy its tracking radar before the helicopters approach, then cover the extraction corridor.

### 06 — Kub radar destroyed

- **File:** `overlord-kub-neutralised.ogg`
- **Voice:** Overlord — factual confirmation, no victory speech.
- **When:** All tracked radars in the spawned Kub group are destroyed. Once, at
  the existing transition that releases the enemy air response.
- **Status:** Integrated audio cue at the existing radar-kill transition.
- **Guard:** Radar silence or destroyed support vehicles does not qualify. This
  is **not** an announcement that every SAM or LZ threat is gone.

> All stations, Overlord. The Kub tracking radar is down. CAP, cover the extraction corridor. Helicopter crews, remain alert for other threats.

### 07 — Enemy fighter launch warning

- **File:** `overlord-fighters-launching.ogg`
- **Voice:** Overlord — focused warning.
- **When:** The enemy fighter group successfully spawns at its airfield after the
  radar kill. Once, to Blue; queue after 06.
- **Status:** Integrated audio cue at the existing fighter-spawn event.
- **Guard:** Spawn is not confirmation of wheels-up. No invented bearing, range
  or “fighters airborne” report before actual takeoff.

> CAP, Overlord. Enemy fighters are preparing to launch. Expect an interception. Protect the extraction package.

### 08 — Enemy Hind launch warning

- **File:** `overlord-hind-launching.ogg`
- **Voice:** Overlord — caution about a separate, low-level threat.
- **When:** The Hind is spawned/ready and all spawned fighters are confirmed
  destroyed. Once, to Blue, after the additional 20-second reporting pause.
- **Status:** Gated handoff; actual Hind spawn still accompanies the fighters
  after the radar kill. Existing wording retained at the owner's request.
- **Guard:** Do not claim it has already intercepted, seen or fired on the Chinook.

> All stations, Overlord. An enemy Hind is preparing to launch. Watch for a low-level threat along the extraction corridor.

### 09 — Ground party sees the enemy closing in

- **File:** `mule-one-hvt-under-fire.ogg`
- **Voice:** HVT — frightened, urgent, still intelligible.
- **When:** The first eligible outbound extraction helicopter crosses the existing
  contact-distance trigger. Operational mission: three nautical miles from pickup;
  retained short Testing layout: halfway. Once, to Blue.
- **Status:** Existing audio cue with the new approach-warning recording and caption.
- **Why:** This trigger starts the hostile approach; it does not confirm shots
  have started. Despite the legacy filename, use an approach warning here. Avoid
  addressing only Mule because Raven can trigger this without a Chinook pilot.

> Overlord, they're closing in on us! All three of us are still here. We need that helicopter!

### 10 — Actual firefight begins

- **File:** `hvt-taking-fire.ogg`
- **Voice:** HVT — sharper and more breathless than 09; not an unintelligible scream.
- **When:** The primary enemy reaches the existing firefight engagement gate
  within 400 metres (nearest surviving soldier), and the mission enables the
  exchange. Once, to Blue. The gate was widened after the 2026-10-27 Mule test;
  see [flight-test findings](hidden-passage-flight-tests.md).
- **Status:** Integrated audio cue at the existing combat gate; contact text retained.
- **Guard:** Use this at the engagement gate, not the earlier three-mile warning.
  It follows the scripted combat state, not detection of each individual bullet.

> They're firing on us! We're keeping our heads down. Get us out of here!

### 11 — Chinook requests smoke

- **File:** `mule1-smoke-request.ogg`
- **Voice:** Heli Pilot — controlled radio request.
- **When:** Mule's crew chooses F10 **Request green smoke**; to that aircraft.
- **Status:** Existing audio cue; retain its current wording.

> Ground, Mule One on final. Requesting green smoke at the pickup.

### 12 — Blackhawk requests smoke

- **File:** `raven-smoke-request.ogg`
- **Voice:** Heli Pilot — same delivery as 11, correct callsign.
- **When:** Raven's crew chooses F10 **Request green smoke**; to that aircraft.
- **Status:** Existing audio cue; retain its current wording.

> Ground, Raven One on final. Requesting green smoke at the pickup.

### 13 — Ground smoke reply, normal

- **File:** `popping-green-smoke-normal.ogg`
- **Voice:** HVT — tense but composed, speaking clearly.
- **When:** Reply to either helicopter's smoke request while the primary firefight
  is not active. To the requesting aircraft only.
- **Status:** Existing audio cue; retain its current wording.
- **Timing:** Existing queue waits five seconds after the pilot clip and its
  safety tail. Do not bake those five seconds into the recording.

> Copy. Popping green smoke now.

### 14 — Ground smoke reply, under fire

- **File:** `popping-green-smoke-under-fire.ogg`
- **Voice:** HVT — hurried, breathless, forcing the words out clearly.
- **When:** Same request/reply as 13, but the primary firefight is active.
- **Status:** Existing audio cue. Same words as 13, a distinct performance.
- **Timing:** Same five-second queue gap; do not render extra silence.

> Copy! Popping green smoke now!

### 15 — Chinook boarding starts

- **File:** `boarding-start.ogg`
- **Voice:** Heli Crew Chief — firm cabin instruction to the flight crew.
- **When:** The Chinook claims the party and boarding begins; to its crew only.
- **Status:** **Retain existing recording by owner decision.** Do not regenerate.
  The quote is the existing code transcript, not a fresh transcription.
- **Guard:** This is not permission to take off.

> Personnel boarding. Remain landed until the party disappears and 'Three personnel aboard' appears.

### 16 — Blackhawk boarding starts

- **File:** `uh60-boarding-start.ogg`
- **Voice:** Heli Crew Chief — raised voice, addressing the boarding party.
- **When:** The Blackhawk claims the party and boarding begins; to its crew only.
- **Status:** Existing audio cue; retain its current wording.

> Package, move to the helicopter! You're clear to board. Go, go, go!

### 17 — Passenger headcount

- **File:** `boarding-hvt-aboard.ogg`
- **Voice:** HVT — breathless relief, still in danger.
- **When:** All three are confirmed aboard, in either extraction helicopter.
  To the actual carrier's crew; followed by its crew-chief confirmation.
- **Status:** Existing audio cue; retain its current wording.

> All three aboard.

### 18 — Chinook cabin secure

- **File:** `boarding-confirm.ogg`
- **Voice:** Heli Crew Chief — decisive cabin report.
- **When:** Confirmed boarding in the Chinook; queued after 17, to its crew only.
- **Status:** **Retain existing recording by owner decision.** Do not regenerate.
  The quote is the existing code transcript, not a fresh transcription.
- **Guard:** Boarding confirmation, not “the area is clear.” Enemies may remain.

> Three personnel aboard. Return to Hatay and unload inside OHP-Hatay-Return.

### 19 — Blackhawk cabin secure

- **File:** `uh60-boarding-complete.ogg`
- **Voice:** Heli Crew Chief — urgent but confident.
- **When:** Confirmed boarding in the Blackhawk; queued after 17, to its crew only.
- **Status:** **Retain existing recording by owner decision.** Do not regenerate.
  The quote is the existing code transcript, not a fresh transcription.

> All three aboard! Doors closing. Let's get out of here!

### 20 — Successful delivery

- **File:** `hidden-passage-success.ogg`
- **Voice:** Overlord — restrained relief and acknowledgement.
- **When:** The actual carrier lands at Hatay and successfully unloads all three
  inside the receiving area. Once, to Blue, after any queued boarding calls.
- **Status:** **Retain existing recording by owner decision.** Do not regenerate.
  The quote is the existing code transcript, not a fresh transcription.
- **Guard:** Returning to base or touching down alone is insufficient. Unloading
  remains manual through F10. No forced mission exit is implied.

> Operation Hidden Passage complete. All three personnel delivered safely to Hatay.

### 21 — Extraction failed

- **File:** `overlord-extraction-failed.ogg`
- **Voice:** Overlord — serious and controlled, no theatrical shouting.
- **When:** The existing extraction objective first enters its failed state.
  Once, to Blue. Keep the specific reason on screen.
- **Status:** Integrated audio cue at the existing failure transition.
- **Guard:** A lost fighter, surviving SAM or failed optional template does not
  automatically mean the extraction objective has failed. Silence/drop stale
  queued boarding or success calls after failure when integrating this line.

> All stations, Overlord. The extraction has failed. Abort the operation.

## Fighter-role recordings — integrated

These **six extra clips** give the two new voices a purpose. Originally proposed
as optional additions, they are now integrated at the owner's request alongside
the core 21. The `O1`–`O6` labels are retained to match the recording checklist.

They are not new prerequisites for boarding or extraction. Use “position destroyed,” not
“I killed it,” so reports do not falsely award kills to a particular player.

### O1 — CAS departure

- **Status:** Disabled; no playback. Retained take and former cue documented below.
- **File:** `cas-departure.ogg`
- **Voice:** CAS Pilot — practical, ready to work.
- **When:** First human takeoff in an enabled CAS role, once for the role, to
  Blue. The convoy must be active and the checkpoint stage must still be waiting
  for pickup. The pilot must remain in that aircraft and airborne when the queued
  call plays. No longer requires an already spawned checkpoint.
- **Guard:** No claim that the pilot is already over the village. If both CAS
  aircraft fly, this generic line should not be played twice in succession.

> Overlord, CAS airborne. Moving to intercept the convoy.

### O2 — CAP / SEAD departure

- **Status:** Disabled; no playback. Retained take and former cue documented below.
- **File:** `cap-departure.ogg`
- **Voice:** CAP / SEAD Pilot — crisp, composed.
- **When:** First human takeoff in an enabled CAP role, once for the
  role, to Blue. Only use while the Kub is still active; suppress after its loss.
- **Guard:** Do not re-enable threats if CAP joins after the frozen decision.

> Overlord, CAP airborne. We'll deal with the Kub, then cover the extraction corridor.

### O3 — Convoy destroyed

- **File:** `cas-convoy-destroyed.ogg`
- **Voice:** CAS Pilot — concise report.
- **When:** The successfully spawned convoy transitions to all units
  destroyed; once, to Blue, while a CAS role remains human-occupied.
- **Guard:** The lead BTR dying, vehicles stopping, or losing sight of the convoy
  does not qualify. Missing objects alone are not proof of destruction.

> Overlord, CAS. The convoy is destroyed.

### O4 — RPG checkpoint cleared

- **File:** `cas-checkpoint-cleared.ogg`
- **Voice:** CAS Pilot — useful confirmation for the helicopter crews.
- **When:** All eight infantry in the successfully spawned checkpoint
  are confirmed destroyed; once, to Blue, while a CAS role is human-occupied.
- **Guard:** This conservative “clear” report does not fire just because one RPG
  soldier dies. It does not declare the village or landing area entirely safe.

> Overlord, CAS. The north-road checkpoint is clear. Keep watching for other threats on the approach.

### O5 — Enemy fighters destroyed

- **File:** `cap-fighters-destroyed.ogg`
- **Voice:** CAP / SEAD Pilot — focused, no celebration.
- **When:** Both aircraft in the successfully spawned enemy fighter
  group are confirmed destroyed; once, to Blue, while CAP is human-occupied.
- **Guard:** Not when the group is still inactive, returning to base or merely
  outside detection range. It says nothing about the Hind or other aircraft.

> Overlord, CAP. Both enemy fighters are down. Continuing cover for the extraction.

### O6 — Hind destroyed

- **File:** `cap-hind-destroyed.ogg`
- **Voice:** CAP / SEAD Pilot — short, reassuring confirmation.
- **When:** The one successfully spawned Hind is confirmed destroyed;
  once, to Blue, while CAP is human-occupied.
- **Guard:** Not “lost contact,” not landed, and not a blanket all-clear.

> Overlord, CAP. The Hind is down. Continuing cover for the helicopters.

## Integration and recording checklist

1. Retain entries 15, 18, 19 and 20. The departure and early-warning replacements
   are imported; six other unchanged original clips were also retained.
2. The eight new core files are integrated: CAS convoy/checkpoint tasking, SEAD
   tasking, Kub neutralised, fighter/Hind launch warnings, actual taking-fire and
   extraction failed.
3. O1–O6 are integrated using the two additional pilot voices; no Blue AI aircraft
   were added. Missing/unoccupied roles remain silent.
4. Listen for callsigns, Hatay/Kub pronunciation, clipping and accidental spoken
   directions. Verify that the two smoke-reply performances are distinct.
5. All 27 assets decode successfully, and their queue durations cover their measured
   lengths. Crew calls remain carrier-only; urgent calls jump routine backlog.
6. Offline CAS-only, CAP-only, helicopter-only, combined-role, Raven-only, failure
   and successful-delivery checks pass. **Live playback/pacing remains to test.**

Source references checked for this script: `voice.lua`, `transport-test.lua` and
`operation.lua` under `src/missions/operation-hidden-passage/`.
