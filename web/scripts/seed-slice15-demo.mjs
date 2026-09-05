#!/usr/bin/env node
/**
 * seed-slice15-demo.mjs — generates demo NDJSON runs for Slice 15 view testing
 * without flying a mission.
 *
 * Writes three files to out/slice15-demo/:
 * - demo-blue-ahead.ndjson: ended run, blue 2x AIM_120C + red 1x AIM_9X
 *   (blue spending more while ahead; tests ended filter + by-type + subtotal)
 * - demo-unpriced.ndjson: active run, 1x AIM_120C + 1x FUTURE_MISSILE_X +
 *   1x unknown weapon (tests active filter + partial totals)
 * - demo-pagination.ndjson: active run, 1x mission.started + 60x AIM_120C
 *   (tests event pagination: 50 per page over 61 events)
 *
 * Ingest with:
 *   node scripts/dev-ingest-run.mjs out/slice15-demo/*.ndjson
 *
 * Re-running ingest is safe (idempotent duplicates).
 * No DB connection here — this script only writes NDJSON.
 */

import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PRODUCER = "dcs-server-alpha";
const SOURCE_VERSION = "duel-dynamic-telemetry-v1";
const WALL = "2026-09-06T12:00:00Z";

function started({ runKey, sequence }) {
  return {
    schema_version: 1,
    event_id: `${PRODUCER}:${runKey}:${sequence}`,
    source: "moose-mission",
    producer_id: PRODUCER,
    source_version: SOURCE_VERSION,
    run_key: runKey,
    event_sequence: sequence,
    event_type: "mission.started",
    sim_time: 0,
    wall_time: WALL,
    initiator: null,
    target: null,
    participant: null,
    asset: null,
    weapon: null,
    coalition: null,
    location: null,
    payload: {
      mission_name: "duel-dynamic",
      mission_version: "1",
      map_name: "Caucasus",
      run_classification: "test",
    },
  };
}

function shot({ runKey, sequence, weaponDcsType, weaponStatus, participant }) {
  const p = participant ?? {
    participant_id: "ucid-blue-demo",
    display_name: "DemoViper",
    callsign: "Aerial 1-1",
    asset_key: "aerial-1.u1.g1",
    dcs_type: "FA-18C_hornet",
    coalition: "blue",
  };
  const weapon =
    weaponDcsType === null
      ? {
          status: "unknown",
          reason: "type-not-reported",
          dcs_type: null,
          display_name: null,
          category: "unknown",
        }
      : {
          status: weaponStatus ?? "known",
          dcs_type: weaponDcsType,
          display_name: weaponDcsType,
          category: "missile",
        };
  return {
    schema_version: 1,
    event_id: `${PRODUCER}:${runKey}:${sequence}`,
    source: "moose-mission",
    producer_id: PRODUCER,
    source_version: SOURCE_VERSION,
    run_key: runKey,
    event_sequence: sequence,
    event_type: "ordnance.fired",
    sim_time: sequence * 10,
    wall_time: WALL,
    initiator: {
      status: "known",
      kind: "aircraft",
      participant_id: p.participant_id,
      asset_key: p.asset_key,
      display_name: p.display_name,
      callsign: p.callsign,
      dcs_name: "Aerial-1-1",
      dcs_type: p.dcs_type,
      coalition: p.coalition,
    },
    target: null,
    participant: {
      status: "known",
      kind: "participant",
      participant_id: p.participant_id,
      display_name: p.display_name,
      callsign: p.callsign,
      coalition: p.coalition,
    },
    asset: {
      status: "known",
      kind: "aircraft",
      asset_key: p.asset_key,
      dcs_name: "Aerial-1-1",
      dcs_type: p.dcs_type,
      coalition: p.coalition,
    },
    weapon,
    coalition: p.coalition,
    location: {
      status: "known",
      coordinate_system: "dcs-local",
      x: 125000.25 + sequence * 10,
      y: 7620.5,
      z: -44000.75 - sequence * 10,
    },
    payload: { dcs_event_name: "shot" },
  };
}

function ended({ runKey, sequence }) {
  return {
    schema_version: 1,
    event_id: `${PRODUCER}:${runKey}:${sequence}`,
    source: "moose-mission",
    producer_id: PRODUCER,
    source_version: SOURCE_VERSION,
    run_key: runKey,
    event_sequence: sequence,
    event_type: "mission.ended",
    sim_time: sequence * 10,
    wall_time: WALL,
    initiator: null,
    target: null,
    participant: null,
    asset: null,
    weapon: null,
    coalition: null,
    location: null,
    payload: { reason: "mission-end-observed" },
  };
}

const RED = {
  participant_id: "ucid-red-demo",
  display_name: "DemoBandit",
  callsign: "Bandit 1-1",
  asset_key: "bandit-1.u1.g1",
  dcs_type: "Su-33",
  coalition: "red",
};

const runs = {
  "demo-blue-ahead.ndjson": [
    started({ runKey: "demo-blue-ahead", sequence: 1 }),
    shot({ runKey: "demo-blue-ahead", sequence: 2, weaponDcsType: "AIM_120C" }),
    shot({ runKey: "demo-blue-ahead", sequence: 3, weaponDcsType: "AIM_120C" }),
    shot({
      runKey: "demo-blue-ahead",
      sequence: 4,
      weaponDcsType: "AIM_9X",
      participant: RED,
    }),
    ended({ runKey: "demo-blue-ahead", sequence: 5 }),
  ],
  "demo-unpriced.ndjson": [
    started({ runKey: "demo-unpriced", sequence: 1 }),
    shot({ runKey: "demo-unpriced", sequence: 2, weaponDcsType: "AIM_120C" }),
    shot({
      runKey: "demo-unpriced",
      sequence: 3,
      weaponDcsType: "FUTURE_MISSILE_X",
    }),
    shot({ runKey: "demo-unpriced", sequence: 4, weaponDcsType: null }),
  ],
  "demo-pagination.ndjson": [
    started({ runKey: "demo-pagination", sequence: 1 }),
    ...Array.from({ length: 60 }, (_, i) =>
      shot({
        runKey: "demo-pagination",
        sequence: i + 2,
        weaponDcsType: "AIM_120C",
      }),
    ),
  ],
};

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.resolve(scriptDir, "..", "..", "out", "slice15-demo");
await mkdir(outDir, { recursive: true });
for (const [file, events] of Object.entries(runs)) {
  const body = events.map((event) => JSON.stringify(event)).join("\n") + "\n";
  await writeFile(path.join(outDir, file), body, "utf8");
  console.log(`wrote ${file} (${events.length} events)`);
}
console.log(`done: ${outDir}`);
console.log(
  "ingest with: node scripts/dev-ingest-run.mjs out/slice15-demo/*.ndjson",
);
console.log(
  "empty/no-result view: open /?mission=nomatchXXXX to see the empty state",
);
