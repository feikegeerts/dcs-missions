# Stock Bridge Feasibility Spike

**Status:** Slice 3 complete on stock DCS 2.9.29.27278. The full-client host and
dedicated-server gates both passed. The transport is proven:
`net.dostring_in("mission", ...)` with `a_do_script` inside, shifted return
mapping (sentinel recovery required), NUL-truncating returns, and a byte-exact
NUL-free 64 KiB frame round trip. Both environments passed two generations
with `failures=0` on every `RESULT`/`STOP_RESULT`, including durable hook-local
spool writes verified by reopen-and-byte-compare before bounded
acknowledgement.

## Decision

The selected approach is a project-owned GameGUI server hook that reaches the
mission trigger state through `net.dostring_in("mission", ...)`, then invokes
the mission scripting state's `a_do_script`. The direct hook-global
`a_do_script` assumption was disproved on DCS 2.9.29.27278. Discovery and full
queue probes characterized the nested route's availability, return-stack bug,
NUL truncation, and conservative size limit on this exact build.

The production hook will poll a mission-owned telemetry queue, durably spool
complete frames outside the mission sandbox, and acknowledge only the highest
sequence safely accepted into that spool.

This approach is preferred over unmodified DCS-gRPC and structured `dcs.log`
tailing because it can preserve mission-normalized envelopes, use server-only
multiplayer identity, and implement an application-level peek/acknowledge
protocol without exposing `io`, `os`, or `lfs` to mission Lua.

The local-host full-queue gate passed with stock sanitization on the installed
full DCS client in **Multiplayer → New Server** mode. Dedicated-server parity
then passed separately on the matching dedicated release channel. The selected
GameGUI bridge is therefore viable for downstream slices; this spike does not
implement the production bridge, which remains deferred to Slice 17.

## Current Environment

Evidence collected on 2026-08-31:

| Component | Observed state |
|---|---|
| Full DCS client | `2.9.29.27278` |
| Dedicated server | Updated from `2.9.28.26283` to `2.9.29.27278` before parity testing |
| Client `MissionScripting.lua` | Stock; development version preserved as `.telemetry-dev-backup` |
| Server `MissionScripting.lua` | Stock; development version preserved as `.telemetry-dev-backup` |
| Stock backups | Present as `MissionScripting.lua.orig` in both installations |
| Full-client host gate | Passed, two generations and clean stop |
| Dedicated-server gate | Passed, two generations, clean stop, and remote identity correlation |

## Evidence

### Installed DCS API

The installed `API/Sim_ControlAPI.md` documents that:

- `$WRITE_DIR/Scripts/Hooks/*.lua` files load in isolated GUI Lua states.
- Hook Lua has the Lua 5.1 standard libraries, including `io` and `os`, and the
  hook API exposes `lfs.writedir()`.
- `a_do_script("return 1,2,3")` returns mission-script values directly and is
  the replacement for obsolete, unsafe `net.dostring_in`.
- `net.get_player_info(playerID, "ucid")` exposes UCID on the server.
- `onPlayerTryConnect` receives UCID directly.
- Mission load, simulation start/stop, frame, pause/resume, network mission,
  player connection, and slot callbacks are available.
- `onPlayerStart`, `onPlayerStop`, and `onPlayerDisconnect` are never called for
  the local player ID.

The same installed documentation demonstrates `Sim.setUserCallbacks`, while
bundled DCS hooks call `DCS.setUserCallbacks`. The probe supports either name;
the runtime result must record which one exists.

### Local static gates

- `npm --prefix contracts run check`: 32 contract tests passed.
- `lua5.1 tests/lua/telemetry/run.lua`: 20 Lua telemetry tests passed.
- `stylua --check src/missions/duel-dynamic/telemetry tests/lua/telemetry`:
  passed.
- `lua5.1 tests/dcs/run-telemetry-bridge-probe-mock.lua`: passed.
- `lua5.1 tests/dcs/run-telemetry-bridge-api-discovery-mock.lua`: passed.

These checks validate the event contract and pure Lua work. They do not validate
the DCS bridge.

### Failed full-client runtime gate

The 2026-08-31 full-client multiplayer-host run on DCS 2.9.29.27278 proved:

- `Sim.setUserCallbacks` works from a Saved Games hook.
- A separately loaded companion hook continued receiving frames.
- Server-side player snapshots exposed a stable redacted UCID fingerprint and
  slot transition.
- The mission sandbox was restored to stock before launch.
- Hook-global `a_do_script` was `nil`; the probe stopped with
  `CHECK a_do_script.available FAIL type=nil`.

