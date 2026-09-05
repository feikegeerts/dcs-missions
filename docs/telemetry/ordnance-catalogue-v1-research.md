# Ordnance valuation catalogue v1 research

## Decision and scope

Catalogue `ordnance` version 1 is an immutable, human-reviewed score catalogue
effective 2026-09-04. It contains exactly 24 canonical DCS type keys: 16
missiles and 8 aircraft. It is deliberately **not** a catalogue of every type in
DCS. It covers the Slice 11 airframe/AAM matrix plus four source-only missile
keys that the same airframes can emit (`R-60`, `AIM_7`, `AIM-7F`, and
`AIM-7P`). Any other `dcs_type` remains explicitly unpriced.

The raw `dcs_type` is never normalized. Case, punctuation, spaces, hyphens, and
underscores are part of the identity. In particular, display names such as
AIM-9M, AIM-120B, R-73, and R-77 map to runtime keys `AIM_9`, `AIM_120`,
`P_73`, and `P_77` respectively.

`faction` is catalogue affiliation (`blue` or `red`), not the coalition on a
particular event. The unattended matrix intentionally used some normally blue
aircraft as red test targets. Runtime coalition remains telemetry data.

## DCS identity audit

The runtime event is the authority for a key. The other sources predict or
cross-check what DCS can emit but cannot override a live observation:

