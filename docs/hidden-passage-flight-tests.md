# Operation Hidden Passage — live flight tests

Keep dated live observations here; do not replace measured results with route
estimates. Current behaviour/deployment: [mission notes](hidden-passage.md).

## 2026-10-27 — solo CAP Hornet Kub kill and slow scramble

**Tested build:** `transport-failure-report-delay-1`. Recording:
`Tacview-20261027-160946-DCS.zip.acmi`, DCS 2.9.30.28738. The HARM destroyed
the spawned objective Kub radar (`1000014`), not just its support vehicles.

| Event | Mission model time (s) | Since radar death |
| --- | ---: | ---: |
| HARM hit; Kub radar dead/kill | 570.403 | 00:00.000 |
| Both MiGs and Hind engine-startup events; first replay samples | 571.200 | 00:00.797 |
| Hind takeoff, Taftanaz | 874.500 | 05:04.097 |
| Lead MiG takeoff, Abu al-Duhur | 986.010 | **06:55.607** |
| Wingman MiG takeoff, Abu al-Duhur | 1008.600 | **07:18.197** |
| Mission end | 1011.482 | 07:21.079 |

These are debrief model-time differences, not wall-clock subtraction. The lead
and wingman first moved more than 10 m from their first replay positions at
582.470 s and 595.570 s. This corroborates taxiing well before takeoff; those
sample thresholds are not takeoff events or exact taxi-start times. The authored
MiGs use `TakeOffParkingHot`, start time zero and no uncontrolled start. The
evidence points to DCS ground-departure/taxi time, not a scripted seven-minute
launch wait. Subsequent airborne route timing is separate and was not shortened.

**Immediate Kub confirmation confirmed:** the adapter detected the radar loss
at 15:21:43.655 UTC and dispatched the recording at 15:21:43.656, effectively
instantly. The prior 20-second pause covered only mission failure.

**False spawn failures:** the same transition logged `Aerial-1 spawned without
live units` and `Rotary-1 spawned without live units`. Both groups actually
spawned and took off. A synchronous live check ran before DCS aircraft creation
completed, skipping their warning and destruction-tracking registration. This
is not evidence of failed activation; the follow-up retains the wrappers and
observes readiness without repeating the spawn.

### Follow-up

The owner explicitly chose **runway-ready MiGs** instead of hot-parking starts,
keeping their airfield, payloads and airborne route. The Hind's start is
unchanged. Current build `transport-overlord-latency-scramble-2` also waits at
least 20 seconds for Overlord outcome reports/text, except the owner-approved
five-second checkpoint tasking. Objective state and actual spawns do not wait.
Full test/deployment details are in [mission notes](hidden-passage.md).
**New runway takeoff timing is not yet measured**; the table describes only
the old hot-parking flight.

### Preserved evidence

`out/hidden-passage-cap-live-20261027-160946/` contains original `dcs.log`,
`debrief.log`, Tacview archive and `analysis.json` with event IDs/model times,
movement samples, relevant log lines and source hashes. Recipe:
`out/analyze-hidden-passage-cap-20261027.py`. Raw evidence was preserved before
another flight could overwrite it.

## 2026-10-27 — solo CAS Hornet first bombing attempt

**Tested build:** `transport-cas-sequence-test-1`. Recording:
`Tacview-20261027-135845-DCS.zip.acmi`. The current DCS log also contains an
earlier run of `transport-voice-volume-90-1`; the timings here use only the later
run that loaded the sequential CAS build.

**First bomb's estimated ground impact: 7m 07.630s after takeoff.** This is an
attack-timing reference, **not a successful convoy strike or clearance time**.
The pilot reported missing the convoy; no hit/kill event or convoy-destroyed
report was recorded.

| Event | Mission model time (s) | Since takeoff |
| --- | ---: | ---: |
| CAS Hornet takeoff; convoy spawned/tasking dispatched | 215.980 | 00:00.000 |
| New CAS departure recording dispatched | approximately 225.93 | approximately 00:09.95 |
| First GBU-12 release | 615.643 | 06:39.663 |
| First GBU-12 estimated impact | 643.610 | **07:07.630** |
| Second GBU-12 release | 772.000 | 09:16.020 |
| Second GBU-12 estimated impact | 800.080 | 09:44.100 |
| Mission end | 1013.826 | 13:17.846 |