The preserved evidence is
`Saved Games\DCS\Logs\dcs.telemetry-probe-failed-a-do-script.*.log`. This is a
valid architectural failure, not an inconclusive test. It rejects the direct
global API assumed by the first probe.

### Nested API evidence and known defect

The installed `API/Sim_ControlAPI.md` shows an unqualified `a_do_script` call,
but does not explain that current examples reach it from the internal mission
trigger state. Official DCS 2.9.15 release notes explicitly reference
`net.dostring_in("mission", "a_do_script(...)")`.

DCS 2.9.18 reintroduced argument and return pass-through, but the ED forum's
reported bug demonstrates that the return stack is shifted and its last value
is dropped: expected `1,2,3` becomes `nil,1,2`. The bug was still confirmed in
2.9.23 and no later changelog through the installed 2.9.29 build records a fix.
The discovery hook therefore tests both the corrected and shifted mappings and
uses two sentinels to recover one framed string without guessing which behavior
is installed.

`net.dostring_in` remains documented as obsolete and unsafe. The 2.9.18
allowlist change was reverted one patch later, but actual availability on this
installation is a runtime gate. No `autoexec.cfg` exception will be added unless
the stock default is first shown to reject the nested call and the security
trade-off is explicitly accepted.

### Discovery round 1 runtime result

The 2026-08-31 full-client multiplayer-host run of
`tests/dcs/telemetry-bridge-api-discovery.lua` on DCS 2.9.29.27278, loading
`test-flight.miz` in **Multiplayer → New Server** with the client restored to
stock sanitization and no `autoexec.cfg` present, produced (final
`mission=test-flight multiplayer=true server=true` run):

- `CHECK full_client_host_mode PASS` — `isMultiplayer()==true`,
  `isServer()==true` under the host.
- `API ... net_dostring_in=function` — `net.dostring_in` is available in the
  hook state under stock defaults.
- `CHECK nested_a_do_script_available PASS` — the nested mission state exposes
  `a_do_script` as a function. **The nested route is viable under stock
  sanitization.**
- `OBSERVE return_mapping=shifted` — the ED shifted/drop-last return bug is
  live on this build. `a_do_script([[return "FIRST","SECOND","THIRD"]])`
  observed as `nil,FIRST,SECOND,nil`. The two-sentinel recovery logic is
  therefore required, not optional.
- `CHECK stock_mission_sandbox PASS` — `os`, `io`, `lfs`, `require`,
  `package`, and `loadlib` are all `nil` in the mission state.
- `CHECK binary_round_trip FAIL bytes=1` — a value with an embedded NUL came
  back truncated to the byte before the NUL.
- `CHECK framed_65536_round_trip FAIL bytes=32` — a 64 KiB frame containing a
  NUL came back truncated at that NUL (32 bytes), not at a length limit.

This is a decisive constraint: the return pass-through is a C-style string copy
that truncates at the first NUL byte. The earlier assumption that the bridge
must prove exact binary (NUL-bearing) preservation is therefore wrong for this
route. Production frames must be NUL-free by construction — a text header plus
JSON payload satisfies that — and the round 2 probe has been revised to
characterize the NUL truncation precisely and instead prove that a NUL-free
64 KiB frame round-trips byte-for-byte. The mock now emulates the NUL-truncating
return path and passes under both the `shifted` and `fixed` mappings.

If round 2 shows the NUL-free 64 KiB frame also fails (i.e. a true length cap,
not just NUL truncation), the 64 KiB frame limit must be lowered to the largest
proven round-trip size before the full queue probe is rerun.

### Discovery round 2 runtime result (passing)

The revised discovery probe passed cleanly on the same stock DCS 2.9.29.27278
full-client multiplayer host, `test-flight.miz` (log
`Saved Games\DCS\Logs\dcs.log.discovery-round-2.*`):

- `CHECK full_client_host_mode PASS`
- `CHECK nested_a_do_script_available PASS`
- `CHECK return_mapping_known PASS` with `OBSERVE return_mapping=shifted`
- `CHECK stock_mission_sandbox PASS`
- `CHECK nul_truncation_characterized PASS` (1 of 8 bytes survived)
- `CHECK framed_binary_truncates_at_first_nul PASS` (32 of 65536 bytes, exact)
- `CHECK framed_65536_nul_free_round_trip PASS` (65536 bytes, exact)
- `RESULT failures=0`

The transport is therefore fully characterized: `net.dostring_in("mission", ...)`
works under stock defaults; `a_do_script` is available in the nested mission
state; the return pass-through is shifted; returned strings truncate at the
first NUL; and a NUL-free 64 KiB frame round-trips byte-for-byte.

