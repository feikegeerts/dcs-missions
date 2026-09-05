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
weapon table's `name` field. This table records the researched expectations;
the live-run results, confirmed deviations, and final verdicts are in
[Results](#results) below.
For readability, `...\` in a source cell expands to the portable common prefix
`<DCS install>\CoreMods\aircraft\`. The matrix was run against the dedicated
server installation present on 2026-09-04; an installation path is not part of
the evidence or the catalogue identity.

| Airframe | Weapon key | Pylon | CLSID | Expected runtime `dcs_type` | Livery used | Verification/source |
|---|---|---:|---|---|---|---|
| `FA-18C_hornet` | AIM-120C | 2 | `LAU-115_2*LAU-127_AIM-120C` | `AIM_120C` | `Australia 75 Sqn RAAF` | `...\FA-18C\UnitPayloads\FA-18C_hornet.lua`; `...\AircraftWeaponPack\aim120_family.lua` (`name="AIM_120C"`); live-proven |
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

Note: the F-15ESE/AIM-120B, F-15ESE/AIM-7M, and both Su-34 invocations were
run with the researched expected value and FAILed on it — the observed types
were `AIM_120C`, `AIM-7MH`, `P_73`, `P_77` (see [Confirmed catalogue
deviations](#confirmed-catalogue-deviations) below). The no-shot cells
(r02/r03/r04) also FAIL their weapon assertion by construction (zero shots
observed); their airframe evidence is still valid. See [Results](#results).

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

The 2026-09-04 matrix run was automated: a driver script did exactly this per
cell — set the four knobs, full server process restart (the mission's
400-second auto-stop ends the run), NDJSON capture, then the matching
verifier — with a 300-second minimum run-validity gate and per-cell retries
for invalid attempts (no run / early death / timeout / post-run error). One
driver bug was found and fixed during the run; see [g01 verdict
incident](#g01-verdict-incident-driver-bug-run-data-valid) below.

### Results

| Cell | Cell spec | Expected `dcs_type` | Observed `dcs_type` | Verdict | Run key |
|---|---|---|---|---|---|
| b01 | `FA-18C_hornet` / AIM-9L | `AIM-9L` | `AIM-9L` | PASS | `run-20260904T084214Z-24e1f801` |
| b02 | `FA-18C_hornet` / AIM-9M | `AIM_9` | `AIM_9` | PASS | `run-20260904T085938Z-16c8e047` |
| b03 | `FA-18C_hornet` / AIM-9P | `AIM-9P` | `AIM-9P` | PASS | `run-20260904T091059Z-0e13678f` |
| b04 | `FA-18C_hornet` / AIM-9X | `AIM_9X` | `AIM_9X` | PASS | `run-20260904T091836Z-21f1ba3a` |
| b05 | `FA-18C_hornet` / AIM-120C | `AIM_120C` | `AIM_120C` | PASS | `run-20260904T092613Z-6c4dba23` |
| b06 | `F-16C_50` / AIM-9X | `AIM_9X` | `AIM_9X` | PASS | `run-20260904T093348Z-5b67a541` |
| b07 | `F-16C_50` / AIM-120B | `AIM_120` | `AIM_120` | PASS | `run-20260904T094127Z-60353421` |
| b08 | `F-16C_50` / AIM-120C | `AIM_120C` | `AIM_120C` | PASS | `run-20260904T094904Z-465cea32` |
| b09 | `F-15ESE` / AIM-9M | `AIM_9` | `AIM_9` | PASS (2nd attempt) | `run-20260904T120037Z-6b554759` |
| b10 | `F-15ESE` / AIM-120B | `AIM_120` | `AIM_120C` | DEVIATION | `run-20260904T100416Z-5c145827` |
| b11 | `F-15ESE` / AIM-7M | `AIM_7` | `AIM-7MH` | DEVIATION | `run-20260904T101153Z-2a93f800` |
| b12 | `F-5E-3` / AIM-9B | `GAR-8` | `GAR-8` | PASS | `run-20260904T101931Z-5a082494` |
| b13 | `F-5E-3` / AIM-9P | `AIM-9P` | `AIM-9P` | PASS | `run-20260904T102711Z-2205b395` |
| b14 | `F-5E-3` / AIM-9P5 | `AIM-9P5` | `AIM-9P5` | PASS | `run-20260904T103453Z-406d8b61` |
| b15 | `A-10C_2` / AIM-9M | `AIM_9` | `AIM_9` | PASS | `run-20260904T104233Z-1490287c` |
| g01 | `FA-18C_hornet` / guns | 0+ gun events, `other-discrete` | 0 gun events | PASS (re-verified) | `run-20260904T123101Z-4b0c2dd6` |
| r01 | `MiG-21Bis` / R-3S | `R-3S` | `R-3S` | PASS | `run-20260904T105011Z-34638614` |
| r02 | `MiG-21Bis` / R-60 | `R-60` | none (no-shot) | NO-SHOT | `run-20260904T120815Z-5c9ecc1a` |
| r03 | `MiG-29 Fulcrum` / R-60 | `R-60` | none (no-shot) | NO-SHOT | `run-20260904T121551Z-197d1d9b` |
| r04 | `MiG-29 Fulcrum` / R-73 | `R-73` | none (no-shot) | NO-SHOT | `run-20260904T122327Z-48643a6d` |
| r05 | `Su-34` / R-73 | `R-73` | `P_73` | DEVIATION | `run-20260904T112058Z-245ff6bc` |
| r06 | `Su-34` / R-77 | `R-77` | `P_77` | DEVIATION | `run-20260904T112832Z-5f31b7f8` |

Every PASS cell observed exactly one `ordnance.fired` with the observed type
above, fired by the expected initiator airframe, with `mission.ended` present
after a full ~400-second run. The red-armed cells additionally passed the
`asset.spawned` assertion for the swapped bandit airframe, so the
`MiG-21Bis` and `MiG-29 Fulcrum` airframe `dcs_type` values are live-proven
even in the no-shot cells.

- **b09** — the first full-length attempt (11:55–12:03 local, original pass)
  was a no-shot; the re-run attempt fired `AIM_9`. (An earlier b09 attempt at
  ~10:55 local was an instant-death run killed by the driver-v1 reload-flag
  incident, not a valid run.)
- **r02, r03, r04** — two full-length attempts each (original pass + re-run),
  both no-shot: the bandit AI did not get into launch range for the
  short-range IR R-60 (r02/r03) or R-73 (r04) within the 400-second window.
  Weapon-level `dcs_type` for these three entries remains unproven at
  runtime; the `P_73` identifier for the R-73 is independently corroborated
  by the Su-34 run (r05) and the DCS-internal identifiers below.
- **DEVIATION** rows are not rig failures: the run was valid and the weapon
  fired; the observed type simply differs from the researched expectation.
  Details below.

### Confirmed catalogue deviations

1. **F-15ESE "AIM-120B" loadouts are actually the AIM-120C model** (b10,
   observed `AIM_120C`). In
   `...\F-15E\UnitPayloads\F-15ESE.lua` the
   loadouts named "CATM-9M x 3, AIM-120B" (line 297) and "AIM-9M x 4,
   AIM-120B x 4, TGP, NVP, Fuel Tanks x 2" (line 333) both use CLSID
   `{40EF17B7-F508-45de-8566-6FFECC0C1AB8}` — the same CLSID the file's
   AIM-120C loadouts use. The F-15E module has no separate AIM-120B weapon
   model, so the "AIM-120B" pylon entry resolves to the AIM-120C model and
   DCS emits `AIM_120C`. Contrast F-16C_50 (b07, PASS): its AIM-120B pylon
   uses the distinct CLSID `{C8E06185-7CD6-4C90-959F-044679E90751}` and
   emits `AIM_120`.
2. **F-15ESE AIM-7M key loads the AIM-7H model** (b11, observed `AIM-7MH`).
   The cell's AIM-7 pylon entries in
   `...\F-15E\UnitPayloads\F-15ESE.lua` (lines 736/740) use CLSID `{AIM-7H}`,
   whose runtime type is `AIM-7MH` — not the base `AIM_7` name from
   `aim7_family.lua`.
3. **Su-34 R-73/R-77 emit export-identifier names** (r05/r06, observed
   `P_73`/`P_77`). This install has no Lua weapon-pack table for the R-73/R-77
   (`AircraftWeaponPack` ships `R_60.lua`, `R3_family.lua`, `r27_family.lua`,
   but no R-73/R-77 pack). `P_73`/`P_77` are DCS-internal weapon type
   identifiers — P-73/P-77 being the Russian export designations of the
   R-73/R-77: the DTC threat database groups "R-77" threats under
   `wstype = P_77_` (`...\FA-18C\DTC\threat_base.lua`), and
   `...\MiG-29-Fulcrum\MiG-29-Fulcrum.lua` line 1328 declares the R-73 with
   the `P_73` identifier.

### g01 verdict incident (driver bug, run data valid)

The re-run driver's g01 verdict came back FAIL with verifier output equal to
the usage text (exit 2). Root cause, reproduced and fixed: the driver builds
the verifier argument list with a helper that returns `@("--guns")` for the
gun cell — a one-element array, which PowerShell unwraps to a bare string on
assignment, and splatting a string with `@vargs` passes it
character-by-character (`--guns` → `- - g u n s`). The verifier rejected the
unknown `-` arguments, printed usage to stderr, and exited 2. The four-arg
cells returned real arrays and were unaffected. The run itself was valid: the
NDJSON is complete (`mission.ended` present, both aircraft `asset.spawned` as
`FA-18C_hornet`, the matrix line confirms `gun_test=true`), and re-running the
exact verifier invocation against the same file exits 0 with all assertions
PASS (0 gun events — explicitly permitted for the gun cell). The driver was
fixed by wrapping the helper result in `@(...)`; g01 is recorded PASS on the
run key above.

### Evidence locations (machine-local, transient)

- NDJSON run files:
  `C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Logs\telemetry\run-<key>.ndjson`
  (they persist across server restarts; junk runs from the driver-v1 incident
  are still in that directory — only the run keys in the table above are
  evidence).
- Working logs: `C:\Users\g_for\AppData\Local\Temp\opencode\slice11-matrix\` —
  `cells.tsv` (raw driver verdicts, including the annotated invalidated g01
  row), `driver.log` (full history including the driver-v1 incident and the
  per-cell knob lines), `cell-<id>-verifier.txt` (per-cell verifier output).
  The Results table above is the durable record.