Release and takeoff times come from `debrief.log`. Estimated impact times come
from the final descending bomb samples and removal in Tacview, not direct
vehicle-hit events; do not treat the displayed millisecond precision as exact
physical-impact precision. First/second estimated bomb flight times were
27.967 s and 28.080 s. The nearest convoy vehicle was approximately **888 m**
from the first bomb's final position and **603 m** from the second's, using
nearest-in-time replay samples. No successful strike is implied.

Relative to the earlier Mule flight's 15m 39.640s touchdown, first CAS impact
was **8m 32.010s earlier on a common takeoff-relative timeline**. If both flights
depart together, this suggests room for CAS to begin attacking before helicopter
arrival. It does **not** establish how long killing the convoy takes, and it
does not account for staggered takeoffs or different flight profiles.

The latest run correctly released only the convoy at takeoff and dispatched the
new convoy clip (9.6 s queue length), followed by the then-enabled CAS departure
clip (3.4 s). The latter was subsequently removed at the owner's request; this
historical timeline records what actually played in this run. No temporary
pickup override, checkpoint spawn, or full checkpoint-stage test was logged.

### Hornet FLIR follow-up

The pilot reported WPDSG slewing near the CHECKPOINT location but a drifting
ground image. The archive's CAS Hornet carries **LITENING** (`{AAQ-28_LEFT}`);
CHECKPOINT is route waypoint 2, at Vec2 `(88246.128947491, 40864.49186291)` with
**2,000 m BARO altitude**, versus roughly 190–196 m terrain around the checkpoint.
Incorrect target elevation is a likely explanation for designation parallax,
but the cockpit DATA/WYPT elevation and FLIR tracking mode were not captured
here, so the exact cause is not proven. WPDSG designates a location; it does not
automatically command optical vehicle tracking. Also, checkpoint infantry were
not activated in this run; the permanent static checkpoint structures remain.

The owner will correct waypoint heights. **No waypoint coordinates, heights or
routes were changed by the assistant.** Check the in-cockpit waypoint elevation
as well as pod AREA/POINT tracking on the next run.

### Preserved evidence

`out/hidden-passage-cas-live-20261027-135845/` contains raw `dcs.log`,
`debrief.log`, the Tacview archive and `analysis.json` with model-time events,
bomb endpoints, nearest convoy samples, session checks and source hashes.
Analysis recipe: `out/analyze-hidden-passage-cas-20261027.py`.
No mission gameplay or route timing was changed based on these measurements.

## 2026-10-27 — solo Mule One approach and failed pickup

**Tested build:** `transport-firefight-voice-1`, operational 33.06 NM layout.
Human role: Mule One / CH-47F; CAS and CAP were correctly disabled at the first
Blue takeoff. This was a client-hosted flight, not a dedicated-server test.

**Measured flight time: 15m 39.640s from takeoff to first LZ touchdown.**
DCS event model times were 109.272 s and 1048.912 s. The pilot's initial estimate
of about ten minutes was shorter than the recorded flight. No return leg or
successful delivery was completed in this run.

### Timeline

Times below are DCS log UTC; the local Tacview filename uses 12:14:52. Elapsed
times are relative to takeoff, rounded to tenths from log timestamps. Use the
model-time subtraction above for the precise airborne duration.

| Event | UTC | Since takeoff |
| --- | --- | --- |
| Mission adapter ready | 11:14:52.693 | — |
| Mule takeoff, departure recording | 11:16:39.938 | 00:00.0 |
| Crossed 3 NM; primary enemy advance commanded | 11:29:58.659 | 13:18.7 |
| Early HVT approach-warning recording dispatched | 11:29:58.674 | 13:18.7 |
| Mule green-smoke request | 11:30:30.964 | 13:51.0 |
| Calm HVT green-smoke reply | 11:30:41.522 | 14:01.6 |
| First LZ touchdown | 11:32:19.572 | 15:39.6 |
| Boarding recording; pickup reinforcement released | 11:33:05.668 | 16:25.7 |
| First recorded rifle hit on the subsequently killed HVT | 11:33:31.387 | 16:51.4 |
| Adapter declared personnel loss during boarding; abort recording | 11:33:42.657 | 17:02.7 |
| DCS confirmed the HVT kill | 11:33:43.132 | 17:03.2 |