### Full-queue first-run finding: the shift drops a single return value

The first full-queue run (log
`Saved Games\DCS\Logs\dcs.log.full-queue-failed-single-value-drop.*`)
showed every transport check failing with `TLM_TRANSPORT_FAIL|nil|nil` while all
lifecycle, spool, host-mode, and identity checks passed. The wrapper executed,
so `net.dostring_in` and the trigger state work; `a_do_script` simply returned
no value.

Discovery had only observed *multi*-value returns (`1,2,3` → `nil,1,2`), so the
single-value case was unobserved. Under the same left-shift-with-nil-fill
semantics, a *single* return value `[S]` becomes `[nil]` — the value is dropped
entirely. The full-queue inner chunk returned exactly one value (the tagged
string), so `a_do_script` returned only `nil`.

The fix is to have the inner chunk return a **dummy second value** after the
tagged string. With two values the shift maps the real string to position 2
(shifted) or position 1 (fixed), and the wrapper checks both positions. The mock
was corrected to apply the shift to single-value returns too, so it now
reproduces the exact `nil|nil` failure and guards the fix; a focused check
confirms the mock drops a single value and preserves a two-value return. This
constraint must be re-proven in the DCS rerun, and it generalizes to the
production bridge: any mission→trigger `a_do_script` call must return a padding
value if it needs to return fewer than two.

### Full-queue rerun finding: verify the spool, not Lua return truthiness

The rerun with the padding fix proved the complete nested transport and queue
path: mixed values, stock sandbox, exact 1 KiB and 64 KiB NUL-free frames,
queue initialization, bounded peek, identical repeated peek, acknowledgement
rejection cases, remainder, and the empty final queue all passed in both
generations, with distinct run keys/fingerprints and companion coexistence.

Four spool/ack checks failed because DCS hook `file:write`, `file:flush`, or
`file:close` returned a falsey value with `error=nil`, even though inspection of
the closed spool file showed all three frames present and byte-complete. The
probe had incorrectly treated Lua return truthiness as durability evidence and,
more seriously, still invoked mission acknowledgement after its own spool check
failed. That was an acceptance-probe defect, not production behavior to retain.

The corrected probe now wraps write/flush/close in `pcall`, closes the file,
reopens it in binary read mode, reads the full contents, and requires an exact
byte comparison against the expected cumulative spool before setting
`spooled_through`. Any failed verification terminates the generation
immediately, and defensive guards make both acknowledgement calls impossible
unless the expected `spooled_through` value is present. A corruption-injection
mock verifies that a mismatched spool produces a failed result and that no
acknowledgement or later queue stage runs; happy-path mocks pass under both
shifted and fixed mappings.

The final two-generation run (log
`Saved Games\DCS\Logs\dcs.log.full-queue-spool-byte-verify.*`) passed with
`failures=0` on every `RESULT` and `STOP_RESULT`, confirming the spool byte
verification works on real DCS and that the transport stays callable during
`onSimulationStop`.

### Dedicated-server parity

The dedicated server was updated to the same `2.9.29.27278` release as the full
client and its install-level `MissionScripting.lua` was verified byte-identical
to `.orig`. The disposable probe and companion were installed under
`Saved Games\DCS.dcs_serverrelease\Scripts\Hooks`, and the client connected to
the local server as a real remote multiplayer client.

The dedicated run (log
`Saved Games\DCS.dcs_serverrelease\Logs\dcs.log.dedicated-telemetry-parity.*`)
proved:

- Two generations completed with `RESULT ... failures=0` and
  `STOP_RESULT ... failures=0`, including the 64 KiB frame and both durable
  spool/acknowledgement cycles.
- `multiplayer=true` and `server=true`; zero probe checks failed.
- The separately loaded companion received frames and clean stop callbacks in
  both generations.
- `onPlayerTryConnect` supplied a stable redacted UCID fingerprint; the later
  connect and F/A-18 slot-change snapshots had `matches_connect=true`.
- The nested transport remained callable during both simulation-stop callbacks.

The server automatically loaded the development `duel-dynamic.miz` before the
WebGUI switched to `test-flight.miz`. Under stock sanitization that development
loader emitted one expected, unrelated error when `bootstrap.lua` accessed nil
mission-side `io`. It was not emitted by the probe and does not weaken the
bridge result; it is also not evidence about the separate self-contained
shipping `.miz` issue. Generation 2 used the script-free `test-flight.miz`.

