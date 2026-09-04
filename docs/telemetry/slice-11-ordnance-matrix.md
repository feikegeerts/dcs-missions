# Slice 11: ordnance and airframe matrix

## Purpose

Slice 11 establishes the runtime `dcs_type` strings emitted by DCS for a
representative airframe/air-to-air weapon matrix. The dev-only unattended rig
spawns one blue AI fighter and one red bandit 15 nm apart. The blue AI is added
to both telemetry rosters after spawn, using its actual runtime group name, and
is registered as an `asset.spawned` instance.

The four knobs are local variables inside the stripped test-combat block in
`src/missions/duel-dynamic/main.lua`:

| Knob | Default | Meaning |
|---|---|---|
| missile knob | `"AIM-120C"` | Red-cell AAM when the blue side is unarmed. |
| blue missile knob | `nil` | `nil` leaves blue weaponless; a weapon key arms exactly one blue AAM and leaves the bandit weaponless. |
| bandit airframe knob | `nil` | `nil` keeps the bandit as `FA-18C_hornet`. |
| blue airframe knob | `nil` | `nil` keeps the blue AI as `FA-18C_hornet`. |
| gun-test knob | `false` | `true` gives both aircraft `gun=100` and zero AAM pylons. |

The normal invariant is deterministic: the armed side carries exactly one AAM,
`gun=0`, and the other side carries no weapons. The gun cell is the exception:
both sides carry guns and no AAMs. A missing `(airframe, weapon)` pylon entry
aborts the run; it never silently falls back to another loadout.

## Researched catalogue

