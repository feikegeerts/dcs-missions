# MOOSE Class Map (stable / master-ng)

Condensed from the official index. Doc pages: `https://flightcontrol-master.github.io/MOOSE_DOCS/Documentation/<Module>.<Class>.html`

## Core — building blocks you'll use constantly

| Class | Purpose |
|---|---|
| **SPAWN** | Dynamically spawn new groups (from a ME template group). Waves, limits, scheduled/random spawning. |
| **SPAWNSTATIC** | Spawn static objects from templates. |
| **ZONE** | Zones of various forms (`ZONE`, `ZONE_RADIUS`, `ZONE_AIRBASE`, `ZONE_GROUP`, `ZONE_POLYGON`...). |
| ZONE_DETECTION | Zone tied to a detection object + radius. |
| **SET** (`SET_GROUP`, `SET_UNIT`, `SET_CLIENT`, `SET_AIRBASE`, ...) | Collections with prefix/coalition/active filters; bulk `ForEach` actions. Backbone of most logic. |
| **EVENT** | DCS event pub/sub. Use `obj:HandleEvent(EVENTS.X)` + `function obj:OnEventX(data)`. |
| **FSM** | Finite state machines for long-lived processes (spawn managers, capture logic). |
| **TIMER** | Simple delay/interval function scheduler. |
| SCHEDULER / SCHEDULEDISPATCHER | Older scheduler (TIMER is the modern lightweight one). |
| **MENU** (`MENU_COALITION`, `MENU_GROUP`, `MENU_*_COMMAND`) | F10 radio menu trees and commands. |
| **MESSAGE** | On-screen messages (`:ToAll()`, `:ToCoalition()`, `:ToLog()`...). |
| **CLIENT** menus (Core.ClientMenu) | Per-client menu management. |
| **SETTINGS** (`_SETTINGS` global) | Mission defaults + auto player settings menus (A2G coords, metric/imperial, era). |
| **DATABASE** (`_DATABASE` global) | Registry of all mission objects/templates — query existing groups/units/statics. |
| BASE | Root of every class: `:I()`, `:E()`, `:TraceOn()`, event handling, scheduling. |
| Core.Point (COORDINATE) | Full 3D point API: smoke, explosions, markers, distance, translation. |
| Core.Vector (VECTOR) | Vector algebra. |
| Core.Report (REPORT) | Structured multi-line message reports. |
| Core.MarkerOps_Base (MARKEROPS_BASE) | React to F10 map markers placed by users. |
| Core.UserFlag (USERFLAG) | Bridge to ME trigger user flags. |
| Core.Beacon (BEACON) | TACAN/ICLS/Radio beacons. |
| Core.Condition (CONDITION) | Any/all condition evaluation. |
| Core.Goal (GOAL), Core.Spot (SPOT), Core.Pathline, Core.Astar, Core.TextAndSound, Core.Velocity | Misc utilities. |

## Ops — the modern AI/tasking system

| Class | Purpose |
|---|---|
| **AUFTRAG** | A "mission order" object: `NewCAP`, `NewCAS`, `NewSEAD`, `NewSTRIKE`, `NewBAI`, `NewTANKER`, `NewAWACS`, `NewARTY`, `NewTRANSPORT`... Assign to an OPS group. |
| **FLIGHTGROUP** | Enhanced airborne group that executes AUFTRAGs (RTB, fuel/ammo logic built in). |
| **ARMYGROUP** / **NAVYGROUP** | Same for ground / naval groups. |
| **OPSGROUP** | Common base of the three above (waypoints, tasks, state). |
| **EasyGCICAP** | One-call A2A defense network (replaces legacy `AI_A2A_Dispatcher`). |
| **EasyAG** | One-call A2G defense (replaces legacy `AI_A2G_Dispatcher`). |
| LEGION → **AIRWING** / **BRIGADE** / **FLEET** | Warehouse-based force providers with squadrons/platoons/flotillas. |
| **COMMANDER** / **CHIEF** | Auto tasking: legions + commander execute AUFTRAGs with own assets/payloads. |
| COHORT / SQUADRON / PLATOON / FLOTILLA | Asset containers inside legions. |
| **OPSZONE** | Strategic zone: capture state, ownership, draw — pairs with COMMANDER/CHIEF. |
| **OPSTRANSPORT** | Transport assignments between OPS groups/zones. |
| **CTLD** | MOOSE-native Combat Troops & Logistics (helo troop/crate logistics). Evaluate before external CTLD. |
| **CSAR** | Combat search & rescue (downed pilot pickup). |
| **AIRBOSS** | Carrier CASE I/II/III recovery management. |
| RECOVERYTANKER / RESCUEHELO | Carrier support assets. |
| FLIGHTCONTROL | ATC for AI and players. |
| ATIS / AWACS | Automated info service / AI AWACS (SRS TTS). |
| INTEL | Detection → contact reports. |
| PLAYERTASK / PLAYERRECCE | Tasking menus for players; helo recce/lasing. |
| TARGET | Target object for AUFTRAG/OPS. |
| OPERATION | Multi-phase campaign structure. |
| TARS | (Tactical air navigation/resource — see docs; sparse doc page.) |