For dedicated lifecycle fidelity, the probe now retains connection UCID
fingerprints across mission reloads and clears them only on disconnect. The
mock models a remote client surviving a mission restart and requires its later
slot snapshot to remain correlated. The generic mode check is named
`multiplayer_server_mode` rather than the full-client-specific earlier label.

### DCS-gRPC

DCS-gRPC provides useful protobuf framing, lifecycle events, and UCID through
`NetService.GetPlayers` and connection events. It is not a transparent fit for
the current contract:

- Upstream installation adds a loader to install-level
  `Scripts/MissionScripting.lua` before sanitization and installs Lua and native
  modules.
- `MissionService.StreamEvents` carries predefined protobuf variants, not an
  arbitrary mission-normalized telemetry envelope.
- The stream has no documented event cursor, application acknowledgement, or
  replay operation.
- Each upstream IPC subscriber uses a bounded 1,024-message channel and drops
  an event for a full subscriber.
- `Eval` could poll mission state, but it is disabled by default because it
  executes arbitrary mission Lua and is not the supported event-stream path.
- The latest published release found is `0.8.1` from 2024-11-05. Current
  upstream `main` contains later unreleased compatibility work and must not be
  treated as release behavior.

### Structured logging

Structured `env.info` records can carry event IDs and parseable text, but the
channel is one-way and has no mission-visible acknowledgement. The installed API
also states that main-log messages may be lost at high output rates. Mission Lua
does not have a documented source for stable UCID. Logging therefore remains a
diagnostic or fallback sink, not the authoritative production ledger.

## Proposed Bridge Semantics

The production design should use these semantics if the runtime probe succeeds:

1. Mission Lua assigns immutable event IDs and retains sequence-ordered
   envelopes in a bounded in-memory queue.
2. The hook peeks a bounded contiguous range through `a_do_script`; peeking does
   not remove events.
3. A frame identifies its format, producer, run, first and last sequence, event
   count, and payload byte length. Event boundaries are length-delimited rather
   than newline-dependent.
4. The hook validates the frame, appends it to a hook-owned local spool, and
   closes or flushes the spool before accepting it.
5. A later `a_do_script` call acknowledges the highest contiguous sequence
   accepted by the spool. Mission Lua removes only acknowledged entries.
6. Retries preserve complete envelopes. The collector and API deduplicate by
   `event_id`.
7. Mission crash before hook acceptance can still lose in-memory events. No
   stock bridge can make mission-memory capture durable before crossing the
   environment boundary.

## Contract Constraints

- `producer_id` must be persisted outside mission Lua by the hook or collector
  and injected into each mission run.
- The hook should create a collision-resistant `run_key` and inject it before
  mission telemetry emits sequence 1. Simulation time alone remains invalid.
- Telemetry startup must wait for this bridge handshake in the stock shipping
  path. The development sink may use a separate development-only provider.
- UCID must come from the server hook. Identity mapping must correlate player ID,
  slot, and mission-visible labels without turning a display name into a stable
  identity.
- When correlation is not available in time, the existing explicit
  `stable-identity-unavailable` representation is valid; the mission must not
  invent a participant ID.
- The contract's HTTP maximum remains 1,048,576 bytes, but it is not yet an
  approved DCS bridge-frame limit. A smaller bridge limit may be required by the
  probe and collector batching.
- `wall_time` may remain `null` when mission Lua cannot obtain it. Bridge-side
  receipt time must not silently replace source capture time.

## Disposable Probe

### API discovery probe

`tests/dcs/telemetry-bridge-api-discovery.lua` is the next runtime probe. It is
deliberately smaller than the queue probe and records:

- The hook-global, `Sim`, `DCS`, and `net` locations for `a_do_script`.
- Stock-default availability of `net.dostring_in("mission", ...)`.
- Whether the nested mission state exposes `a_do_script`.
- Whether return pass-through is fixed, shifted by the known DCS bug, or an
  unsupported third behavior.
- Sentinel-based recovery of one value from either known mapping.
- Stock mission-sandbox state.
- Precise characterization of the round 1 NUL-truncation behavior: an
  NUL-bearing value must come back truncated to exactly the bytes before the
  first NUL, both small and inside a 64 KiB frame.
- One exact NUL-free 64 KiB framed string through the complete nested path,
  since production frames are NUL-free by construction (text header + JSON).

It does not test queue acknowledgement or authorize the production bridge. If
it passes, the full queue probe must be adapted to the proven nested transport
and rerun.

### Full queue probe (adapted to the nested transport)

