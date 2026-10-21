# Operation Hidden Passage

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