## Functional — ready-made systems

| Class | Purpose |
|---|---|
| **SCORING** | Player score administration, CSV/log export. Start here for score tracking. |
| **SEAD** | SAM evasive/defensive reaction when fired upon. |
| **MANTIS** | Modular IADS (SAM network, AWACS-linked). Skynet alternative. |
| **SHORAD** | Short-range air defense coordination (pairs with MANTIS). |
| TIRESIAS | Electronic-warfare/decoy SAM behaviour. |
| **ARTILLERY** (ARMATA) | Artillery fire missions. |
| **DETECTION** / DETECTION_ZONES | FAC/RECCE detection → grouped target sets (older OPS input). |
| **DESIGNATE** | Target designation/lasing management. |
| **AUTOLASE** | Auto-lase targets. |
| **RAT** | Random air traffic. |
| **RANGE** | Bombing/strafing range scoring. |
| **ESCORT** | AI escort following a lead. |
| **FORMATION** | Large formations. |
| **FOX** | Missile trainer. |
| **AICSAR** | AI CSAR (older than Ops.CSAR — prefer the latter). |
| ATC_GROUND / PSEUDOATC | Ground traffic speed / basic ATC. |
| CLEANUP | Keep airbases clear of wrecks; kill airbase-bound missiles. |
| CLIENTWATCH | Track client slots, per-client modules. |
| SUPPRESSION | Suppress ground units under fire. |
| AMMOTRUCK | Arty resupply trucks. |
| MOVEMENT | Throttle simultaneous moving ground groups. |
| WAREHOUSE | Legacy logistics sim (mostly superseded by Ops LEGION). |
| ZONECAPTURECOALITION / ZONEGOAL(COALITION) | Zone capture/guard processes. |
| STRATEGO | Weighted decision helper. |

## Wrapper — OO wrappers over DCS objects

| Class | Purpose |
|---|---|
| **GROUP** / **UNIT** / **STATIC** / **AIRBASE** / **CLIENT** | Wrap DCS objects: `GROUP:FindByName(name)` then rich methods (alive, coordinate, tasking...). |
| CONTROLLABLE / IDENTIFIABLE / POSITIONABLE / OBJECT | Inheritance chain of the above. |
| MARKER | F10 map markers (create/update/remove). |
| SCENERY | Scenery objects. |
| WEAPON | Weapon tracking. |
| NET | net singleton wrapper. |
| STORAGE | Airbase warehouse contents. |
| DYNAMICCARGO | F8 dynamic cargo objects. |

## Sound / Utilities / Navigation / Shapes

- **Sound**: RADIO, RADIOQUEUE, RADIOSPEECH, **SRS** (SimpleRadio TTS), USERSOUND, SOUNDOUTPUT (play sound files/text-to-speech).
- **Utilities**: UTILS (MIST-derived helpers: serialisation, smoke, conversions), ENUMS, FIFO, PROFILER, SOCKET.
- **Navigation**: BEACONS, POINT (nav aids/fixes), RADIOS, TOWNS.
- **Shapes**: SHAPE_BASE, CUBE, LINE, OVAL, POLYGON, TRIANGLE (draw map shapes).

## Not present in stable (do NOT use)

`AI_A2A_Dispatcher`, `AI_A2G_Dispatcher`, `AI_BAI`, `AI_CAP`, `AI_CAS`, `AI_PATROL`, `AI_Formation`, `TASKING` (`TASK_A2G_Dispatcher`, `TASK_A2A_Dispatcher`, `COMMANDCENTER`, `MISSION`, `DETECTION_MANAGER`), `CARGO*`, `AI_CARGO*`, `RAT` legacy variants of Ops classes. All archived — use the Ops.* equivalents.