`tests/dcs/telemetry-bridge-probe.lua` and the separately loaded controlled
`tests/dcs/telemetry-bridge-companion.lua` are non-production GameGUI hooks.
They do not modify mission source. Every mission evaluation goes through the
proven nested transport: `net.dostring_in("mission", wrapper)` where the
wrapper invokes `a_do_script(inner)` in the mission trigger state. Because the
return pass-through is shifted (and, for a single return value, drops it
entirely) and truncates strings at the first NUL byte, the inner chunk
serializes all of the source's return values into a single NUL-free tagged
string (tag `0`=nil, `1`=number, `2`=boolean, `3`=string, `4`=unsupported type)
and appends a dummy second value, so the real string lands at position 1 (fixed
mapping) or 2 (shifted) before the value crosses the state boundary. The wrapper
checks both positions.
The probe's own test queue is injected into the mission `_G` by the
`queue_initialize` stage, so a lightweight stock mission is sufficient.

They test:

- A complete `Sim` or `DCS` callback namespace, including lifecycle, time,
  mission-name, multiplayer, and server-mode methods.
- Mission lifecycle callback order.
- Same-callback coexistence across two separately loaded hook files through the
  companion's `onSimulationFrame` callback.
- Nested `a_do_script` availability and round-trip of multiple mixed return
  values (string, number, nil, boolean) through the single-tagged-string
  serializer, plus confirmation that `os`, `io`, `lfs`, `require`, `package`,
  and `loadlib` are nil in the mission state.
- Precise NUL-truncation characterization: an 8-byte NUL-bearing value must come
  back as exactly the bytes before the first NUL.
- Exact framed NUL-free returns at 1 KiB and the required 64 KiB conservative
  frame limit, including a NUL-absence assertion on the payload.
- Hook-owned run-key injection into a three-event mission queue, a bounded
  two-event peek, identical pre-acknowledgement re-peek, hook-side
  header/length/sequence parsing, hook-local write/flush/close followed by
  reopen-and-byte-compare before acknowledgement, rejection of wrong-run and
  beyond-peek acknowledgements, a second bounded peek/acknowledgement, and an
  empty final peek. Failed spool verification must terminate the generation
  before any acknowledgement call.
- Distinct generation markers and run keys across mission restart.
- Whether the nested transport remains callable during `onSimulationStop`.
- UCID and slot consistency across connection and player snapshots using only
  fingerprints. The probe does not log player names, addresses, DCS player IDs,
  raw UCIDs, or raw slot labels.

The full probe writes `TELEMETRY_BRIDGE_PROBE` records to `dcs.log`. The 64 KiB
return is the required conservative bridge-frame floor. Larger HTTP batches can
be split across acknowledged bridge frames instead of relying on undocumented
cross-state limits. The probe must be removed from the hook directory after
testing. The local mock emulates the three-state topology (hook → trigger →
mission) with both the `shifted` and `fixed` return mappings and the NUL-truncating
return boundary, and passes under both.

## Runtime Procedure: Nested API Discovery (complete)

This gate used the existing small `test-flight.miz` to isolate the API from the
duel mission and shipping build. Both rounds ran under stock sanitization with
no `autoexec.cfg` present, in **Multiplayer → New Server**, on DCS 2.9.29.27278.

Round 2 (revised probe) final evidence from the fresh `dcs.log`,
`mission=test-flight multiplayer=true server=true`:

- `CHECK full_client_host_mode PASS`
- `CHECK nested_a_do_script_available PASS`
- `CHECK return_mapping_known PASS` with `OBSERVE return_mapping=shifted`
- `CHECK stock_mission_sandbox PASS`
- `CHECK nul_truncation_characterized PASS` (1 of 8 bytes survived)
- `CHECK framed_binary_truncates_at_first_nul PASS` (32 of 65536 bytes, exact)
- `CHECK framed_65536_nul_free_round_trip PASS` (65536 bytes, exact)
- `RESULT failures=0`

Preserved logs:
`Saved Games\DCS\Logs\dcs.log.discovery-round-1.*` and the fresh
`dcs.log` (round 2), to be archived on cleanup.

### Procedure (executed, reproducible)

1. Close DCS completely.
2. Confirm
   `C:\Users\g_for\Saved Games\DCS\Config\autoexec.cfg` is absent. If it
   exists, stop and inspect it rather than testing with an unknown
   `net.allow_unsafe_api` or `net.allow_dostring_in` override. Then restore
   stock `MissionScripting.lua`. The existing
   `MissionScripting.lua.telemetry-dev-backup` may be reused only when its hash
   exactly matches the current development file; otherwise stop. If it does not
   exist, create and hash-verify it before copying `MissionScripting.lua.orig`
   over the active file. Hash-verify the stock copy too.
