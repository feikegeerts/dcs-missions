# Operation Hidden Passage

**Fighters first, then the existing Hind call — 2026-10-27:**
Client `transport-cap-hind-handoff-1` leaves actual spawns unchanged: Kub radar
destruction releases both the runway-ready MiGs and the authored hot-parking
Hind. Only CAP's announcement sequence changes. Overlord's existing Hind clip
and matching on-screen text are held until **every tracked spawned fighter is
confirmed destroyed**, followed by the normal **20-second minimum reporting
pause**. The gate uses verified unit deaths/life, not the pilot destruction
recording playing, landing, RTB, disappearance, a missing template or failed
spawn. The Hind is still active and can threaten helicopters during the fighter
task. At the owner's explicit request, the original **"preparing to launch"**
recording/text is unchanged, even if its wording is no longer literal by then.

Handoff is once-only. Both destruction reports are observed before deciding
whether a live Hind still needs tasking, so simultaneous fighter/Hind losses
cannot create stale tasking. Pending Hind text/audio are dropped on Hind loss
or objective failure/completion. A Hind that becomes ready after the fighters
are already destroyed can still receive the handoff without another spawn.
Readiness now requires all authored aircraft units before taking the tracking
snapshot, so an asynchronously appearing wingman cannot be omitted. If the
fighters never spawn/never have confirmed deaths, the Hind call remains held;
there is no invented fighter-clearance fallback.

160 source/shipping adapter checks, 11 objective checks, 23 packaging tests,
five audio tests, 15 DTC tests, layout guards, Lua 5.1 syntax and StyLua pass.
Regressions cover two-versus-one kills, no early text/audio, the subsequent
20-second pause, duplicate observation, despawn/error paths, simultaneous Hind
loss, terminal mission states, delayed Hind birth and partial fighter birth.
The approved five-second checkpoint tasking and other reporting delays remain
unchanged. **Live handoff/pacing remains unverified**; reload from disk.

Client/generated SHA-256:
`48e6a5414b44753d76b92942e88d4808c11cceaafabddbba940452439b21c623`.
Only `l10n/DEFAULT/OHP-main.lua` changed. The Hind recording and every other
audio member, editor mission/routes, waypoint edits, DTCs, briefing and unrelated
members remain byte-identical. Dedicated-server/Testing archives are unchanged.
Verified backup:
`C:\Users\g_for\Saved Games\DCS\Backups\Operation-Hidden-Passage\Operation Hidden Passage-before-voice-20261027T183634818522Z.miz`
(input SHA-256 `223c0353db8dfed3ddb6a273225af6d7e27b040f0cc752a16debf09bc249d5ce`).
Evidence: `out/operation-hidden-passage-evidence.json`.

**Overlord latency, five-second checkpoint exception and runway scramble — 2026-10-27:**
Client `transport-overlord-latency-scramble-2` enforces reporting latency in the
voice registry, including direct callers:

- **20 seconds minimum:** Kub radar destroyed, fighter/Hind launch preparation,
  mission success and mission failure (`config.overlord_confirmation_delay_s`).
- **5 seconds minimum:** checkpoint tasking after confirmed full pickup
  (`config.cas.checkpoint_tasking_delay_s`). The owner explicitly shortened this
  exception because the helicopter may reach the checkpoint within 20 seconds.

Outcome text is queued with its recording and uses the same stale-call guards;
it cannot reveal the event instantly while the audio waits. Failure text keeps
its observer deadline. An occupied clip/crew queue can extend the minimum pause;
there is no additional reporting pause after a queued clip starts. Checkpoint
tasking has priority over routine intelligence so a pending 20-second report
cannot strand the five-second task, but it cannot interrupt active audio or
jump urgent crew calls. Initial convoy/SEAD assignments, helicopter clearances,
pilot destruction reports, direct HVT contact/smoke calls and crew boarding
confirmations retain their timing. Objective transitions, validated pickup,
checkpoint activation and radar-kill-triggered spawns remain immediate.
Failure cancels pending text/audio immediately. No dialogue or recording changed.

