# Slice 17 part 5 — ambiguous hook ACK reconciliation evidence

Date: 2026-09-08. Authority: the owner-approved near-live plan,
`docs/telemetry/slice-18-5-near-live-plan.md`, section 4, lines 200–214.
Scope is limited to the production hook transport, mission bridge ACK contract,
and offline Lua mocks. No DEV file-sink, frame codec, collector, contract,
gameplay, network, database, DCS, or deployment work was performed.

## Verified pre-state

- `hooks/duel-dynamic-telemetry.lua:421` held only the hook-owned ACK cursor.
  `spool_lines` at then-lines 622–639 byte-verified each append, but did not
  retain a sequence frontier. The ACK path at then-lines 706–720 left the
  cursor unchanged for every non-`OK` response. A later stale peek entered the
  generic failure path at then-lines 677–684.
- `src/missions/duel-dynamic/telemetry/bridge.lua:159-171` already exposed the
  flat `last_acked_sequence`, `first_pending_sequence`, and `pending_count`
  status scalars. Its ACK method at then-lines 204–212 delegated directly to
  the queue, so a retry of an applied ACK was rejected as stale.
- `src/missions/duel-dynamic/telemetry/bridge_queue.lua:48-92` implemented the
  pinned lifetime-contiguous queue and stale/beyond checks. It remains
  unchanged.
- Baseline checks passed: bridge 40 tests, production mock 52 checks (26 per
  transport mapping), and repository StyLua check. Contrary to the supplied
  clean-status precondition, baseline `git status --porcelain` also showed
  ` M .gitignore` in addition to the expected untracked live-evidence doc.
  Neither pre-existing path was touched.

## Design

### Verified-spool and mission reconciliation

The hook now maintains `state.spool_verified_sequence`. It starts at zero for
each generation and advances only after `write_and_verify` has confirmed the
append byte-for-byte (`hooks/duel-dynamic-telemetry.lua:422,565,626-643`).

For an ambiguous ACK result, or the exact stale-peek response, the hook reads
only three flat scalars through the existing mission transport:
`last_acked_sequence`, `first_pending_sequence`, and `pending_count`. It
rejects malformed return counts, non-integer frontiers, and inconsistent
pending/frontier combinations. The hook cursor is then assigned:

```text
min(mission last_acked_sequence, hook spool_verified_sequence)
```

This is implemented at
`hooks/duel-dynamic-telemetry.lua:646-690`, invoked from stale-peek recovery at
lines 728–748 and ambiguous-ACK recovery at lines 781–801. Therefore mission
confirmation alone cannot move the cursor past bytes verified in this
generation's spool. If the mission is behind the spool (a genuine unapplied
ACK), the cursor remains at the mission frontier before any retry/reappend.
If the mission is ahead, the cursor remains at the verified frontier; missing
bytes are never treated as durable.

Reconciliation also derives the known unspooled count as
`mission_acked + pending_count - spool_verified` (bounded at zero). The
existing STOP fields and order are unchanged; the known count is used at
`hooks/duel-dynamic-telemetry.lua:860-867`. A later successful drain reduces a
previously known count by its verified frame count. This makes the
ambiguous-ACK stop fixture report the remaining mission event rather than a
false zero.

### Idempotent ACK boundary

The queue retains its strict stale-ACK contract. The bridge transport boundary
now returns `true, "already-applied"` only when a positive requested sequence
is at or behind the queue's acknowledged frontier
(`src/missions/duel-dynamic/telemetry/bridge.lua:204-218`). Invalid and
beyond-appended ACKs still delegate to the queue and fail. The hook's existing
mission snippet maps either normal `true` or this covered retry to `OK`.

Safety by outcome:

- **Response lost:** bytes were verified before the ACK call. A readable
  status advances only to the minimum frontier. If status is also unavailable
  or malformed, the cursor does not advance; a subsequent stale peek triggers
  the same reconciliation before anything is reappended.
- **Response mangled/short:** it is not accepted as success. Status
  reconciliation applies the same minimum bound.