3. Install only
   `tests\dcs\telemetry-bridge-api-discovery.lua` as
   `Saved Games\DCS\Scripts\Hooks\00-telemetry-bridge-api-discovery.lua`.
   Refuse to overwrite an existing file and hash-verify the copy.
4. Move the old `Saved Games\DCS\Logs\dcs.log` to a unique, non-overwriting
   archive while DCS is closed.
5. Start DCS, choose **Multiplayer → New Server**, and load
   `C:\Users\g_for\Saved Games\DCS\Missions\test-flight.miz`.
6. Wait for `TELEMETRY_BRIDGE_DISCOVERY RESULT`. No slot entry, weapon firing,
   or mission restart is needed. Exit DCS.
7. Remove the discovery hook, preserve the fresh log, and restore the
   development `MissionScripting.lua`.
8. The discovery passes only if the log contains all of:

   - `CHECK full_client_host_mode PASS`
   - `CHECK nested_a_do_script_available PASS`
   - `CHECK return_mapping_known PASS`
   - `OBSERVE return_mapping=fixed` or `shifted`
   - `CHECK stock_mission_sandbox PASS`
   - `CHECK nul_truncation_characterized PASS`
   - `CHECK framed_binary_truncates_at_first_nul PASS`
   - `CHECK framed_65536_nul_free_round_trip PASS`
   - `RESULT failures=0`

If the nested API is unavailable under the stock default, stop. Do not silently
enable unsafe API access; reassess structured log transport, DCS-gRPC, or an
explicitly approved server configuration.

## Next Runtime Procedure: Full Queue Bridge

This is the gate now that the full queue probe is adapted to the nested
transport proven in discovery. It deliberately uses the full client as a local
multiplayer server; plain single-player is not sufficient for the host mode and
server-side identity checks. Because the probe injects its own test queue into
the mission `_G`, the lightweight stock `test-flight.miz` is used (no duel or
shipping build is required). The client is already stock-sanitized with a
hash-verified development backup from the discovery rounds, so the orchestrator
only re-verifies that state, installs the probe and companion, and archives the
fresh log while DCS is closed.

1. Close DCS completely.
2. In an elevated PowerShell, confirm the stock state and (re)verify the
   development backup. The existing `.telemetry-dev-backup` may be reused only
   when the active file is stock and differs from the backup; restore stock
   from `.orig` if the active file is not stock:

```powershell
    $ErrorActionPreference = 'Stop'
    $dcs = 'C:\Program Files (x86)\Steam\steamapps\common\DCSWorld'
    $missionScripting = "$dcs\Scripts\MissionScripting.lua"
    $stockBackup = "$missionScripting.orig"
    $devBackup = "$dcs\Scripts\MissionScripting.lua.telemetry-dev-backup"
    if (-not (Test-Path -LiteralPath $missionScripting) -or -not (Test-Path -LiteralPath $stockBackup)) {
      throw 'MissionScripting.lua or its stock backup is missing'
    }
    $active = (Get-FileHash -LiteralPath $missionScripting).Hash
    $stock = (Get-FileHash -LiteralPath $stockBackup).Hash
    if ($active -eq $stock) {
      if (-not (Test-Path -LiteralPath $devBackup)) {
        throw 'Development backup missing while the active file is stock; cannot proceed safely'
      }
      $dev = (Get-FileHash -LiteralPath $devBackup).Hash
      if ($dev -eq $stock) {
        throw 'Development backup unexpectedly matches the stock file; backup state is inconsistent'
      }
      'Active file is already stock; development backup intact.'
    } else {
      if (Test-Path -LiteralPath $devBackup) {
        throw 'Refusing to overwrite an existing development backup; resolve it first'
      }
      Copy-Item -LiteralPath $missionScripting -Destination $devBackup
      if ((Get-FileHash -LiteralPath $missionScripting).Hash -ne (Get-FileHash -LiteralPath $devBackup).Hash) {
        throw 'Development backup verification failed'
      }
      Copy-Item -LiteralPath $stockBackup -Destination $missionScripting -Force
      if ((Get-FileHash -LiteralPath $stockBackup).Hash -ne (Get-FileHash -LiteralPath $missionScripting).Hash) {
        throw 'Stock restoration verification failed'
      }
      'Restored and verified stock MissionScripting.lua.'
    }
    ```

