# Slice 14 part 2 evidence

## Scope

Implemented run-scoped persisted `kill.attributed` and `assist.attributed`
facts derived from retained `asset.kill-reported` and `asset.hit` source
events. The projection is catalogue-independent, shares one retained-run event
read with the existing catalogue-gated loss projection, and is exposed by the
public dynamic `GET /api/telemetry/runs/[runId]/kills` route. No migration was
applied and no database was accessed.

## Files

- `web/src/telemetry/combat-facts.ts`: pure kill and assist reconciliation.
- `web/src/db/schema.ts`: additive kill and assist attribution tables.
- `web/src/telemetry/store.ts`: guarded upserts and run-scoped list methods.
- `web/src/telemetry/ingest.ts`: shared retained-event read and combat projection.
- `web/src/app/api/telemetry/runs/[runId]/kills/route.ts`: public read route.
- `web/tests/combat-facts.test.ts`: explicit assist rule and kill semantics tests.
- `web/tests/kills-route.test.ts`: success, not-found, and internal-error route tests.
- `web/tests/ingest.test.ts`: in-memory store wiring and unassigned-run coverage.
- `web/drizzle/0004_robust_dexter_bennett.sql`: generated additive migration.
- `web/drizzle/meta/0004_snapshot.json` and `web/drizzle/meta/_journal.json`:
  generated Drizzle metadata.

## Final data model

### `kill_attributions`

`fact_id` text not null unique; `producer_id` text not null;
`run_key` text not null; `target_asset_key` text not null;
`target_dcs_name` text nullable; `target_dcs_type` text nullable;
`target_coalition` text nullable; `killer_asset_key` text nullable;
`killer_dcs_name` text nullable; `killer_dcs_type` text nullable;
`killer_coalition` text nullable; `killing_blow_sim_time` double precision not
null; `killing_blow_event_id` text not null; `weapon_dcs_type` text nullable;
`weapon_category` text nullable; `source_event_ids` jsonb not null and checked
non-empty; `created_at` timestamptz not null default now; `updated_at`
timestamptz not null default now. Primary key:
`(producer_id, run_key, target_asset_key)`. The run foreign key cascades on
delete. Run and run/killer indexes are present.

### `assist_attributions`

`fact_id` text not null unique; `producer_id` text not null;
`run_key` text not null; `target_asset_key` text not null;
`attacker_asset_key` text not null; `attacker_dcs_name` text nullable;
`attacker_dcs_type` text nullable; `attacker_coalition` text nullable;
`target_dcs_name` text nullable; `target_dcs_type` text nullable;
`target_coalition` text nullable; `representative_hit_sim_time` double
precision not null; `representative_hit_event_id` text not null;
`source_event_ids` jsonb not null and checked non-empty; `created_at`
timestamptz not null default now; `updated_at` timestamptz not null default now.
Primary key:
`(producer_id, run_key, target_asset_key, attacker_asset_key)`. The run foreign
key cascades on delete. Run and run/attacker indexes are present.

The optional killing-blow weapon columns (`weapon_dcs_type`,
`weapon_category`) are the only columns added beyond the decided core.

## Explicit assist-rule results

All cases passed in `web/tests/combat-facts.test.ts`:

1. Within-window tracked hit: one assist.
2. Hit exactly at `T_kill`: included.
3. Hit exactly at `T_kill - 30`: included.
4. Hit at `T_kill - 30.001`: excluded.
5. Hit at `T_kill + 0.001`: excluded.
6. Known primary killer's hit: excluded.
7. Unknown killer plus tracked hit: one assist; kill killer fields remain null.
8. Two tracked attackers: two assists.
9. Repeated hits by one attacker: one row; earliest sequence is representative.
10. Null attacker asset key: excluded.
11. Hit on another target: excluded.
12. Hits without a kill report: no kills and no assists.
13. Reordered input: identical complete rows, fact IDs, and counts.
14. Kill report with null target asset key: skipped.

An additional test confirms that the first kill report supplies the killing
blow and that `asset.dead` cannot produce or alter a kill attribution.

## Acceptance outputs

- `npm test --prefix web`: exit 0; 13 files and 106 tests passed.
- `npm run typecheck --prefix web`: exit 0.
- `npm run lint --prefix web`: exit 0.
- `npm run format --prefix web`: exit 0; followed by
  `npm run format:check --prefix web`: exit 0, all files matched.
- `npm run build --prefix web`: exit 0; route table contains dynamic
  `/api/telemetry/runs/[runId]/kills`.
- First `npm run db:generate --prefix web`: exit 0; generated
  `drizzle/0004_robust_dexter_bennett.sql`. Second run: exit 0;
  `No schema changes, nothing to migrate`.
- Lua: `run.lua` 20, `run-lifecycle.lua` 8, `run-shot.lua` 10,
  `run-json-sink.lua` 11, `run-participant.lua` 9, `run-asset.lua` 23,
  `run-combat.lua` 11, and `tests/lua/run-duel-shared-bandits.lua` 12 passed:
  104 total. The requested path under `tests/lua/telemetry` does not exist;
  the tracked runner is one directory higher and passed there.
