# Operation Hidden Passage

Status (2026-10-20): **Short-range testing accepted by the owner; operational
port approved.** The full long-range flight, remote multicrew and dedicated-server
operation remain separate live gates. Adaptive combat is still a draft.

## Retained mission files

Both files live in `C:\Users\g_for\Saved Games\DCS\Missions`:

| Mission | Pickup | Purpose |
|---|---|---|
| `Operation Hidden Passage.miz` | 33.06 NM south of Hatay | Operational mission; preserves the editor-authored layout |
| `Operation Hidden Passage - Testing.miz` | 3.06 NM northeast of Hatay | Retained testing mission; renamed from Short Voice Test |

The short archive's mission-list title is also **Operation Hidden Passage -
Testing**. Both use the same self-contained `transport-1` Lua payload and nine Ogg
recordings; their editor layouts, travel briefings and archive/list names differ.
The old Short Voice Test filename is retired only after verified backup/deployment.

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
  the once-only Blue-wide halfway warning. Halfway uses each archive's actual
  zones: about 16.53 NM remaining operationally, 1.53 NM in Testing.
- There is no forced session exit, in-mission reset or adaptive enemy/SAM logic.
  Restart after failure/completion. Off-site unloads can be recovered by the same
  carrier; losing/replacing that carrier or the party requires a restart.

The owner declared short testing complete. The client log independently recorded
Raven departure, halfway, boarding, Hatay delivery and success audio. This is not
evidence that the entire 33 NM route or remote multiplayer has been flight-tested.

## Update workflow

For future improvements, update/test **Testing first**, then port after approval:

```powershell
python build/update-hidden-passage.py --input 'C:\Users\g_for\Saved Games\DCS\Missions\Operation Hidden Passage - Testing.miz' --layout testing --deploy
python build/update-hidden-passage.py --input 'C:\Users\g_for\Saved Games\DCS\Missions\Operation Hidden Passage.miz' --layout operational --deploy
```

Omit `--deploy` for candidate-only builds. Explicit layout guards reject the wrong
archive. The updater preserves mission tables, aircraft, weather, zones, triggers,
warehouses and resources byte-for-byte. It replaces the embedded payload, adds
missing audio and surgically updates known briefing sentences. Existing audio
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

Eight archive/deployment safety tests, 11 objective tests and 68 adapter checks
pass. The updater repeats adapter checks using **each archive's actual zones**.
These checks do not replace DCS flight/terrain, mod-package and multiplayer QA.

Shared multiplayer speech commands remain deferred in
`docs/plan-shared-voice-commands.md`; no recognition service is installed by these
mission updates.