The pylon index is the DCS station number (`num` in `UnitPayloads`), not the
ordinal index of the Lua payload array. The expected runtime value is the
weapon table's `name` field. The two prior live-proven cells are marked below.
For readability, `...\` in a source cell expands to the full common prefix
`D:\DCS World Server\CoreMods\aircraft\`.

| Airframe | Weapon key | Pylon | CLSID | Expected runtime `dcs_type` | Livery used | Verification/source |
|---|---|---:|---|---|---|---|
| `FA-18C_hornet` | AIM-120C | 2 | `LAU-115_2*LAU-127_AIM-120C` | `AIM_120C` | `Australia 75 Sqn RAAF` | `D:\DCS World Server\CoreMods\aircraft\FA-18C\UnitPayloads\FA-18C_hornet.lua`; `...\AircraftWeaponPack\aim120_family.lua` (`name="AIM_120C"`); live-proven |
| `FA-18C_hornet` | AIM-9L | 1 | `{AIM-9L}` | `AIM-9L` | `Australia 75 Sqn RAAF` | CLSID/station: `...\FA-18C\FA-18C.lua`; weapon name: `...\AircraftWeaponPack\aim9_family.lua`; **UNVERIFIED (UnitPayloads has no explicit AIM-9L payload; live run is the arbiter)** |
| `FA-18C_hornet` | AIM-9M | 1 | `{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}` | `AIM_9` | `Australia 75 Sqn RAAF` | `...\FA-18C\FA-18C.lua`; `...\AircraftWeaponPack\aim9_family.lua` (`name="AIM_9"`); **UNVERIFIED (no explicit hornet AIM-9M station-1 entry in the current UnitPayloads)** |
| `FA-18C_hornet` | AIM-9P | 1 | `{9BFD8C90-F7AE-4e90-833B-BFD0CED0E536}` | `AIM-9P` | `Australia 75 Sqn RAAF` | `...\FA-18C\FA-18C.lua`; `...\AircraftWeaponPack\aim9_family.lua`; **UNVERIFIED (no explicit hornet AIM-9P payload)** |
| `FA-18C_hornet` | AIM-9X | 1 | `{5CE2FF2A-645A-4197-B48D-8720AC69394F}` plus `NFP_VIS_DrawArgNo_57=0.1`, `NFP_PRESID="MDRN_M_A_AIM9"` | `AIM_9X` | `Australia 75 Sqn RAAF` | `...\FA-18C\UnitPayloads\FA-18C_hornet.lua`; `...\AircraftWeaponPack\aim9_family.lua`; live-proven |
| `F-16C_50` | AIM-120B | 1 | `{C8E06185-7CD6-4C90-959F-044679E90751}` | `AIM_120` | `default` | `...\F-16C\UnitPayloads\F-16C_50.lua`; `...\AircraftWeaponPack\aim120_family.lua` (`name="AIM_120"`) |
| `F-16C_50` | AIM-120C | 1 | `{40EF17B7-F508-45de-8566-6FFECC0C1AB8}` | `AIM_120C` | `default` | `...\F-16C\UnitPayloads\F-16C_50.lua`; `...\AircraftWeaponPack\aim120_family.lua` |
| `F-16C_50` | AIM-9X | 2 | `{5CE2FF2A-645A-4197-B48D-8720AC69394F}` | `AIM_9X` | `default` | `...\F-16C\UnitPayloads\F-16C_50.lua`; `...\AircraftWeaponPack\aim9_family.lua` |
| `F-15ESE` | AIM-9M | 13 | `{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}` | `AIM_9` | no livery directory in install | `...\F-15E\UnitPayloads\F-15ESE.lua`; `...\AircraftWeaponPack\aim9_family.lua` |
| `F-15ESE` | AIM-9L | — | **UNVERIFIED — no CLSID entered** | `AIM-9L` | no livery directory in install | `...\F-15E\UnitPayloads\F-15ESE.lua` has no AIM-9L payload; `...\AircraftWeaponPack\aim9_family.lua`; live run is the arbiter |
| `F-15ESE` | AIM-120B | 15 | `{40EF17B7-F508-45de-8566-6FFECC0C1AB8}` | `AIM_120` | no livery directory in install | `...\F-15E\UnitPayloads\F-15ESE.lua`; `...\AircraftWeaponPack\aim120_family.lua` |
| `F-15ESE` | AIM-7M | 11 | `{AIM-7H}` | `AIM_7` | no livery directory in install | `...\F-15E\UnitPayloads\F-15ESE.lua`; `...\AircraftWeaponPack\aim7_family.lua` (`name="AIM_7"`) |
| `F-5E-3` | AIM-9B | 7 | `{AIM-9B}` | `GAR-8` | `USA standard` | `...\F-5E\UnitPayloads\F-5E.lua`; `...\AircraftWeaponPack\aim9_family.lua` (`name="GAR-8"`) |
| `F-5E-3` | AIM-9P | 7 | `{9BFD8C90-F7AE-4e90-833B-BFD0CED0E536}` | `AIM-9P` | `USA standard` | `...\F-5E\UnitPayloads\F-5E-3.lua`; `...\AircraftWeaponPack\aim9_family.lua` |
| `F-5E-3` | AIM-9P5 | 7 | `{AIM-9P5}` | `AIM-9P5` | `USA standard` | `...\F-5E\UnitPayloads\F-5E-3.lua`; `...\AircraftWeaponPack\aim9_family.lua` |
| `A-10C_2` | AIM-9M | 11 | `{DB434044-F5D0-4F1F-9BA9-B73027E18DD3}` | `AIM_9` | `104th FS Maryland ANG, Baltimore (MD)` | `...\A-10\UnitPayloads\A-10C_2.lua`; `...\A-10\A-10A.lua`; `...\AircraftWeaponPack\aim9_family.lua` |
| `MiG-21Bis` | R-3S | 1 | `{R-3S}` | `R-3S` | no livery directory in install | `...\MiG-21bis\UnitPayloads\MiG-21bis.lua`; `...\AircraftWeaponPack\R3_family.lua` |
| `MiG-21Bis` | R-60 | 1 | `{R-60 2L}` | `R-60` | no livery directory in install | `...\MiG-21bis\UnitPayloads\MiG-21bis.lua`; `...\AircraftWeaponPack\R_60.lua` |
| `MiG-29 Fulcrum` | R-60 | 1 | `{MISSILE_R-60_APU-60}` | `R-60` | `Air Force Standard` | `...\MiG-29-Fulcrum\UnitPayloads\MiG-29 Fulcrum.lua`; `...\AircraftWeaponPack\R_60.lua` |
| `MiG-29 Fulcrum` | R-73 | 1 | `{MISSILE_R-73_APU-73}` | `R-73` | `Air Force Standard` | CLSID/station: `...\MiG-29-Fulcrum\UnitPayloads\MiG-29 Fulcrum.lua`; **UNVERIFIED weapon `name` source was not present in the inspected pack files; live run is the arbiter** |
| `Su-34` | R-73 | 1 | `{FBC29BFE-3D24-4C64-B81D-941239D12249}` | `R-73` | `Russian Air Force` | `...\Su-34\Su-34.lua` (`Pylons`/`SIDE_R73`); **UNVERIFIED (this install has no Su-34 UnitPayloads directory and no inspected R-73 pack table)** |
| `Su-34` | R-77 | 2 | `{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}` | `R-77` | `Russian Air Force` | `...\Su-34\Su-34.lua` (`STATION_2`/`AKU_R77`); **UNVERIFIED (no Su-34 UnitPayloads directory or inspected R-77 pack table)** |

The installed `aim120_family.lua` reports AIM-120B as `AIM_120` (not
`AIM_120B`), and `aim9_family.lua` reports AIM-9M as `AIM_9`, AIM-9L as
`AIM-9L`, AIM-9P as `AIM-9P`, AIM-9X as `AIM_9X`, and AIM-9B as `GAR-8`.

## Phase-1 cells

Each invocation below is run against that cell's NDJSON output. Replace
`<run.ndjson>` with the selected file under
`C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Logs\telemetry\`.

### Blue armed / red unarmed

These assert exactly one listed weapon, and that every firing initiator is the
blue AI airframe.

```text
FA-18C_hornet / AIM-9L:  node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons AIM-9L --initiator-type FA-18C_hornet
FA-18C_hornet / AIM-9M:  node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons AIM_9 --initiator-type FA-18C_hornet
FA-18C_hornet / AIM-9P:  node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons AIM-9P --initiator-type FA-18C_hornet
FA-18C_hornet / AIM-9X:  node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons AIM_9X --initiator-type FA-18C_hornet  # already covered
FA-18C_hornet / AIM-120C: node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons AIM_120C --initiator-type FA-18C_hornet  # already covered
F-16C_50 / AIM-9X:      node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons AIM_9X --initiator-type F-16C_50
F-16C_50 / AIM-120B:    node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons AIM_120 --initiator-type F-16C_50
F-16C_50 / AIM-120C:    node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons AIM_120C --initiator-type F-16C_50
F-15ESE / AIM-9M:      node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons AIM_9 --initiator-type F-15ESE
F-15ESE / AIM-120B:    node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons AIM_120 --initiator-type F-15ESE
F-15ESE / AIM-7M:      node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons AIM_7 --initiator-type F-15ESE
F-5E-3 / AIM-9B:       node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons GAR-8 --initiator-type F-5E-3
F-5E-3 / AIM-9P:       node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons AIM-9P --initiator-type F-5E-3
F-5E-3 / AIM-9P5:      node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons AIM-9P5 --initiator-type F-5E-3
A-10C_2 / AIM-9M:      node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons AIM_9 --initiator-type A-10C_2
```

`FA-18C_hornet/AIM-9L`, `/AIM-9M`, and `/AIM-9P` are catalogue cells but are
currently **UNVERIFIED** because the current hornet `UnitPayloads` file does
not contain explicit entries for those variants. F-16C_50/AIM-7E/M is not a
cell: the F-16C_50 `UnitPayloads` file has no AIM-7 entry.

### Red armed / blue unarmed

These also assert that the run emitted at least one `asset.spawned` event for
the swapped bandit airframe.

```text
MiG-21Bis / R-3S:       node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons R-3S --initiator-type MiG-21Bis --asset-type MiG-21Bis
MiG-21Bis / R-60:       node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons R-60 --initiator-type MiG-21Bis --asset-type MiG-21Bis
MiG-29 Fulcrum / R-60:  node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons R-60 --initiator-type "MiG-29 Fulcrum" --asset-type "MiG-29 Fulcrum"
MiG-29 Fulcrum / R-73:  node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons R-73 --initiator-type "MiG-29 Fulcrum" --asset-type "MiG-29 Fulcrum"
Su-34 / R-73:            node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons R-73 --initiator-type Su-34 --asset-type Su-34
Su-34 / R-77:            node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --weapons R-77 --initiator-type Su-34 --asset-type Su-34
```

The MiG-29 R-73 and both Su-34 cells are **UNVERIFIED** until a live run
confirms the expected weapon table name and that the AI accepts the researched
CLSID. The pylon CLSIDs themselves are taken from the installed aircraft
sources and were not guessed.

### Gun cell

```text
FA-18C_hornet / guns: node build/verify-run-ordnance.mjs --ndjson <run.ndjson> --guns
```

This deliberately permits zero gun events. If any are emitted, every one must
have `weapon.category == "other-discrete"`; the script prints the observed
count.

### Catalogue-only weapons not runnable on this install

`R-27ER`, `R-27ET`, `R-24R`, `R-24T`, and `R-33` are catalogue-only here. No
installed airframe in this phase's set carries a verified runnable cell for
them. Do not add matrix code for these weapons.

## Run procedure and evidence

For each cell, change the four local knobs, restart/reload the dev mission once,
and use the unattended procedure in
[`unattended-test-loop.md`](unattended-test-loop.md). Use its 400-second
auto-stop for a single-shot cell, then run the matching verifier against the
new NDJSON file. Do not use the shipping build for this dev-only rig.

| Run key | Cell | Verdict |
|---|---|---|
| _pending_ | _pending_ | _pending_ |
| _pending_ | _pending_ | _pending_ |
| _pending_ | _pending_ | _pending_ |
