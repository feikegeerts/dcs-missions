# Operation Hidden Passage

Status (2026-10-20): **The staged firefight is deployed to the operational
mission.** Its 33.06 NM route now triggers the Blue-wide HVT-under-fire call and
starts the enemy approach when a recognized outbound helicopter reaches **3 NM
from pickup**. The exchange starts once the six killable riflemen move within
300 m. The short Testing route keeps its existing halfway trigger (about 1.53 NM
from pickup); a candidate-only rebuild confirmed that behavior and left the
deployed Testing archive unchanged. Both layouts hold HVT fire until the exchange,
allow a five-second return-fire burst, and protect only the HVT party during the
exchange. The operational archive was backed up before deployment; its deployed
SHA-256 is recorded below. This port is build-verified, **not yet live-flown**.
The earlier short-range transport acceptance remains valid; operational firefight,
full long-range flight, remote multicrew and dedicated-server behavior remain live
gates.

## Retained mission files

Both files live in `C:\Users\g_for\Saved Games\DCS\Missions`:

| Mission | Pickup | Purpose |
|---|---|---|
| `Operation Hidden Passage.miz` | 33.06 NM south of Hatay | Operational mission; preserves the editor-authored layout |
| `Operation Hidden Passage - Testing.miz` | 3.06 NM northeast of Hatay | Retained testing mission; renamed from Short Voice Test |

The short archive's mission-list title is also **Operation Hidden Passage -
Testing**. Both archives now use `transport-firefight-1`, the same nine Ogg
recordings, and a late-activated enemy template. The old Short Voice Test filename
was retired only after verified backup/deployment.

## Accepted transport behaviour

- Either **Mule One / CH-47F** or **Raven One / UH-60L** can collect the one
  three-person party. Both have independent smoke/status/transport menus.
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

Both archives contain a late-activated six-person Red **Infantry AK** template,
placed relative to that archive's actual HVT zone. Enemies spawn at setup about
**396 m** from the HVTs and hold fire. HVTs are also explicitly placed on weapons
hold at setup. The operational route starts their approach and plays the warning
at **3 NM from pickup**; the retained short Testing route keeps the accepted
halfway trigger (about **1.53 NM** from pickup). From either trigger, enemies move
toward a point about **255 m** from the HVTs at **5 m/s**. The scripted exchange
starts when they reach **300 m**; both groups are then assigned fire tasks. Only
the HVT party is temporarily immortal; enemy infantry remain killable, and player
aircraft remain vulnerable. HVTs return fire for **5 seconds**, then hold fire
while remaining protected until the exchange ends.

The exchange stops when the party is confirmed aboard, all enemies are eliminated,
or the **10-minute maximum** is reached. Riflemen can also stop firing sooner if
they expend their ammunition. The exchange does not continue during the return
flight. The staging/migration guards, layout-specific trigger, 300 m gate, ROE/fire
windows, killability, timeout, and boarding stop are covered by adapter/package
tests; actual DCS route speed, line-of-sight, infantry firing, helicopter-gunner
targeting, ammunition use, and CTLD boarding with the protected party still
require live testing. Expect live ammunition and danger-close gunfire; the player
aircraft are not protected.

Operational deployment SHA-256: `57e60cdb26aa48e5a5f568f35655be95237cea4beee15269c0274cd6f639fd05`.
The verified pre-deployment backup is
`C:\Users\g_for\Saved Games\DCS\Backups\Operation-Hidden-Passage\Operation Hidden Passage-before-voice-20261020T210540132207Z.miz`
(original SHA-256 `770524081e0a4ac432ec54228bcd0d10c2c662d088a858de7b92e1b844ddabdf`).
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
python build/update-hidden-passage.py --input 'C:\Users\g_for\Saved Games\DCS\Missions\Operation Hidden Passage.miz' --layout operational --enable-firefight --deploy
```

Omit `--deploy` for candidate-only builds. Explicit layout guards reject the wrong
archive. The updater preserves editor-authored mission data, aircraft, weather, zones, triggers,
warehouses and resources; the explicit firefight option adds only its constrained
enemy template. It replaces the embedded payload, adds missing audio and surgically
updates known briefing sentences. Existing audio
differences require explicit `--replace-audio NAME.ogg`; unknown briefing changes
are rejected rather than overwritten. The tested MOOSE pin is verified, not
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

Thirteen archive/deployment safety tests, 11 objective tests and 72 adapter checks
pass. The updater repeats adapter checks using **each archive's actual zones**.
These checks do not replace DCS firefight, terrain, mod-package and multiplayer QA.

Shared multiplayer speech commands remain deferred in
`docs/plan-shared-voice-commands.md`; no recognition service is installed by these
mission updates.