- The 3 NM warning preceded touchdown by **2m 20.9s**.
- Boarding began **46.1s after touchdown**, after repositioning.
- The loss was detected **37.0s into boarding**; DCS confirmed the kill about
  half a second later. The killer was an `Infantry AK` in the newly spawned
  `OHP-TestOpposition-2#001` pickup reinforcement, using rifle fire.

### Findings

**No scripted inbound firefight:** The 3 NM trigger and approach-warning audio
dispatch worked. The primary enemies did move, but no soldier crossed the old
300 m firing gate. Tacview's closest sampled approach was **302.7 m**; the
original leader's closest approach was **353.1 m**. The adapter observed the
group position rather than the nearest surviving soldier and never opened
their fire. No `FIREFIGHT started` or `hvt-taking-fire.ogg` playback was logged.
The calm smoke reply therefore matched the actual scripted state. Dispatch in
the log is not proof that the pilot heard a clip.

**Landing tolerance too tight:** The nearest Tacview sample to touchdown
(model time 1048.93 s) places Mule at DCS Vec2 `(86461.40, 41544.61)`: **107.6 m
from the lead HVT** and **38.9 m from green smoke**. Boarding required proximity
to the party, not entry into the editor's smoke-zone circle. This landing was
only **2.6 m outside the 105 m boarding range**. After moving closer, boarding
started normally.

**Boarding casualty:** Confirmed hostile fire, not an unexplained CTLD removal.
The pilot accepted this risk; the follow-up does not remove the reinforcement,
waive casualties, or change existing HVT protection rules.

### Follow-up deployed after this test

Build **`transport-approach-lz-1`**:

- Increase boarding range **105 → 125 m**, consistently in automatic pickup,
  native CTLD extraction and status text. Keep landed/stopped, two-second
  settling and 35 m clearance from every person.
- Increase inbound firefight gate **300 → 400 m** and evaluate the nearest
  surviving soldier. Dead/missing units cannot trigger it. Retain the 3 NM
  approach trigger, authored enemy placement/routes and existing protection.
- Log measured staging/contact distances and contact model time for diagnosis.
- Preserve all editor-owned archive members, briefing and all 27 voice assets.

The recorded old enemy path first entered 400 m at model time **925.90 s**
(13m 36.6s after takeoff), about two minutes before touchdown. This illustrates
why the new gate addresses this run; it is **not** live acceptance of the new
exchange or a guarantee of the next run's AI timing.

Verification: **130 source/shipping adapter checks**, 11 objective checks,
22 packaging tests, four audio tests covering all 27 assets, archive preservation
and syntax/format checks. New regressions cover the recorded touchdown, pickup
near 125 m and rejection outside it in both helicopters, the recorded enemy
offset, and surviving-soldier versus dead/missing-unit contact checks.
**Next live gate:** hear/see the inbound firefight and board from the wider
landing area on a fresh mission run.

Installed client mission:
`C:\Users\g_for\Saved Games\DCS\Missions\Operation Hidden Passage.miz`.
Only `l10n/DEFAULT/OHP-main.lua` changed; no archive members were added.
Installed/generated SHA-256:
`f43abdc0dccd14791d7a03a119d59a64a0d0f8d051469922f75251fe3b5b1a02`.
Verified pre-update backup:
`C:\Users\g_for\Saved Games\DCS\Backups\Operation-Hidden-Passage\Operation Hidden Passage-before-voice-20261027T114048316781Z.miz`
(SHA-256 `3e6a506eba70c8bc91819faa5a5e542ee0ae0f268d36821379000567c3187148`).
The current editor-saved archive was used as input; it differed from the previous
deployment hash, and all its non-main members were preserved. Dedicated-server
and Testing copies were not updated.

### Evidence

Raw evidence was copied before a later flight can overwrite the logs:

`out/hidden-passage-mule-live-20261027-121452/`

- `dcs.log` — adapter state, voice dispatch and DCS combat/flight events.
- `debrief.log` — debrief and casualty positions.
- `Tacview-20261027-121452-DCS-Host-Operation Hidden Passage.zip.acmi` — replay.
- `analysis.json` — extracted timings/ranges, casualty event and source hashes.

Deployment evidence: `out/operation-hidden-passage-evidence.json`. These generated
files are local; this Markdown retains the key measurements independently.