3. From the repository root, install the disposable companion and probe into the
   full client's existing hooks directory. The early filenames ensure they run before the
   unrelated `bhHook.lua` callback that already errors during slot change/stop:

   ```powershell
   $ErrorActionPreference = 'Stop'
   $hooks = "$env:USERPROFILE\Saved Games\DCS\Scripts\Hooks"
   $companionSource = '.\tests\dcs\telemetry-bridge-companion.lua'
   $probeSource = '.\tests\dcs\telemetry-bridge-probe.lua'
   $companionDestination = "$hooks\00-telemetry-bridge-companion.lua"
   $probeDestination = "$hooks\01-telemetry-bridge-probe.lua"
   foreach ($destination in @($companionDestination, $probeDestination)) {
     if (Test-Path -LiteralPath $destination) {
       throw "Refusing to replace existing hook: $destination"
     }
   }
   Copy-Item -LiteralPath $companionSource -Destination $companionDestination
   Copy-Item -LiteralPath $probeSource -Destination $probeDestination
   if ((Get-FileHash $companionSource).Hash -ne (Get-FileHash $companionDestination).Hash -or
       (Get-FileHash $probeSource).Hash -ne (Get-FileHash $probeDestination).Hash) {
     throw 'Hook installation verification failed'
   }
   ```

4. While DCS is still closed, move any old main log aside so stale output cannot
   satisfy the gate:

   ```powershell
   $ErrorActionPreference = 'Stop'
   $dcsLog = "$env:USERPROFILE\Saved Games\DCS\Logs\dcs.log"
   if (Test-Path -LiteralPath $dcsLog) {
     $archive = "$dcsLog.before-telemetry-probe.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
     if (Test-Path -LiteralPath $archive) {
       throw "Refusing to replace existing log archive: $archive"
     }
     Move-Item -LiteralPath $dcsLog -Destination $archive
   }
   if (Test-Path -LiteralPath $dcsLog) {
     throw 'Fresh-log precondition failed'
   }
   ```

5. Start DCS and choose **Multiplayer → New Server**. Load
   `C:\Users\g_for\Saved Games\DCS\Missions\test-flight.miz`. The probe injects
   its own test queue into the mission `_G`, so this lightweight stock mission
   is sufficient; do not use the development loader or the shipping build.
6. Start/resume the mission and wait about 10 seconds. Confirm DCS created a new
   `dcs.log`; it must contain `RESULT generation=1 failures=0`.
7. Enter an `Aerial-*` slot, wait at least three seconds, return to spectators,
   then re-enter. This exercises polling even if local-player callbacks are not
   raised. The same non-`none` `ucid_fingerprint` should remain visible if DCS
   exposes a UCID for the local host.
8. Restart/reload the mission once and wait for
   `RESULT generation=2 failures=0`. The generation-2 checks must include
   `CHECK run_key_fresh PASS` with a different fingerprint from generation 1.
9. Stop the mission cleanly and exit DCS. The final lifecycle must contain
   `STOP_RESULT generation=2 failures=0`; generation 1 must also have its own
   result and stop result. Stop-time `transport_callable` is observational;
   production durability must not depend exclusively on this late callback.
10. Remove the disposable hook:

   ```powershell
   $ErrorActionPreference = 'Stop'
   $hooks = "$env:USERPROFILE\Saved Games\DCS\Scripts\Hooks"
   $companionDestination = "$hooks\00-telemetry-bridge-companion.lua"
   $probeDestination = "$hooks\01-telemetry-bridge-probe.lua"
   Remove-Item -LiteralPath $companionDestination
   Remove-Item -LiteralPath $probeDestination
   Get-ChildItem "$env:USERPROFILE\Saved Games\DCS\Logs" -Filter 'telemetry-bridge-probe-*.tmp' |
     Remove-Item -ErrorAction Stop
   if ((Test-Path -LiteralPath $companionDestination) -or (Test-Path -LiteralPath $probeDestination)) {
     throw 'Disposable hook cleanup failed'
   }
   ```

11. Extract the redacted evidence (the probe never writes names, addresses, or
    raw UCIDs):

    ```powershell
    Select-String -Path "$env:USERPROFILE\Saved Games\DCS\Logs\dcs.log" -Pattern 'TELEMETRY_BRIDGE_(PROBE|COMPANION)'
    ```

12. Require `TELEMETRY_BRIDGE_COMPANION FRAME PASS generation=1` and
    `generation=2` alongside the probe results. These records prove the
    separately loaded companion's `onSimulationFrame` callback continued through
    DCS's callback dispatcher. Also confirm at least one pre-existing hook still
    logged normal activity after the probe loaded (for example SRS,
    OpenKneeboard, or Tacview). Compare any `bhHook.lua` errors with the saved
    pre-probe log; those nil-`tcp` errors are an existing baseline defect, not
    probe evidence.