The [latest CAP flight](hidden-passage-flight-tests.md#2026-10-27--solo-cap-hornet-kub-kill-and-slow-scramble)
measured almost seven minutes from radar death to first MiG takeoff. The owner
approved changing **only the MiGs** from hot parking to runway-ready. Runtime
uses the template's authored airfield ID and pinned MOOSE
`SpawnAtAirbase(..., SPAWN.Takeoff.Runway, nil, nil, false)`. This changes spawned
departure placement/start, not subsequent waypoints, departure tasks, skills or
payloads; the dormant editor template remains exact. There is **no airborne
fallback** if the runway cannot accommodate the group. The Hind keeps its
authored hot-parking start/route. Switch: `config.cap.fighters_runway_start`.

The same run exposed false `spawned without live units` errors for both air
groups: DCS created them after `Spawn` returned. The adapter now retains each
spawner/wrapper and checks readiness every second for at most ten seconds
(`config.cap.spawn_ready_timeout_s`) before declaring failure. Successful
readiness installs once-only launch warnings/destruction tracking. Readiness
retries never repeat the actual spawn; errors stay independent so the other
group can proceed. Launch-report latency starts from verified readiness.

Verification: 154 source/shipping adapter, 11 objective, 23 packaging, five audio
and 15 DTC checks, actual layout guard, Lua 5.1 syntax and StyLua pass. The pinned
MOOSE runway path is exercised against the actual archive's fighter template:
only departure fields/placement change; airborne route, tasks, payloads and
editor template remain exact. Tests cover 20/5-second latency through direct
callers, text timing, checkpoint queue priority, immediate mission transitions,
cancellation, non-overlap, asynchronous birth/timeout and no airborne fallback.
**Faster live runway timing and radio pacing remain unverified.** Reload from
disk for acceptance; dedicated-server/Testing copies were not updated.

Client/generated SHA-256:
`223c0353db8dfed3ddb6a273225af6d7e27b040f0cc752a16debf09bc249d5ce`.
Only `l10n/DEFAULT/OHP-main.lua` changed; editor data, saved waypoint edits,
CAP DTCs, briefing, audio and other archive members remain byte-identical.
Verified backup of the preceding 20-second-checkpoint version:
`C:\Users\g_for\Saved Games\DCS\Backups\Operation-Hidden-Passage\Operation Hidden Passage-before-voice-20261027T180935026184Z.miz`
(SHA-256 `e646618a7189829c29b69a6bbd201b22e7d93d53ef2ca9dcf1d15613ca44d0dc`).
That preceding version was backed up before its deployment at:
`C:\Users\g_for\Saved Games\DCS\Backups\Operation-Hidden-Passage\Operation Hidden Passage-before-voice-20261027T153610861744Z.miz`
(SHA-256 `1b80edbadceffc947dbb5c4773e8f726a78371136f93e6e3e97212c4926c60b5`).
Current evidence: `out/operation-hidden-passage-evidence.json`.

**Delayed Overlord failure report — 2026-10-27:**
Client `transport-failure-report-delay-1` adds a **20-second reporting pause**
before the automatic failure text and Overlord's extraction-failed recording.
This applies to operation failure reports, including HVT casualties before
pickup or during boarding. The objective fails immediately: boarding/delivery
cannot succeed during the pause. Pending crew/success/intelligence calls are
cancelled immediately and new chatter is refused. A recording already playing
cannot be interrupted; the abort waits for it as well as the 20-second minimum.
The first detection fixes the deadline; repeated observer/callback checks do
not postpone it or create duplicate reports. The existing one-second observer
publishes the automatic text after the deadline. Explicit F10 status queries
still expose the actual failed objective without pretending it remains active.
The pause is configured by `config.failure_report_delay_s = 20`; no recordings
or their approved volume were changed.

Verification: 145 source/shipping adapter checks, 11 objective checks, 23
packaging tests, five audio tests, 15 DTC tests, actual archive layout guard,
Lua 5.1 syntax and StyLua pass. Tests cover HVT loss before pickup/during
boarding, no early text/audio, one fixed deadline, cancellation during the
pause, once-only reporting and retained non-overlap. Live pacing remains to
confirm after reloading the mission from disk. Only `l10n/DEFAULT/OHP-main.lua`
changed: editor mission/waypoint edits, both CAP DTC files, briefing, all audio
and every other member are byte-identical. Dedicated-server/Testing copies
are unchanged.

Client/generated SHA-256:
`1b80edbadceffc947dbb5c4773e8f726a78371136f93e6e3e97212c4926c60b5`.
Verified pre-update backup:
`C:\Users\g_for\Saved Games\DCS\Backups\Operation-Hidden-Passage\Operation Hidden Passage-before-voice-20261027T150727512374Z.miz`
(input SHA-256 `8a80aadadc58ca37d5538e598d18bd1132d387c92b0e0ee083b64aae8251f33d`).
Evidence: `out/operation-hidden-passage-evidence.json`.

**CAP native threat cartridges deployed — 2026-10-27:**
After the owner saved waypoint-height edits, the metadata-only updater added
`DTC/OHP-CAP-HORNET.dtc` and `DTC/OHP-CAP-VIPER.dtc`, assigned as default
auto-load cartridges only to `CAP-Hornet` and `CAP-Viper`. Both include six
known visible SAM sites: Ground-1/2 (SA-10), Ground-3/9 (SA-6) and Ground-7/8
(SA-8). Including the other sites avoids replacing legacy rings with an
incomplete custom threat list. The LZ Kub's native planning radius is 25,000 m
(about 13.5 NM). These are static intelligence rings, not live emitter tracks:
they neither activate the Kub nor disappear automatically when it is destroyed.
The Kub remains late-activated and conditional on frozen CAP participation.

Hornet uses `SA.MEZ_THRTS` with radii in NM; Viper uses `MPD.THREAT_PTS` with
radii in metres and authored ground-route elevations, not aircraft heights.
Threat-only partitions and mirror flags retain mission navigation; no radio
or countermeasure partitions are supplied. Exact semantic comparison permits
only the two CAP unit `DTC` fields to change. All saved waypoint coordinates,
altitudes/types, aircraft settings, loadouts, routes, activation flags and
briefing remain exact; every other existing archive member, including scripts
and all recordings, remains byte-identical. No gameplay version was changed.

Verification: 15 DTC tests (including sandbox regression/guards and installed
native importer checks), 23 packaging tests (including subsequent gameplay
updates preserving DTCs), five audio tests, 141 source/shipping adapter checks,
11 objective checks, actual operational layout guard, Lua 5.1 syntax and
StyLua checks pass. The deployed cartridges pass both installed editor
`setData` importers with six threat points each. This tests data import, **not
live avionics rendering or automatic loading**.

Live acceptance:
1. Reopen `Saved Games\DCS\Missions\Operation Hidden Passage.miz` from disk;
   do not save an older in-memory editor copy over it.
2. Start in CAP Hornet and check SA for the planned SA-6 ring near the pickup
   area while still parked, before the first human Blue takeoff.
3. Repeat in CAP Viper and check HSD threat points/rings at a suitable display
   range. Confirm navigation remains as authored in both aircraft.
4. Separately confirm CAP takeoff still activates the Kub and radar destruction
   still releases the authored fighters/Hind. A preplanned ring is not proof
   that the SAM has spawned or is radiating.

Client/generated SHA-256:
`8a80aadadc58ca37d5538e598d18bd1132d387c92b0e0ee083b64aae8251f33d`.
Verified pre-update backup, containing the owner's saved waypoint edits:
`C:\Users\g_for\Saved Games\DCS\Backups\Operation-Hidden-Passage\Operation Hidden Passage-before-dtc-20261027T150310607901Z.miz`
(input SHA-256 `daa180a0842c357e0d76977865975c4cbc9f36451c1a4388c0028993304ae324`).
Evidence: `out/operation-hidden-passage-dtc-evidence.json`, including installed
schema/importer hashes. Tool: `build/update-hidden-passage-dtc.py --input
"<saved mission path>"` (add `--deploy` only for installation with backup).
Existing custom/conflicting cartridges are refused rather than overwritten.
Dedicated-server and retained Testing archives are unchanged.

**CAS/CAP pilot departure calls removed — 2026-10-27:**
At the owner's request, client `transport-no-fighter-departures-1` removes the
automatic human-pilot CAS/CAP takeoff acknowledgements. Their event hooks and
role-departure state were removed. `cas-departure.ogg` and `cap-departure.ogg`
remain archived byte-for-byte but are marked disabled in the voice registry,
so even a stale/direct caller cannot enqueue them. There are now **25 enabled
recordings and two disabled retained assets**, not 27 active mission cues.
Overlord's convoy/checkpoint/SEAD and threat taskings remain, as do helicopter
departure clearances, cabin calls and the four target-destruction reports.
Staged CAS activation and the temporary solo F10 option are unchanged.

141 source/shipping adapter, 11 objective, 22 packaging and five audio tests
pass, including first/repeated fighter takeoffs, combined-role tasking and
direct requests for disabled cues. Only the main payload changed; all editor
members, waypoint heights/routes, briefing and every recording are preserved.
The owner will fix Hornet waypoint heights separately. **Reopen the updated
client archive from disk before editing**, rather than saving an old in-memory
mission over it. Dedicated-server/Testing archives are unchanged.

Client/generated SHA-256:
`fdf3c2a21b6355b2dcb6336f5dc40e11b3aa5728aa76cfdeae6f78e1c8f8dfc7`.
Verified pre-update backup:
`C:\Users\g_for\Saved Games\DCS\Backups\Operation-Hidden-Passage\Operation Hidden Passage-before-voice-20261027T132103681624Z.miz`
(input SHA-256 `d899103924d7d7e8db0d808e6f98aeaca23a6db4260354d2079649db5ee773d5`).
Evidence: `out/operation-hidden-passage-evidence.json`.

Latest CAS flight timings and FLIR investigation:
[`hidden-passage-flight-tests.md`](hidden-passage-flight-tests.md). The first
bomb's estimated impact was 7m 07.6s after takeoff, with no confirmed convoy hit.

**Sequential CAS objectives and temporary solo test — 2026-10-27:**
The owner approved **convoy first, checkpoint activation only after pickup**,
not merely delayed checkpoint chatter. Client `transport-cas-sequence-test-1`
keeps the shared first-human-Blue-takeoff CAS/CAP snapshot, but CAS initially
spawns/briefs only the convoy. The checkpoint remains `waiting_for_pickup` until
the existing, validated CTLD extraction receipt confirms all three personnel
aboard Mule or Raven. Boarding start, partial loading, a casualty, an invalid
receipt or convoy destruction alone cannot release the checkpoint. Its authored
eight-person group and patrol spawn once, then its new tasking queues behind
crew boarding confirmation. Missing convoy templates do not disable a later
checkpoint; convoy destruction is **not** a new boarding/delivery prerequisite.
No CAP, firefight, pickup clearance or AWACS behaviour changed.

Three replacements were imported from Downloads, without modifying the MP3s:
`cas-departure (2).mp3`, `overlord-cas-convoy-tasking (2).mp3` and
`overlord-cas-checkpoint-tasking (2).mp3`. CAS departure now mentions only the
convoy; the checkpoint line confirms the package is aboard and directs CAS to
cover helicopter departure. The supplied calmer convoy take replaces the old
one. Final mono 48 kHz Vorbis durations are 3.20, 9.44 and 9.36 s; queue lengths
are 3.4, 9.6 and 9.5 s. New takes retain the approved 90% gain target, measured
against normalized decoded new MP3 references, not the superseded performances.
The other 24 recordings remain byte-identical. Per-file source/reference/render
hashes and measured levels are in `voice-gain.json`; old clips, reference WAVs,
MP3 copies and import evidence are under
`out/hidden-passage-cas-audio-20261027T125309267838Z/`.

### Temporary solo CAS pickup simulation

1. Reload `Saved Games\DCS\Missions\Operation Hidden Passage.miz` from disk.
2. Occupy CAS Hornet (or CAS Warthog) before the first human Blue takeoff. Fly
   the convoy task normally. The checkpoint must not yet spawn or be briefed.
3. With only **one human-occupied Blue aircraft**, in that CAS group, select:
   **F10 > Operation Hidden Passage - TEMP TEST > TEST: Simulate pickup complete
   (CAS stage only)**.
4. Expect an explicit TEST notice, then one checkpoint spawn and its new tasking
   recording. Attack the checkpoint and check the all-units-destroyed report.

This bypass changes only the checkpoint stage: it does not load/delete the
HVTs, claim a helicopter, emit crew boarding confirmations or award success.
The extraction objective remains waiting; a later real extraction can still
proceed and cannot spawn a duplicate checkpoint. The checkpoint voice's aboard
statement is deliberately simulated in this test, not proof of actual CTLD
boarding. Separately test real pickup with Mule/Raven to accept that boundary.
The bypass refuses pre-takeoff, frozen no-CAS/late-join, multiple occupied Blue
aircraft, wrong-group, failed/completed and in-progress-boarding use. Repeated
commands cannot duplicate the stage. **Temporary switch:** set
`config.cas.enable_pickup_test_menu = false` and rebuild/deploy to remove it
after solo acceptance; stale callbacks also check the switch.

Verification: 140 source/shipping adapter checks, 11 objective checks, 22
packaging tests and five audio tests cover both real carriers, delayed native
boarding receipts, failure/duplicate paths, solo bypass guards and all 27 audio
assets/gain levels. Editor mission, routes, briefing and unrelated archive
members were preserved; changed only main payload + three approved clips.
New clips' delivery/tone and staged DCS AI/menu behaviour still need a live run.
Dedicated-server and Testing archives were not updated.

Client/generated SHA-256:
`d899103924d7d7e8db0d808e6f98aeaca23a6db4260354d2079649db5ee773d5`.
Verified pre-update backup:
`C:\Users\g_for\Saved Games\DCS\Backups\Operation-Hidden-Passage\Operation Hidden Passage-before-voice-20261027T125518952304Z.miz`
(input SHA-256 `19817a79d082f5edf40412478a13ffeb76c7725d7a027670872850b286bb33c0`).
Evidence: `out/operation-hidden-passage-evidence.json`.

**All mission voice volume reduced — 2026-10-27:**
The owner clarified that the requested 10% reduction means **volume**, not fewer
calls. Client build `transport-voice-volume-90-1` renders all 27 mission clips
at **90% of their previous level** (approximately -0.915 dB). Dialogue, speakers,
playback conditions, queue durations, sample rates, channels and encoded clip
durations are unchanged. DCS built-in radio/master settings are untouched.
The AWACS waypoint-report suppression remains in place.

This is an explicitly approved volume-only exception to the previous byte-
identity requirement for retained recordings 15, 18, 19 and 20: their spoken
content remains, but all four receive the same reduction as the other clips.
High-quality Vorbis renders were compared with decoded originals; measured RMS
ratios are **0.899264–0.900351** and every correlation exceeds 0.999. Per-file
render gains compensate for small lossy-encoder level changes. Original and
rendered hashes, sample counts, levels and comparisons are recorded in
`src/missions/operation-hidden-passage/voice-gain.json`. Do not attenuate these
already processed source assets again on rebuild.

Source originals: `out/hidden-passage-voice-gain-20261027T121425733903Z/originals/`;
adjacent `evidence.json` records the render, and the one-time recipe is
`out/reduce-hidden-passage-voice-volume.py`. All 133 source/shipping adapter,
11 objective, 22 packaging and five audio tests pass, including decoded-volume
checks for every recording. All 27 packaged audio members and the main payload
were updated; mission/editor layout, briefing and every other archive member
are byte-identical. No members were added. Dedicated-server/Testing copies are
unchanged; reload the client operational mission to hear the reduction.
Live subjective loudness still needs listening acceptance.

Client/generated SHA-256:
`19817a79d082f5edf40412478a13ffeb76c7725d7a027670872850b286bb33c0`.
Verified original mission backup:
`C:\Users\g_for\Saved Games\DCS\Backups\Operation-Hidden-Passage\Operation Hidden Passage-before-voice-20261027T121551944481Z.miz`
(input SHA-256 `f8eb73af5c7cb54f8b9312b305ad1b659aecaca24b9bac4d80592bea7d065c95`).
Evidence: `out/operation-hidden-passage-evidence.json`.

**AWACS waypoint reports disabled — 2026-10-27:**
The owner reported improved approach/pickup behaviour on the next run and asked
to stop the AWACS aircraft's checkpoint/waypoint announcements. Client build
`transport-awacs-quiet-1` identifies the existing `Overlord` E-3A group and calls
MOOSE `SetOptionWaypointPassReport(false)` at setup. The pinned implementation
sets `PROHIBIT_WP_PASS_REPORT=true`; it does not set general radio silence or
replace the AWACS task/route. Normal AWACS service, datalink and all recorded
Overlord mission cues are retained. An absent/dead AWACS or an option error
cannot stop extraction setup. No other aircraft are affected.

133 source/shipping adapter checks pass, including the actual pinned MOOSE
option method, recorded cue playback and missing/dead/controller-error cases;
11 objective, 22 packaging and four audio tests also pass. Only
`l10n/DEFAULT/OHP-main.lua` changed; all other archive members, including the
editor AWACS settings/route and all 27 recordings, are byte-identical. Reload
the client mission for this change; live suppression still needs confirmation.
Dedicated-server and Testing copies are unchanged.

Client/generated SHA-256:
`f8eb73af5c7cb54f8b9312b305ad1b659aecaca24b9bac4d80592bea7d065c95`.
Verified backup:
`C:\Users\g_for\Saved Games\DCS\Backups\Operation-Hidden-Passage\Operation Hidden Passage-before-voice-20261027T120938558903Z.miz`
(input SHA-256 `f43abdc0dccd14791d7a03a119d59a64a0d0f8d051469922f75251fe3b5b1a02`).
Evidence: `out/operation-hidden-passage-evidence.json`.

**Solo Mule live-test follow-up — 2026-10-27:**
The [dated flight-test report](hidden-passage-flight-tests.md#2026-10-27--solo-mule-one-approach-and-failed-pickup)
records **15m 39.640s takeoff to touchdown**, the 3 NM approach trigger, the
missed firing gate, landing measurements and the confirmed boarding casualty.
`transport-approach-lz-1` is now installed in the client Missions folder: boarding
range is **125 m** (still 35 m clear of each person), and the inbound exchange
starts when the nearest surviving enemy reaches **400 m** after the 3 NM trigger.
No enemy placements, authored routes, audio, briefing or HVT protection rules
were changed. Only the embedded main script changed; backup and hashes are in
the flight-test report. The 130 source/shipping adapter, 11 objective, 22
packaging and four audio tests pass. Fresh live acceptance of these fixes is
still required; dedicated-server/Testing archives remain unchanged.

Voice-generation script, casting, playback cues and exact audio filenames:
[`hidden-passage-voice-script.md`](hidden-passage-voice-script.md). All 27 listed
recordings are now integrated; original and newly added cues are distinguished.

**Full voice integration deployed — 2026-10-27:**
`transport-firefight-voice-1` packages and wires all 27 recordings, including the
owner's 17 new MP3s converted to Ogg Vorbis. Fourteen assets are new; the two
helicopter departure calls and early HVT approach warning are replaced. The
other ten original assets are byte-identical, specifically retained entries
15 (`boarding-start.ogg`), 18 (`boarding-confirm.ogg`), 19
(`uh60-boarding-complete.ogg`) and 20 (`hidden-passage-success.ogg`). Downloads
were not modified. Import backups and measured durations are recorded in the
voice script and `out/hidden-passage-audio-import-20261027T085705525201Z/`.

New audio covers CAS convoy/checkpoint tasking, SEAD tasking, Kub neutralised,
enemy fighter/Hind launch warnings, actual firefight contact and extraction
failure. The owner also approved the six originally optional pilot calls:
one departure per enabled CAS/CAP role and once-only convoy/checkpoint/fighter/
Hind destruction reports. Reports track the actual spawned units, requiring all
of them destroyed, not just the lead vehicle, radar silence, landing, RTB or
disappearance. DCS dead/crash/unit-lost events cover already removed objects;
known life below 1 covers retained wrecks. Query failures suppress reports and
retry without failing the extraction. A matching human role must be occupied
when a destruction report is detected and again when it plays. Calls skipped
because the role was absent are not replayed on a later join.

The shared first-human-Blue-takeoff participation decision, staged enemy spawns,
all editor routes/loadouts and extraction ownership/boarding rules remain
unchanged. No Blue AI aircraft or new objective prerequisites were added.
Routine intelligence remains FIFO; urgent contact and cabin/boarding calls
jump queued routine calls without interrupting an already playing clip. Crew
calls remain carrier-only, smoke replies retain their five-second gap, and
stale calls are rechecked at playback. Failure invalidates old queue callbacks,
discards pending boarding/success/intel calls and plays one abort report after
the active clip finishes. All final clip lengths are measured in `voice.lua`.

Verification: 126 source/shipping adapter checks (including the 18 new voice
integration/queue checks), 22 packaging tests, 11 extraction-objective checks,
four audio tests covering all 27 registrations/codecs/durations/full decodes and
retained hashes, actual archive guards, Lua 5.1 syntax and StyLua pass. Live
radio playback/volume/remote multicrew/pacing are not yet accepted; the previous
convoy/checkpoint/CAP AI live gates also remain open.

Client `Saved Games\DCS\Missions\Operation Hidden Passage.miz` and generated
`out/operation-hidden-passage.miz` SHA-256:
`3715ca8f71d3adb5f77343b12eb054f589855a8f4e7a9952639819680bf1ef8c`.
Changed existing members: embedded main script and the three approved replaced
recordings; added members: 14 new recordings. The editor mission, briefing,
other audio and all unrelated archive members are preserved byte-for-byte.
Verified backup:
`C:\Users\g_for\Saved Games\DCS\Backups\Operation-Hidden-Passage\Operation Hidden Passage-before-voice-20261027T091433877145Z.miz`
(input SHA-256 `0239c74934a3965786660d8fb0b8db55845a7f8ec2b60405d516262371eb367e`).
Current evidence: `out/operation-hidden-passage-evidence.json`. Dedicated-server
and retained Testing archives were not updated. Reload the client operational
archive for the new voices; do not overwrite it with an older in-memory editor copy.

**Staged CAP/SEAD branch deployed — 2026-10-26:**
`transport-firefight-cap-1` retains the CAS convoy and RPG checkpoint and adds
an independent CAP branch. One shared occupied-Blue-slot snapshot at the first
human Blue takeoff freezes both role decisions. Either `CAP-Hornet` (F/A-18C)
or `CAP-Viper` (F-16C) enables the late-activated Kub group `Ground-9`; neither
occupied leaves all three CAP threat groups inactive for the run. Joining late,
re-slotting or subsequent takeoffs cannot change the decision or duplicate units.
CAS still independently enables `CAS-Convoy` and `CAS-Convoy-1` when either CAS
seat is occupied. CAP does not change helicopter boarding/extraction rules.

The spawned SAM's `Kub 1S91 str` wrapper is tracked, not its original dormant
editor unit/name or an unrelated SAM. A MOOSE timer checks every two seconds;
radar silence, damage while life remains >= 1, or loss of launchers/support
vehicles does not advance the branch. Radar death/removal or DCS life < 1
(including a cooking-off wreck) releases `Aerial-1` (two armed Fulcrums) and
`Rotary-1` (one Mi-24V) once, from their authored hot airfield starts. Every
tracked radar must be destroyed if the SAM template contains more than one.
The two air groups spawn independently; a failed aircraft template does not
block the other or retry indefinitely. Missing/failed SAM or unidentifiable
radar holds the air response. Radar-query errors fail closed and retry, with
one error log per episode. Text calls announce SEAD and subsequent air threats.

The owner's routes, aircraft types, skills (including the Hind's High skill),
weapons, parking and tasks remain unchanged. No airborne fallback, automatic
respawn, artificial extraction gate, voice recordings or briefing edits were
added. The archive guard checks CAP client slots, late activation, tracking
radar, two missile-armed fighters, one armed Hind, and controlled hot starts.
The 108 source/shipping adapter checks include the pinned MOOSE spawn path
through the database boundary using the real archive aircraft templates, plus
radar-wrapper lifecycle semantics. The 22 packaging tests (including malformed
CAP layouts), 11 extraction-objective tests, layout guards and StyLua pass.
These are offline checks, not live acceptance: airfield taxi/takeoff, AI route
deviations, actual fighter contact timing, and the Hind's ability to detect and
attack the Chinook still need a DCS run. Earlier route-time estimates predate
the latest editor changes and must not be treated as guaranteed encounter times.

Client `Saved Games\DCS\Missions\Operation Hidden Passage.miz` and generated
`out/operation-hidden-passage.miz` SHA-256:
`0239c74934a3965786660d8fb0b8db55845a7f8ec2b60405d516262371eb367e`.
Only `l10n/DEFAULT/OHP-main.lua` changed; all other archive members, including
the latest editor mission, split briefing, audio and loadouts, were preserved
byte-for-byte. Verified backup:
`C:\Users\g_for\Saved Games\DCS\Backups\Operation-Hidden-Passage\Operation Hidden Passage-before-voice-20261026T191507552892Z.miz`
(original SHA-256 `e61920352dbfd2bb729cd7300954bf0293999cc60dccf79a0c31b016b920953c`).
Current deployment evidence: `out/operation-hidden-passage-evidence.json`.
Dedicated-server and Testing archives remain untouched. Reload the operational
client mission; saving an older in-memory editor copy can overwrite this payload.

**CAS-only RPG checkpoint deployed — 2026-10-23:** `transport-firefight-cas-3`
adds the editor's late-activated `CAS-Convoy-1` infantry checkpoint to the same
first-human-Blue-takeoff CAS decision as the convoy. Either occupied CAS slot
enables both threats once; no CAS at that snapshot leaves both inactive,
including after a later CAS join. Missing/failed templates do not prevent the
other threat from spawning. CAS receives a text warning to clear the north-road
RPG checkpoint before helicopter approach. It retains its editor position,
eight-unit strength (four RPG soldiers), patrol, ROE and killability. There is
no artificial helicopter/boarding gate, new strike-building objective, or
checkpoint-clearance announcement. Actual RPG engagement needs live validation.

Updated `Saved Games\DCS\Missions\Operation Hidden Passage.miz` and
`out/operation-hidden-passage.miz` SHA-256:
`958cfc43f7cca9b6ab996115d73d0ba5ec3f2c1fa5c9a41f745b118a8df06127`.
Only the embedded main payload changed; the latest editor mission (including
convoy relocation and checkpoint), split briefing, audio and other resources
were preserved. The updater now recognizes and preserves the exact approved
story/task split rather than requiring a one-off deployment. Unknown briefing
edits still fail closed. Backup:
`C:\Users\g_for\Saved Games\DCS\Backups\Operation-Hidden-Passage\Operation Hidden Passage-before-voice-20261023T124918954636Z.miz`
(input SHA-256 `cc43cf13240dd2cdfc305239e7df202041112f3cb3c734709c32e45372491c32`).
The 20 packaging tests, 11 objective tests, 89 source/shipping adapter checks,
real-layout guards and formatting checks pass. Dedicated-server and Testing
archives remain untouched; reload the operational client mission to test.

**CAS-2 client deployment — 2026-10-23:** At the owner's request, the verified
CAS-2 payload is installed in
`C:\Users\g_for\Saved Games\DCS\Missions\Operation Hidden Passage.miz`.
Only `l10n/DEFAULT/OHP-main.lua` changed: the client's newer editor mission,
split story/task briefing, audio and all other members were preserved. The
actual client layout guard, 84 shipping adapter checks, ZIP CRC, backup and
post-deployment byte checks passed. Deployed SHA-256:
`3c76f7247f086f9949ba63a6a890aa6bc2c184baa4a18ccc84f24a5b644e39e4`.
Verified backup:
`C:\Users\g_for\Saved Games\DCS\Backups\Operation-Hidden-Passage\Operation Hidden Passage-before-cas2-20261023T123107476247Z.miz`
(original SHA-256 `44f74760dc148272ea045e5445f5099056ec6da60e6f65fa65119dd839e7276e`).
Evidence: `out/operation-hidden-passage-client-deployment.json`. The dedicated
server and Testing archive were not updated. Reload the client mission for the
new payload; continued movement after a lead-vehicle strike is not yet accepted.

**CAS convoy movement follow-up — 2026-10-23:** The owner observed the convoy
halting after the lead BTR was destroyed. Candidate `transport-firefight-cas-2`
sets `OptionDisperseOnAttack(0)` on the spawned convoy to disable DCS's automatic
dispersal response. It does not change routes, vehicle spacing, speed, ROE,
killability, or the first-human-Blue-takeoff snapshot. This is not a guaranteed
workaround for physical wreck blockage or DCS pathfinding; another lead-vehicle
strike must verify that the survivors continue moving in-game.

The candidate was rebuilt from a preserved copy of the previously tested output
(input SHA-256 `06ee13cfb4d37cb8800d56308f3958ad0a43c2e96cd09399819d4cb59c706db2`),
not the separately edited client archive. The current candidate is
`out/operation-hidden-passage.miz`, SHA-256
`0f0cd74419b3228a91eb53dcdd0b8fa74b7a4a84ab6284e7f9d7eef5f9d0bb8c`.
Only `l10n/DEFAULT/OHP-main.lua` changed; the mission table and all other members
are byte-identical. Neither installed mission was replaced. All 18 packaging
tests, 11 objective tests, 84 adapter checks (including the pinned MOOSE
dispersal implementation), and formatting checks pass. A timestamp-dependent
no-op ZIP rebuild failure surfaced during verification; the updater now retains
original bytes when no members change, with a deterministic timestamp regression.

**Conditional CAS convoy candidate — 2026-10-23:** The operational client archive
now contains `CAS-Hornet`, `CAS-Warthog`, and a late-activated Red `CAS-Convoy`.
The optional branch snapshots occupied Blue player slots at the **first human
Blue takeoff**: either CAS slot enables one convoy; neither means no convoy for
that run, even if a CAS pilot joins later. Both CAS slots still spawn only one
convoy. The script broadcasts a warning when it activates. The updater validates
the configured aircraft/convoy templates and preserves the editor-authored
mission table. This is candidate-only: the client archive was used as input but
not replaced, the dedicated-server copy was not updated, and live DCS behavior
remains unverified. Candidate:
`out/operation-hidden-passage.miz` (SHA-256
`dedb716a9b84a06b8c3371fa2bb45ac2c9acba22101bdf307963b001fa1b4ba0`), built from
the unchanged client input SHA-256
`69c08ad02d66605f8e9143938e763eede17c5b63b507da527a8788eef94f3b9f`.

The saved convoy route's mission-editor ETA is **2,020 seconds (33m40s) to
waypoint 4 after activation**, at its authored 5.56 m/s speed. That waypoint is
about **232 m from the HVT zone center** and **305 m from the landing zone**;
actual in-game timing and vehicle movement require flight testing. The convoy is
substantial: two BTR-82As, two armed technicals, a Tigr, and a KrAZ truck. The
Hornet and A-10C II client slots both have CAS tasks and guided ground-attack
stores. Keep the convoy and attack route danger-clearance in mind during live
testing; the CAS warning asks pilots to engage along the road, clear of the party.

Status (2026-10-21): **The operational briefing now gives the extraction a
reason:** three compromised local sources know enemy positions and movements;
they must reach Hatay before hostile troops capture them. The mission text is much
shorter and keeps only the story and essential task instructions. The existing
F10 **Request green smoke** voice exchange and pickup-triggered reinforcement
remain in place. This deployment changed only the DCS dictionary/briefing; the
editor mission table is byte-for-byte preserved. The verified backup and deployed
hash are recorded below. Packaging, objective, adapter, formatting and archive
checks pass; this briefing update is **not yet live-tested**. The Testing archive
was not changed.

The smoke-response timing now waits **5 seconds after the pilot recording and
its 0.35-second audio safety tail**. Lua adapter tests verify that neither
aircraft receives the reply early, including the under-fire response. A new
operational copy was deployed to the dedicated-server mission folder:
`C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Missions\Operation Hidden Passage.miz`
(SHA-256 `ca957f5b7589095b338981f87e87f1ebb8b1de9397d894e59429eab12642a4e4`).
It was built from the client operational archive at SHA-256
`c3ac56e8fed7d96a935c1b4e358e3fa229f37263edd7d20594ee57abbd77ea57`; only
`l10n/DEFAULT/OHP-main.lua` changed, and the editor mission member is byte-for-byte
preserved. The verified source backup is
`C:\Users\g_for\Saved Games\DCS\Backups\Operation-Hidden-Passage\Operation Hidden Passage-before-voice-20261021T202254629779Z.miz`
(same source SHA-256). The dedicated server was not running during deployment, so
the new mission file has not yet been loaded or live-tested. The client archive
was not replaced by this deployment.

On approach, F10 > **Request green smoke** plays the requesting helicopter's call,
emits green smoke at the landing area, then plays the HVT woman's reply. The calm
reply is used until the primary firefight starts; the under-fire recording is used
once the enemy reaches engagement range. Routine voice transcripts and the long
smoke instruction have been removed from the screen; concise boarding, threat,
delivery, and success cues remain. Full-route, firefight, remote multicrew and
dedicated-server behavior remain live gates.

The original operational firefight remains: a recognized outbound helicopter
triggers the Blue-wide warning and starts the primary group's approach at **3 NM
from pickup**. The short Testing route retains its halfway trigger (about 1.53 NM
from pickup) and its original single unsuffixed enemy template.

## Retained mission files

Both files live in `C:\Users\g_for\Saved Games\DCS\Missions`:

| Mission | Pickup | Purpose |
|---|---|---|
| `Operation Hidden Passage.miz` | 33.06 NM south of Hatay | Operational mission; preserves the editor-authored layout |
| `Operation Hidden Passage - Testing.miz` | 3.06 NM northeast of Hatay | Retained testing mission; renamed from Short Voice Test |

The short archive's mission-list title is also **Operation Hidden Passage -
Testing**. The deployed operational archive now contains 13 Ogg recordings; the
unchanged Testing archive retains its previous nine. The operational archive has
two late-activated enemy templates; Testing retains its single template. The old
Short Voice Test filename was retired only after verified backup/deployment.

## Accepted transport behaviour

- Either **Mule One / CH-47F** or **Raven One / UH-60L** can collect the one
  three-person party. Both have independent smoke/status/transport menus.
- On approach, choose **Request green smoke**. The pilot request and HVT response
  play to that aircraft while green smoke appears at the landing area. The calm
  response is used until `runtime.firefight.state` becomes active (enemy reaches
  the 300 m engagement range); after that, the under-fire response is used.
- Land within **105 m** of the party, stay **35 m clear of every person**, and
  stop for **two seconds**. Boarding starts automatically. Ramp/door checks are
  deliberately disabled; the extraction menu remains a fallback.
- Merely entering a slot claims nothing. The first aircraft to begin boarding
  becomes the carrier. The other cannot steal/duplicate the party; it retains
  smoke/status access. If both qualify on the same observer tick, Mule is evaluated
  first. A claimed carrier cannot be replaced; there is no automatic handover.
- Remain landed until troop disappearance and aboard confirmation occur together.
  Crew-chief lines use the actual carrier's aircraft type and go to its crew.
- Return to **OHP-Hatay-Return**, land and stop, then select **Unload personnel**.
  **Unloading remains manual by owner decision.** Confirmed delivery completes the
  objective and plays Hidden Passage Success to Blue automatically.
- Mule and Raven have independent once-only departure calls. Either can trigger
  the once-only Blue-wide HVT-under-fire warning. On the operational route it
  triggers at 3 NM remaining; on the short Testing route it retains halfway
  timing, about 1.53 NM remaining.
- There is no forced session exit, in-mission reset or adaptive enemy/SAM logic.
  Restart after failure/completion. Off-site unloads can be recovered by the same
  carrier; losing/replacing that carrier or the party requires a restart.

## Staged firefight

The operational archive contains two late-activated Red **Infantry AK** groups,
eight units each. The primary template is `OHP-TestOpposition-1` (older archives
may use the unsuffixed `OHP-TestOpposition`); it spawns at setup, holds fire, and
starts moving at the **3 NM from pickup** outbound trigger. It approaches a point
about **255 m** from the HVTs at **5 m/s**; the exchange starts inside **300 m**.
The editor-authored concealed template `OHP-TestOpposition-2` stays inactive until
the CTLD pickup changes to boarding. At that point it spawns and routes toward the
HVTs at **5 m/s**. It remains killable and uses its editor-authored engagement
settings while advancing. Once all three HVTs are confirmed aboard, it is ordered
to hold and hold fire. If the second template is absent (as in the retained
Testing archive), this additional behavior is skipped.

HVTs are held at setup, return fire for **5 seconds** after the primary exchange
starts, then hold fire while remaining protected until that exchange ends. Only
the HVT party is temporarily immortal during the primary exchange; enemy infantry
and player aircraft remain vulnerable.

The primary exchange stops when the party is confirmed aboard, all primary enemies
are eliminated, or the **10-minute maximum** is reached. The pickup reinforcement
stops advancing when the party is confirmed aboard. The layout-specific triggers,
300 m gate, ROE/fire windows, one-shot pickup spawn, killability, timeout, and
boarding stop are covered by adapter/package tests; actual DCS route speed,
line-of-sight, infantry firing, helicopter-gunner targeting, ammunition use, and
CTLD boarding with the protected party still require live testing. Expect live
ammunition and danger-close gunfire; the player aircraft are not protected.

## Conditional CAS convoy

- The operational editor layout has the Blue player slots `CAS-Hornet`
  (`FA-18C_hornet`) and `CAS-Warthog` (`A-10C_2`), both assigned the CAS task,
  plus a Red late-activated vehicle group named `CAS-Convoy`.
- On the first human Blue `TAKEOFF` event, the mission snapshots currently
  occupied Blue player aircraft. If either configured CAS group is occupied,
  it spawns the convoy once and warns Blue. If neither is occupied, the branch
  is disabled for that run. Switching slots before the first takeoff is
  reflected in the snapshot; later slot changes do not toggle it. Occupying
  both CAS slots still produces only one convoy.
- In a layout without the editor convoy template (including the retained
  Testing layout), the branch fails closed and does not spawn anything.
- The current editor-authored route reaches its closest point to the HVTs at
  about 33m40s after activation according to the saved waypoint ETA. This is
  not live-tested and may differ in DCS.

Previously verified operational deployment SHA-256:
`d4b92f92df38ab3c76b2f47932df6a7f5ee3219ac9b800a1329675adc9460b34`.
The verified pre-deployment backup is
`C:\Users\g_for\Saved Games\DCS\Backups\Operation-Hidden-Passage\Operation Hidden Passage-before-voice-20261021T200504361143Z.miz`
(original SHA-256 `2c5019a36712549741b6f809e7a11cba2de27e717a90a490c56d0506dc266832`).
The deployed Testing archive remains unchanged at SHA-256
`86ebe8673b54ff1715c8716a808b3ff0c97fce8af3875c8e5895ddc0acda609b`.

The earlier short-range transport acceptance recorded Raven departure, halfway,
boarding, Hatay delivery and success audio in the client log. That run does not
validate this revised firefight, the entire 33 NM route, or remote multiplayer.

## Update workflow

For future improvements, update/test **Testing first**. The firefight is already
enabled in both retained archives. A Testing-only candidate can be rebuilt with:

```powershell
python build/update-hidden-passage.py --input 'C:\Users\g_for\Saved Games\DCS\Missions\Operation Hidden Passage - Testing.miz' --layout testing --enable-firefight
```

To deploy the operational port after further changes, use the explicit operational
layout and `--deploy`:

```powershell
python build/update-hidden-passage.py --input 'C:\Users\g_for\Saved Games\DCS\Missions\Operation Hidden Passage.miz' --layout operational --deploy
```

The current operational archive already contains both editor-authored groups, so
ordinary updates should omit `--enable-firefight`; that option is only for a
reviewed archive that still needs the primary template added.

Omit `--deploy` for candidate-only builds. Explicit layout guards reject the wrong
archive. The updater preserves editor-authored mission data, aircraft, weather, zones, triggers,
warehouses and resources; the explicit firefight option adds only its constrained
enemy template. It replaces the embedded payload, adds missing audio, and replaces
the operational description only when the recognized old text is intact. Unknown
briefing changes are rejected rather than overwritten. Existing audio differences
require explicit `--replace-audio NAME.ogg`; the tested MOOSE pin is verified, not
silently replaced. Deployment backs up and detects concurrent editor saves.

For the initial rename, the updater supports `--deploy-to '<new filename.miz>'
--retire-source`: it refuses existing destinations, backs up the old file, verifies
the new file, then retires the old name. Ordinary future updates use `--deploy`.

Generated outputs:

- `out/operation-hidden-passage.miz` and `out/operation-hidden-passage-evidence.json`
- `out/operation-hidden-passage-testing.miz` and `out/operation-hidden-passage-testing-evidence.json`

Source, sounds, tests and plans are versioned. Generated archives and local backups
follow existing gitignore conventions. Preserve the editor-authored `.miz` files
as build inputs. The older seed packager/short-voice wrapper are compatibility
tools, not the preferred update workflow. Historical development findings are in
`docs/hidden-passage-transport-test.md`.

## Verification

```powershell
python tests/test_hidden_passage_packaging.py
lua5.1 tests/lua/run-hidden-passage-operation.lua
lua5.1 tests/lua/run-hidden-passage-adapter.lua
```

Eighteen archive/deployment safety tests, 11 objective tests and 77 adapter checks
pass. The updater repeats adapter checks using **each archive's actual zones**.
These checks do not replace DCS firefight, terrain, mod-package and multiplayer QA.

Shared multiplayer speech commands remain deferred in
`docs/plan-shared-voice-commands.md`; no recognition service is installed by these
mission updates.