1. [DCS `Object.getTypeName`](https://wiki.hoggitworld.com/view/DCS_func_getTypeName)
   documents the simulator API that returns an object's type name. Aircraft
   `asset.spawned` identity is captured from this runtime concept.
2. [Quaggles' DCS Lua datamine](https://github.com/Quaggles/dcs-lua-datamine)
   exports selected in-memory DCS tables after launch. Its weapon index
   independently shows keys including `AIM_9`, `AIM_9X`, `AIM_120`,
   `AIM_120C`, the AIM-7 variants, `P_73`, and `P_77`. It is a
   version-sensitive community extraction, not a stable public API.
3. [pydcs' exporter](https://github.com/pydcs/dcs/blob/master/tools/pydcs_export.lua)
   reads DCS weapon launchers and aircraft definitions from the running Mission
   Editor database. It demonstrates why CLSID/display-name inventories help
   establish reachability but do not by themselves prove the event string.
4. [MOOSE Core.Event](https://flightcontrol-master.github.io/MOOSE_DOCS/Documentation/Core.Event.html)
   documents `EVENTDATA.IniTypeName`, `WeaponName`, and `WeaponTypeName` for
   event handling. Slice 11 retained DCS values as pass-through telemetry and
   then verified the emitted values in unattended runs.
5. Installed DCS weapon definitions, aircraft `UnitPayloads`, and pylon
   definitions were inspected under `<DCS install>\CoreMods\aircraft\` to map
   reachable CLSIDs to weapon names. The portable paths and exact matrix cells
   are recorded in [the Slice 11 matrix](slice-11-ordnance-matrix.md).

The matrix produced 15 passing weapon cells, 4 confirmed naming deviations,
and 3 no-shot cells; the gun cell emitted no shot events and passed its explicit
zero-or-more policy. The matrix document is the durable record of run keys and
deviation evidence. `R-60` remained a no-shot weapon in the matrix, but its DCS
weapon definition and reachable MiG-21/MiG-29 loadouts establish the
source-only key. The three source-only AIM-7 keys are reachable from Hornet
pylons. These bounded claims do not imply global DCS coverage.

## Actionable completeness audit

Version 1 is complete only for its approved matrix, not for every missile the
eight airframes can load and not for every installed fixed-wing module. The
tables below are a **minimum source-proven expansion backlog**, assembled from
the installed aircraft/weapon Lua definitions and the Quaggles in-memory table
export. They intentionally do not claim exhaustive static coverage. DCS updates
and licensed modules can add, remove, or hide definitions.

“Static-high” means an exported weapon table has the exact `name` shown and an
aircraft source exposes a matching launcher or loadout. It is still not a live
event observation. “Static-candidate” means the launcher or module inventory is
known but the runtime name remains hidden, ambiguous, or binary-only. Every key
must be promoted by logging `event.weapon:getTypeName()` (and the corresponding
MOOSE `WeaponName`/`WeaponTypeName`) from a real `S_EVENT_SHOT` before catalogue
entry.

Bombs, glide bombs, unguided/guided rockets, decoys, and captive/training rounds
are excluded from this audit. Thus JSOW/AGM-154, BK90/DWS39, GB-6, APKWS,
BRM-1, TALD/ADM-141, CATM, and CAIM families are not listed here.

### Gaps loadable by the current eight Slice 11 airframes

| Category           | Source-proven exact key or probe candidate                                  | Representative current airframe(s)                                         | Confidence/status                                                                                                                                                                                                    | Action                                                                                  |
| ------------------ | --------------------------------------------------------------------------- | -------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| AAM                | `R-3R`, `R-13M`, `R-13M1`, `R-55`, `RS2US`                                  | `MiG-21Bis`                                                                | Static-high weapon names; `R-3R` also appears directly in installed UnitPayloads. No Slice 11 live shot.                                                                                                             | Add one MiG-21 cell per key.                                                            |
| AAM                | `P_60` (R-60M)                                                              | `MiG-29 Fulcrum`; MiG-21 family also exposes R-60M                         | Static-high: exported definition has `name="P_60"`; installed MiG-29 UnitPayloads use R-60M launchers. No live shot.                                                                                                 | Probe separately from v1 `R-60`; do not alias them.                                     |
| AAM                | `P_27P`, `P_27PE`, `P_27T`, `P_27TE` (R-27R/ER/T/ET)                        | `MiG-29 Fulcrum`; `Su-34` exposes R/ER launchers                           | Static-high exact aliases from `r27_family.lua`; installed MiG-29 UnitPayloads expose all four variants. No live shot.                                                                                               | Run four pinned MiG-29 cells, then a Su-34 cross-check for R/ER.                        |
| AAM                | `AIM-9J`                                                                    | `F-15ESE`, `F-5E-3`                                                        | Static-high: installed `aim9_family.lua` declares exact `name="AIM-9J"`; both aircraft pylon definitions expose CLSID `{AIM-9J}`. No live shot.                                                                      | Add one pinned cell per airframe and assert the hyphenated event key.                   |
| AAM                | `AIM-9P3`                                                                   | `F-16C_50`, `F-5E-3`                                                       | Static-high: installed `aim9_family.lua` declares exact `name="AIM-9P3"`; both aircraft pylon definitions expose CLSID `{AIM-9P3}`. No live shot.                                                                    | Add one pinned cell per airframe; do not collapse it into v1 `AIM-9P`.                  |
| A/G / ATGM         | `AGM_65D`, `AGM_65E`, `AGM_65F`, `AGM_65G`, `AGM_65H`, `AGM_65K`, `AGM_65L` | `FA-18C_hornet`, `F-16C_50`, `A-10C_2`, `F-15ESE` as pylon support permits | Static-high family definitions; installed presets directly show D/G/H/K/L subsets, and the F-15ESE pylon source explicitly exposes D/G/H/K. No live matrix shots.                                                    | Inventory the exact CLSID-to-airframe subset, then fire one of each exact key.          |
| A/G / ATGM         | `X_29L`, `X_29T`                                                            | `Su-34`                                                                    | Static-high launcher and weapon-family names; not live-proven here.                                                                                                                                                  | Add laser/TV target cells and record the emitted names.                                 |
| A/G / ATGM         | `{Kh-66_Grom}` launcher; runtime key **unknown**                            | `MiG-21Bis`                                                                | Static-candidate: installed UnitPayloads prove the launcher, but the reviewed public export did not establish a dependable runtime `name`. Module implementation may be binary-only.                                 | Mandatory live `getTypeName()` probe; do not preseed `Kh-66`, `X-66`, or another guess. |
| A/G                | `AGM_130`                                                                   | `F-15ESE`                                                                  | Static-candidate: the common weapon definition declares top-level `name="AGM_130"` and the licensed F-15ESE pylon source exposes CLSID `{AGM_130C_9}`, but an inner definition also uses `AGM_130C_9`. No live shot. | Mandatory live `getTypeName()` probe; do not substitute the CLSID/internal name.        |
| ARM                | `AGM_88` (displayed as AGM-88C)                                             | `FA-18C_hornet`, `F-16C_50`                                                | Static-high: the exported definition is `name="AGM_88"`, not `AGM_88C`; both installed UnitPayloads expose AGM-88C loadouts.                                                                                         | Use a radiating target and assert the exact `AGM_88` event key.                         |
| ARM                | `X_31P`, `X_58`                                                             | `Su-34`                                                                    | Static-high exported names and installed Su-34 launchers; no live shot.                                                                                                                                              | Add one emitting-target cell per key.                                                   |
| Anti-ship / cruise | `AGM_84D`, `AGM_84E`, `AGM_84H`                                             | `FA-18C_hornet`                                                            | Static-high exported names and installed Hornet loadouts; no live shot.                                                                                                                                              | Probe each variant against a ship/route-capable target.                                 |
| Anti-ship / cruise | `X_31A`, `X_35`                                                             | `Su-34`                                                                    | Static-high launchers; `X_31A` has a reviewed exported `name`; `X_35` still needs a same-build name cross-check.                                                                                                     | Probe both; treat `X_35` as unconfirmed until emitted.                                  |

These are absent from v1 even when the same airframe already appears in v1.
Loadability is not enough: the F-15E “AIM-120B” deviation proved that labels and
CLSIDs can resolve to a different runtime weapon.

### Additional installed official/licensed fixed-wing families

This second queue broadens module coverage beyond the eight Slice 11 airframes.
Repeated keys are useful cross-airframe probes but would still become only one
catalogue item.

| Category           | Source-proven exact key or probe candidate                            | Representative installed family  | Confidence/status                                                                                                       | Action                                                                        |
| ------------------ | --------------------------------------------------------------------- | -------------------------------- | ----------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| AAM                | `AIM_54A_Mk47`, `AIM_54A_Mk60`, `AIM_54C_Mk47`, `AIM_54C_Mk60`        | F-14A/B                          | Static-high in the public in-memory export; not live-proven by this project.                                            | Four F-14 launch cells.                                                       |
| AAM                | `MMagicII`, `Matra Super 530D`                                        | Mirage 2000C                     | Static-high exact names, including the space in `Matra Super 530D`.                                                     | Two Mirage 2000C cells.                                                       |
| AAM                | `R_550_M1`, `R_550`, `R_530F_EM`, `R_530F_IR`, `Super_530F`           | Mirage F1                        | Static-high public export; module/variant pylon availability must be pinned.                                            | Inventory F1 variants, then one cell per reachable key.                       |
| AAM                | `PL-5EII`, `SD-10`                                                    | JF-17                            | Static-high public export; not live-proven here.                                                                        | Two JF-17 cells.                                                              |
| AAM                | `Rb 24`, `Rb 24J`, `Rb 74`                                            | AJS-37                           | Static-high public export with significant spaces; not live-proven here.                                                | Preserve spaces exactly in three Viggen cells.                                |
| AAM                | `HB-AIM-7E`, `HB-AIM-7E-2`, plus reachable `AIM-9E`/`AIM-9J` variants | F-4E                             | Static source exists, but licensed-module launcher resolution may differ from the public table/file names.              | Treat all as static-candidates until live `getTypeName()` output is captured. |
| A/G / ATGM         | `AGM_65E`, `AGM_65F`                                                  | AV-8B N/A                        | Static-high family definitions; pylon resolution not live-proven here.                                                  | Cross-airframe Maverick cells after the current-eight subset.                 |
| A/G / ATGM         | `AGM_12A`, `AGM_12B`, `AGM_12C_ED`                                    | F-4E                             | Static source names; licensed-module runtime resolution is unproven.                                                    | Live Bullpup probes; retain `_ED` only if emitted.                            |
| A/G / ATGM         | `X_25ML`, `X_29L`, `X_29T`                                            | Su-25/Su-25T                     | Static-high common weapon names; not live-proven by this project.                                                       | Probe only keys not already established on Su-34.                             |
| ARM                | `AGM_122`                                                             | AV-8B N/A                        | Static-high public export; no project live shot.                                                                        | One radiating-target cell.                                                    |
| ARM                | `AGM_45A`, `AGM_45B`, `HB_AGM_78`                                     | F-4E                             | Static source names; `HB_AGM_78` and module-side resolution are licensed/binary-sensitive.                              | Mandatory live probe for each reachable launcher.                             |
| ARM                | `X_25MPU`, `X_58`                                                     | Su-25T                           | Static-high family names; no project live shot.                                                                         | One emitting-target cell per unresolved key.                                  |
| ARM                | `LD-10` candidate                                                     | JF-17                            | Static-candidate: known licensed-module weapon, but the exact same-build event name was not established in this review. | Mandatory live probe; do not infer punctuation from the display name.         |
| Anti-ship / cruise | `AM39`                                                                | Mirage F1 family where supported | Static-high public export; aircraft-variant support and runtime emission need confirmation.                             | Pin the supporting F1 variant and fire against a ship.                        |
| Anti-ship / cruise | `C_701IR`, `C_701T`, `C_802AK`, `CM_802AKG`                           | JF-17                            | Static source names; licensed-module launcher/runtime resolution remains unproven here.                                 | One ship/route cell per reachable key.                                        |
| Anti-ship / cruise | Rb-04/Rb-15 launcher families; runtime keys **unknown in this audit** | AJS-37                           | Static-candidate/binary-sensitive. Display names are not safe event aliases.                                            | Capture live names before documenting or pricing them.                        |

### Staged expansion and live-probe plan

1. **Freeze v1.** Never add these rows to version 1. Create a candidate v2
   inventory with source build/version, airframe, pylon, CLSID, display label,
   expected key, and confidence.
2. **Close the current-eight AAM gaps first.** Extend the existing unattended
   rig with the MiG-21 and MiG-29 keys above. Require one `ordnance.fired`, the
   expected initiator type, and direct `event.weapon:getTypeName()` output.
3. **Add target-specific missile cells.** Use ground, emitter, and ship targets
   for A/G/ATGM, ARM, and anti-ship/cruise weapons. Keep one missile per run and
   lengthen the run only where launch logic requires it.
4. **Probe binary/licensed candidates without guessed aliases.** Log CLSID,
   display label, raw DCS `getTypeName()`, MOOSE `WeaponName`, and
   `WeaponTypeName`. A no-shot result proves only aircraft/loadout reachability,
   not weapon identity.
5. **Broaden by installed family.** Run F-14, Mirage, JF-17, Viggen, Harrier,
   Phantom, and Su-25 queues in small batches. Deduplicate by exact emitted key,
   not by marketing name.
6. **Gate v2 separately.** Resolve every live key to one category and reviewed
   value or explicitly leave it unpriced. Publish a new immutable catalogue and
   seed version only after the matrix, source notes, and unknown-key report are
   reviewed.

## Pricing convention

Values are current or replacement-equivalent nominal USD **score values** as of
the effective date. They are not a uniform procurement-cost dataset:

- AIM-9X is the sole sourced value.
- Other missiles are reviewed relative-capability estimates. Russian/Soviet
  missile values are order-of-magnitude estimates because dependable public
  recurring unit costs were not found.
- Aircraft values are score-scale estimates. They are not claimed to be either
  historical production prices or current replacement procurement costs and
  should not be compared directly with the missile budget-exhibit figure.
- Source years and cost definitions differ. A future source correction creates
  a new catalogue version; it does not rewrite version 1.
- DSCA notifications and other package totals can include support, training,
  spares, equipment, and services. Version 1 does not divide package totals by
  headline quantities to manufacture unit prices.

The frequently repeated `$125,000` AIM-7 figure was rejected as a source
because dependable year and variant attribution could not be established.
`AIM_7` and `AIM-7MH` therefore remain estimates, as do the other Sparrow
variants.

### AIM-9X source and rounding

The source is the **Department of Defense Fiscal Year (FY) 2026 Budget
Estimates, Navy, Justification Book Volume 1 of 1, Weapons Procurement, Navy**,
June 2025:

- LI 2209 / Sidewinder
- Exhibit P-5, Cost Analysis, Navy page 3 of 20
- Item 1 / Sidewinder Block II
- Flyaway - MISSILE Cost, Recurring Cost, element 1.1.1, All Up Round - Block II
- FY 2026 Base unit cost: `$447,092.74`, quantity 110, displayed total cost
  `$49.180M`

Version 1 uses the exhibit's explicit recurring live-round/AUR unit-cost field,
rounded to a whole-dollar score value:

```text
round($447,092.74) = $447,093
```

The displayed `$49.180M` total is rounded to three decimal places and is only a
cross-check; dividing it by 110 would discard the more precise unit-cost field.

Sources:

- Original Navy URL:
  `https://www.secnav.navy.mil/fmc/fmb/Documents/26pres/WPN_Book.pdf`
- Archived capture used for review:
  `https://web.archive.org/web/20250702015950id_/https://www.secnav.navy.mil/fmc/fmb/Documents/26pres/WPN_Book.pdf`

### Official family anchors for later research

The same Navy book contains two useful current family exhibits. They are
research leads only and do **not** make v1 AIM-120B/C or legacy AGM-88C HARM
values sourced:

- **AMRAAM:** LI 2206 / AMRAAM, Exhibit P-5, Navy page 3 of 13 (PDF page 103,
  Volume 1 page 73), recurring cost element 1.1.1 “AIM-120 MISSILE - ALL-UP-
  ROUND (AUR)”: FY 2026 unit cost `$1,167.000K`, quantity 51, total
  `$59.517M`. The P-40 description identifies the current procured variant as
  AIM-120D and explicitly notes service/type mix effects. It is therefore a
  modern AMRAAM family anchor, not an AIM-120B or AIM-120C unit price.
- **AARGM-ER:** LI 2327 / AARGM-ER, Item 1, Exhibit P-5, Navy page 4 of 24
  (PDF page 300, Volume 1 page 270), recurring cost element 1.1.1 “ES010
  AGM-88G All Up Round (AURs)”: FY 2026 unit cost `$1,524.000K`, quantity 141,
  total `$214.884M`. This is an AGM-88G AARGM-ER figure with concurrent-
  procurement assumptions, not a price for the legacy AGM-88C HARM represented
  by DCS key `AGM_88`.

Both citations use the original/archive URLs above. Their cost definitions and
variants must remain explicit if they are used to calibrate estimates in a
future catalogue.

## Version 1 values

### Missiles

| DCS type   | Display name               | Faction | USD score value | Basis    |
| ---------- | -------------------------- | ------- | --------------: | -------- |
| `GAR-8`    | AIM-9B Sidewinder          | blue    |          75,000 | estimate |
| `R-3S`     | R-3S                       | red     |          50,000 | estimate |
| `R-60`     | R-60                       | red     |         100,000 | estimate |
| `AIM-9P`   | AIM-9P Sidewinder          | blue    |         125,000 | estimate |
| `AIM-9L`   | AIM-9L Sidewinder          | blue    |         175,000 | estimate |
| `AIM-9P5`  | AIM-9P5 Sidewinder         | blue    |         200,000 | estimate |
| `AIM_9`    | AIM-9M Sidewinder          | blue    |         225,000 | estimate |
| `P_73`     | R-73                       | red     |         300,000 | estimate |
| `AIM_9X`   | AIM-9X Block II Sidewinder | blue    |         447,093 | sourced  |
| `AIM-7F`   | AIM-7F Sparrow             | blue    |         250,000 | estimate |
| `AIM_7`    | AIM-7M Sparrow             | blue    |         300,000 | estimate |
| `AIM-7MH`  | AIM-7M/H Sparrow           | blue    |         300,000 | estimate |
| `AIM-7P`   | AIM-7P Sparrow             | blue    |         350,000 | estimate |
| `AIM_120`  | AIM-120B AMRAAM            | blue    |         900,000 | estimate |
| `AIM_120C` | AIM-120C AMRAAM            | blue    |       1,050,000 | estimate |
| `P_77`     | R-77                       | red     |       1,100,000 | estimate |

### Aircraft

The aircraft figures preserve the reviewed score scale that preceded this
source audit.

| DCS type         | Display name                   | Faction | USD score value | Basis    |
| ---------------- | ------------------------------ | ------- | --------------: | -------- |
| `FA-18C_hornet`  | F/A-18C Hornet                 | blue    |      29,000,000 | estimate |
| `F-16C_50`       | F-16C Block 50 Fighting Falcon | blue    |      33,000,000 | estimate |
| `F-15ESE`        | F-15ESE Strike Eagle           | blue    |      41,000,000 | estimate |
| `F-5E-3`         | F-5E-3 Tiger II                | blue    |       4,000,000 | estimate |
| `A-10C_2`        | A-10C II Thunderbolt II        | blue    |      13,000,000 | estimate |
| `MiG-21Bis`      | MiG-21Bis Fishbed              | red     |         500,000 | estimate |
| `MiG-29 Fulcrum` | MiG-29 Fulcrum                 | red     |      11,000,000 | estimate |
| `Su-34`          | Su-34 Fullback                 | red     |      30,000,000 | estimate |

## Persistence rule

The database identity is `(catalogue, version)` and each item identity is
`(catalogue, catalogue_version, dcs_type)`. The seed may fill missing rows after
an interrupted first run, but it never updates an existing row. Any changed
metadata, changed item, or unexpected item causes the seed to fail and report
the mismatch. This preserves old catalogue references and requires changed
values to be published under a new version.