- **Response late/already applied:** a synchronous response that is still a
  valid `OK` follows the normal path. A later retry is accepted only when the
  mission queue already covers that exact or newer sequence; it cannot move
  the mission frontier.
- **ACK genuinely not applied:** mission status remains behind the verified
  spool. The cursor equals that lower frontier, normal backoff occurs, and the
  next peek/reappend/ACK retry proceeds. The existing byte-identical duplicate
  spool behavior remains safe for collector event-ID deduplication.

Frame-cap halving, sentinel decoding, identity validation, verify-before-ACK,
transport-unavailable marking, backoff, handshake behavior, and event-ID
construction were not changed.

## Pinned-semantics and test inventory

- Idempotent bridge ACK contract:
  `tests/lua/telemetry/run-bridge.lua:219-230`.
- Genuine unapplied ACK, mission-behind-spool minimum, status read, reappend,
  and retry regression:
  `tests/dcs/run-telemetry-bridge-prod-mock.lua:625-661`.
- Executed ACK + lost response + lost first status response, subsequent stale
  peek reconciliation, no duplicate application, later event flow, and stable
  event identity: lines 664–697.
- Mangled ACK response, verified-spool bound, and stable identity: lines
  699–712.
- Direct minimum-frontier cases in both orderings: lines 714–719.
- Executed ACK + lost response during bounded stop, termination, stable
  identity, and honest `unspooled=1`: lines 770–786.
- All production fixtures execute under both supported fixed and shifted
  `a_do_script` return mappings.

Counts changed from 40 to 41 bridge tests and from 52 to 60 production-mock
checks (26 to 30 per mapping). No separate runner was added.

## Changed files

- `hooks/duel-dynamic-telemetry.lua`
- `src/missions/duel-dynamic/telemetry/bridge.lua`
- `tests/lua/telemetry/run-bridge.lua`
- `tests/dcs/run-telemetry-bridge-prod-mock.lua`
- `docs/telemetry/slice-17-part5-ack-reconciliation-evidence.md`

`bridge_queue.lua` and `bridge_frame.lua` required no change.

## Acceptance battery

Run from `C:\Projects\dcs-missions`:

| Command | Exit | Result |
|---|---:|---|
| `lua5.1 tests\lua\telemetry\run-bridge.lua` | 0 | 41 passed |
| `lua5.1 tests\dcs\run-telemetry-bridge-prod-mock.lua` | 0 | 60 passed (30 shifted + 30 fixed) |
| New runner | N/A | No runner added |
| `stylua --check .` | 0 | Clean |
| `luacheck <changed Lua paths>` | 1 | Skipped: `luacheck` is not resolvable on PATH; `luarocks show luacheck` confirmed no local rock; repository config was present |
| `npm --prefix web run test` | 0 | 22 files, 200 tests passed |
| `npm --prefix collector run check` | 0 | format, lint, typecheck, 9 files/109 tests passed |
| `git diff --check` | 0 | Clean; Git emitted only existing CRLF conversion warnings |

Final `git status --porcelain` contained 7 lines: 5 modified and 2 untracked.
The task-owned entries are four modified Lua files plus this untracked evidence
doc. The other two entries (`M .gitignore` and
`?? docs/telemetry/dev-ai-live-test-evidence.md`) pre-existed this work and were
not touched.

## Residuals / S17-p6 handoff

- Whole-lifetime `spool_content` retention and whole-file append
  re-verification remain intentionally unchanged; S17-p6 owns bounded spool
  verification and callback work.
- STOP still performs the existing single forced drain. This slice makes the
  status-reconciled ambiguous-ACK case honest; broader stop-tail truth and
  bounded draining remain S17-p6 scope.
- If mission status proves ACKed bytes beyond the hook's verified frontier,
  the minimum rule intentionally refuses to cross them. Recovery cannot
  reconstruct discarded, unverified bytes; safety takes precedence and the
  derived unspooled count remains nonzero.
- Live validation is reserved for the S17-p7 gate. This slice used offline
  mocks only.
