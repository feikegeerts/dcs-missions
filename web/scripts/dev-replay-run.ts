/**
 * Rebuild derived telemetry facts for one retained run.
 *
 * Usage: tsx scripts/dev-replay-run.ts <runKey>
 */

import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { replayRun, ReplayRunNotFoundError } from "../src/telemetry/replay";
import { NeonTelemetryStore } from "../src/telemetry/store";

function pickEnv(line: string, key: string): string | null {
  const equalsIndex = line.indexOf("=");
  if (equalsIndex <= 0 || line.slice(0, equalsIndex).trim() !== key) {
    return null;
  }

  let value = line.slice(equalsIndex + 1).trim();
  if (
    (value.startsWith('"') && value.endsWith('"')) ||
    (value.startsWith("'") && value.endsWith("'"))
  ) {
    value = value.slice(1, -1);
  }
  return value || null;
}

async function ensureDatabaseEnvironment(): Promise<void> {
  if (process.env.POSTGRES_URL || process.env.DATABASE_URL) {
    return;
  }

  const envPath = path.join(
    path.dirname(fileURLToPath(import.meta.url)),
    "..",
    ".env.local",
  );
  let text: string;
  try {
    text = await readFile(envPath, "utf8");
  } catch {
    throw new Error(
      "Database connection is not configured: set POSTGRES_URL or DATABASE_URL, or add one to web/.env.local",
    );
  }

  let postgresUrl: string | null = null;
  let databaseUrl: string | null = null;
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) {
      continue;
    }
    postgresUrl = postgresUrl ?? pickEnv(line, "POSTGRES_URL");
    databaseUrl = databaseUrl ?? pickEnv(line, "DATABASE_URL");
  }

  if (postgresUrl) {
    process.env.POSTGRES_URL = postgresUrl;
  } else if (databaseUrl) {
    process.env.DATABASE_URL = databaseUrl;
  } else {
    throw new Error(
      "Database connection is not configured: set POSTGRES_URL or DATABASE_URL, or add one to web/.env.local",
    );
  }
}

async function main(): Promise<void> {
  const [runKey, ...extraArguments] = process.argv.slice(2);
  if (!runKey || extraArguments.length > 0) {
    throw new Error("Usage: tsx scripts/dev-replay-run.ts <runKey>");
  }

  await ensureDatabaseEnvironment();
  const store = new NeonTelemetryStore();
  const run = await store.getRunByRunKey(runKey);
  if (run === null) {
    throw new ReplayRunNotFoundError(runKey);
  }

  const summary = await replayRun(store, runKey);
  const span = summary.sequenceSpan
    ? `${summary.sequenceSpan.first}-${summary.sequenceSpan.last}`
    : "empty";
  const catalogue = summary.catalogue
    ? `${summary.catalogue.catalogue} v${summary.catalogue.version}`
    : "unassigned";

  console.log(`Run: ${summary.runKey}`);
  console.log(`Status/catalogue: ${run.status} / ${catalogue}`);
  console.log(`Events: ${summary.eventCount} (sequence span: ${span})`);
  console.log(`Expenditures: ${summary.expenditures}`);
  console.log(`Losses: ${summary.losses}`);
  console.log(`Kills: ${summary.kills}`);
  console.log(`Assists: ${summary.assists}`);
  console.log(`Participants: ${summary.participants}`);
}

try {
  await main();
} catch (error) {
  if (error instanceof ReplayRunNotFoundError) {
    console.error(`Unknown telemetry run key: ${error.runKey}`);
  } else {
    console.error(error instanceof Error ? error.message : String(error));
  }
  process.exitCode = 1;
}
