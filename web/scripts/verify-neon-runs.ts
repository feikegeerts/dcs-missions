import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { neon } from "@neondatabase/serverless";
import { drizzle } from "drizzle-orm/neon-http";
import { eq, and } from "drizzle-orm";
import * as schema from "../src/db/schema";

function pickEnv(line: string, key: string): string | null {
  const eqi = line.indexOf("=");
  if (eqi <= 0) return null;
  const k = line.slice(0, eqi).trim();
  if (k !== key) return null;
  let v = line.slice(eqi + 1).trim();
  if (
    (v.startsWith('"') && v.endsWith('"')) ||
    (v.startsWith("'") && v.endsWith("'"))
  ) {
    v = v.slice(1, -1);
  }
  return v;
}

const envPath = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  ".env.local",
);
const text = await readFile(envPath, "utf8");
let conn = null;
for (const line of text.split(/\r?\n/)) {
  if (line.trim() === "" || line.trim().startsWith("#")) continue;
  for (const key of ["POSTGRES_URL", "DATABASE_URL"]) {
    const v = pickEnv(line, key);
    if (v) conn = v;
  }
}
if (!conn) {
  console.error("no POSTGRES_URL/DATABASE_URL found in web/.env.local");
  process.exit(1);
}
process.env.POSTGRES_URL = conn;

const db = drizzle(neon(conn), { schema });
const { missionRuns, telemetryEvents } = schema;

const runKeys = [
  "run-20260903T033512Z-21af9d3f",
  "run-20260903T040817Z-745fc0db",
];

console.log("=== mission_runs ===");
for (const rk of runKeys) {
  const rows = await db
    .select()
    .from(missionRuns)
    .where(eq(missionRuns.runKey, rk));
  if (rows.length !== 1) {
    console.log(`  ${rk}: EXPECTED 1 ROW, GOT ${rows.length}`);
    continue;
  }
  const r = rows[0];
  console.log(
    `  ${rk}: status=${r.status} event_count=${r.eventCount} ` +
      `seq ${r.firstSequence}-${r.lastSequence} mission=${r.missionName}@${r.missionVersion} ` +
      `map=${r.mapName} class=${r.runClassification}`,
  );
  console.log(`      started=${r.startedAt} ended=${r.endedAt}`);
}

console.log("\n=== telemetry_events: ordnance.fired per run ===");
for (const rk of runKeys) {
  const fired = await db
    .select()
    .from(telemetryEvents)
    .where(
      and(
        eq(telemetryEvents.runKey, rk),
        eq(telemetryEvents.eventType, "ordnance.fired"),
      ),
    );
  console.log(`  ${rk}: ${fired.length} ordnance.fired event(s)`);
  for (const e of fired) {
    console.log(
      `      seq=${e.eventSequence} weapon_dcs_type=${e.weaponDcsType} ` +
        `weapon_category=${e.weaponCategory} weapon_status=${e.weaponStatus} ` +
        `initiator=${e.initiatorDcsName}(${e.coalition}) sim_time=${e.simTime}`,
    );
  }
}

console.log("\n=== telemetry_events: totals per run (all types) ===");
for (const rk of runKeys) {
  const all = await db
    .select({ n: telemetryEvents.eventId })
    .from(telemetryEvents)
    .where(eq(telemetryEvents.runKey, rk));
  console.log(`  ${rk}: ${all.length} total events stored`);
}

// Cross-check: weapon identity should be AIM_120C for the first run, AIM_9X for the second.
console.log("\n=== expected-identity check ===");
const expected: Record<string, string> = {
  "run-20260903T033512Z-21af9d3f": "AIM_120C",
  "run-20260903T040817Z-745fc0db": "AIM_9X",
};
let pass = true;
for (const rk of runKeys) {
  const fired = await db
    .select()
    .from(telemetryEvents)
    .where(
      and(
        eq(telemetryEvents.runKey, rk),
        eq(telemetryEvents.eventType, "ordnance.fired"),
      ),
    );
  const got =
    fired.length === 1 ? fired[0].weaponDcsType : `COUNT=${fired.length}`;
  const ok = fired.length === 1 && fired[0].weaponDcsType === expected[rk];
  pass = pass && ok;
  console.log(
    `  ${rk}: expected 1x ${expected[rk]}, got 1x ${got} -> ${ok ? "PASS" : "FAIL"}`,
  );
}

process.exit(pass ? 0 : 2);
