/**
 * One-time operator step: re-pin the 2026-09-13 unattended AI-vs-AI test
 * runs to ordnance catalogue v2 and replay each run so the store's gap-fill
 * projection records the v2 prices, catalogue pins, and curated weapon
 * display names for the rows that were priced unknown under v1.
 *
 * Usage: npm run db:reprice-runs-to-v2
 *
 * Run once after `npm run db:seed:catalogue-v2`.
 *
 * Safety:
 * - refuses to touch a run that does not exist or is not classified "test";
 * - refuses to touch a run pinned to anything other than ordnance v1 (or
 *   unassigned);
 * - prices already recorded under the v1 pin are never rewritten (the
 *   expenditure conflict guard only fills rows whose price is null);
 * - version 1 catalogue rows are untouched.
 */
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { and, eq, sql } from "drizzle-orm";

import { getDb } from "../src/db/client";
import { missionRuns } from "../src/db/schema";
import { ordnanceCatalogueV2 } from "../src/telemetry/catalogue";
import { replayRun } from "../src/telemetry/replay";
import { NeonTelemetryStore } from "../src/telemetry/store";

const TARGET_RUN_KEYS = [
  "run-20260913T085237Z-71b1d0b4",
  "run-20260913T101940Z-5803a5a9",
] as const;

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
  await ensureDatabaseEnvironment();
  const store = new NeonTelemetryStore();
  const db = getDb();

  for (const runKey of TARGET_RUN_KEYS) {
    const before = await store.getRunByRunKey(runKey);
    if (before === null) {
      throw new Error(`Unknown telemetry run key: ${runKey}`);
    }
    if (before.runClassification !== "test") {
      throw new Error(
        `Refusing to reprice ${runKey}: run classification is ${before.runClassification ?? "unset"}, not "test"`,
      );
    }
    const pinnedV1 =
      before.valuationCatalogue === ordnanceCatalogueV2.catalogue &&
      before.valuationCatalogueVersion === 1;
    const unassigned =
      before.valuationCatalogue === null &&
      before.valuationCatalogueVersion === null;
    if (!pinnedV1 && !unassigned) {
      throw new Error(
        `Refusing to reprice ${runKey}: pinned to ${before.valuationCatalogue} v${before.valuationCatalogueVersion}, expected ${ordnanceCatalogueV2.catalogue} v1 or unassigned`,
      );
    }

    await db
      .update(missionRuns)
      .set({
        valuationCatalogue: ordnanceCatalogueV2.catalogue,
        valuationCatalogueVersion: ordnanceCatalogueV2.version,
        updatedAt: sql`now()`,
      })
      .where(
        and(
          eq(missionRuns.producerId, before.producerId),
          eq(missionRuns.runKey, before.runKey),
        ),
      );

    const after = await store.getRunByRunKey(runKey);
    if (after?.valuationCatalogueVersion !== ordnanceCatalogueV2.version) {
      throw new Error(`Repin did not take effect for ${runKey}`);
    }

    const summary = await replayRun(store, runKey);
    console.log(
      [
        `Repriced ${runKey}:`,
        `events=${summary.eventCount}`,
        `expenditures=${summary.expenditures}`,
        `losses=${summary.losses}`,
        `kills=${summary.kills}`,
        `catalogue=${summary.catalogue?.catalogue} v${summary.catalogue?.version}`,
      ].join(" "),
    );
  }
}

try {
  await main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