13. Either leave `MissionScripting.lua` stock for safety, or restore the saved
    development copy before returning to the trusted hot-reload loop:

   ```powershell
   $ErrorActionPreference = 'Stop'
   $dcs = 'C:\Program Files (x86)\Steam\steamapps\common\DCSWorld'
   $missionScripting = "$dcs\Scripts\MissionScripting.lua"
   $devBackup = "$missionScripting.telemetry-dev-backup"
   Copy-Item -LiteralPath $devBackup -Destination $missionScripting -Force
   if ((Get-FileHash $devBackup).Hash -ne (Get-FileHash $missionScripting).Hash) {
     throw 'Development restoration verification failed'
   }
    ```

A remote client is not required to prove the string/framing bridge. If the local
host's UCID is absent, remote stable-identity correlation remains explicitly
unproven and must be checked before Slice 9 rather than replaced with a name.

## Full Queue Exit Gate

The local-host portion of Slice 3 passes only when full-client multiplayer-host
evidence shows:

- Stock mission sandbox confirmation.
- Exactly two successful generation results for nested mixed-value round trip,
  NUL-truncation characterization, exact NUL-free framing, distinct hook-owned
  run-key injection, bounded repeated peek, durable hook-local spool writes
  before bounded acknowledgement, and the required 64 KiB frame size.
- Lifecycle behavior across start, restart, and clean stop, ending with
  `STOP_RESULT generation=2 failures=0`.
- Local host UCID availability is recorded by fingerprint, or its absence is
  retained as an explicit narrower identity constraint. A stable fingerprint
  across the slot transition proves snapshot-to-slot association; because DCS
  does not raise local-player connection callbacks, `matches_connect=false` for
  the host is recorded as that documented limitation rather than misreported as
  connection-event correlation.
- The separately loaded companion receives frames in both generations.
- A conservative 64 KiB production bridge-frame limit, with larger contract
  batches split across frames.
- No new `SCRIPTING ERROR` or `SCRIPTING WARNING` attributable to the probe.

**Satisfied (local host):** the final full-queue run
(`Saved Games\DCS\Logs\dcs.log.full-queue-spool-byte-verify.*`) met every
criterion above — `failures=0` on both `RESULT` and both `STOP_RESULT`, a
distinct run key/fingerprint per generation, companion frames in both
generations, `frame_65536 PASS`, `matches_connect=false` recorded as the
documented limitation, and zero probe-attributable `SCRIPTING` errors/warnings.

**Satisfied (dedicated server):** the dedicated parity run met the same
transport, framing, spool, acknowledgement, generation, lifecycle, and
companion criteria. It additionally correlated a real remote client's
connection UCID fingerprint with its F/A-18 slot transition. Both final
`STOP_RESULT` lines reported `failures=0`; no probe check failed.

Slice 3 is complete and Slice 4 may begin. Do not implement the production hook
in Slice 4; production bridge implementation and stock-sanitized shipping
integration remain explicitly deferred to Slice 17.

## Sources

- Installed `DCSWorld/API/Sim_ControlAPI.md`
- Installed bundled `DCSWorld/Scripts/Hooks/common.lua`
- DCS 2.9.15.9408 changelog, including the explicit
  `net.dostring_in("mission", "a_do_script(...)")` route:
  <https://www.digitalcombatsimulator.com/en/news/changelog/release/2.9.15.9408/>
- DCS 2.9.18.12722 changelog, return pass-through change:
  <https://www.digitalcombatsimulator.com/en/news/changelog/release/2.9.18.12722/>
- DCS 2.9.18.12899 changelog, `dostring_in` behavior rollback:
  <https://www.digitalcombatsimulator.com/en/news/changelog/release/2.9.18.12899/>
- ED-reported shifted/drop-last return bug:
  <https://forum.dcs.world/topic/376809-a_do_script-return-value-pass-thru-mangled-since-dcs-291812722/>
- <https://github.com/DCS-gRPC/rust-server>
- <https://github.com/DCS-gRPC/rust-server/releases/tag/0.8.1>
- <https://github.com/DCS-gRPC/rust-server/blob/main/protos/dcs/mission/v0/mission.proto>
- <https://github.com/DCS-gRPC/rust-server/blob/main/protos/dcs/net/v0/net.proto>
- <https://github.com/DCS-gRPC/rust-server/blob/main/src/rpc/mission.rs>
- <https://github.com/rkusa/dcs-module-ipc/blob/main/src/ipc.rs>
