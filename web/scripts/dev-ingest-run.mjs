#!/usr/bin/env node
/**
 * dev-ingest-run.mjs — dev-only CLI that ingests a run's NDJSON telemetry
 * file into the local web app's idempotent ingest endpoint
 * (POST /api/telemetry/ingest, Slice 7).
 *
 * This is the local equivalent of what a future Slice 8 delivery client
 * will do: read producer NDJSON, chunk it into telemetry_batch_v1 batches
 * (<= 100 events, one producer + run, contiguous event_sequence), POST
 * with the Bearer ingest token, and surface the per-event acks.
 *
 * Usage:
 *   node scripts/dev-ingest-run.mjs <run.ndjson> [more.ndjson ...]
 *
 * Options:
 *   --url <base>   Web app base URL (default: $TELEMETRY_WEB_URL or
 *                  http://localhost:3000)
 *   --dry-run      Parse and chunk only; print what would be sent, no POST
 *
 * Env:
 *   TELEMETRY_INGEST_TOKEN  Bearer token (falls back to web/.env.local)
 *   TELEMETRY_WEB_URL       Web app base URL
 *
 * Re-running the same file is safe: the endpoint is idempotent, so a
 * second pass returns `duplicate` acks for every event (that is the
 * acceptance check for idempotency).
 *
 * Exit codes:
 *   0  all events accepted or duplicated, no HTTP failures
 *   1  usage error, unparseable NDJSON, HTTP failure, 4xx/5xx, or any
 *      event rejected
 */

import { readFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const MAX_EVENTS_PER_BATCH = 100;

function usage() {
  console.error(
    "usage: node scripts/dev-ingest-run.mjs [--url <base>] [--dry-run] <run.ndjson> [...]",
  );
}

function parseArgs(argv) {
  const options = {
    url: process.env.TELEMETRY_WEB_URL ?? "http://localhost:3000",
    dryRun: false,
    files: [],
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--url") {
      i += 1;
      if (i >= argv.length) {
        throw new Error("--url requires a value");
      }
      options.url = argv[i];
    } else if (arg === "--dry-run") {
      options.dryRun = true;
    } else if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    } else if (arg.startsWith("-")) {
      throw new Error(`unknown option: ${arg}`);
    } else {
      options.files.push(arg);
    }
  }
  return options;
}

/**
 * Reads KEY=VALUE pairs from the gitignored web/.env.local so this plain
 * Node script (outside Next's env loading) can find TELEMETRY_INGEST_TOKEN
 * the same way `next dev` does. Never prints the values.
 */
async function loadEnvLocalToken() {
  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  const envPath = path.join(scriptDir, "..", ".env.local");
  const text = await readFile(envPath, "utf8");
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed === "" || trimmed.startsWith("#")) {
      continue;
    }
    const eq = trimmed.indexOf("=");
    if (eq <= 0) {
      continue;
    }
    const key = trimmed.slice(0, eq).trim();
    let value = trimmed.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (key === "TELEMETRY_INGEST_TOKEN" && value.length > 0) {
      return value;
    }
  }
  return null;
}

/** Parses one NDJSON file into telemetry events. */
async function parseNdjson(filePath) {
  const text = await readFile(filePath, "utf8");
  const events = [];
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i].trim();
    if (line === "") {
      continue;
    }
    let event;
    try {
      event = JSON.parse(line);
    } catch (err) {
      throw new Error(
        `${filePath}:${i + 1}: invalid JSON: ${err instanceof Error ? err.message : String(err)}`,
      );
    }
    if (
      typeof event !== "object" ||
      event === null ||
      Array.isArray(event) ||
      typeof event.producer_id !== "string" ||
      typeof event.run_key !== "string" ||
      typeof event.event_id !== "string" ||
      typeof event.event_sequence !== "number"
    ) {
      throw new Error(
        `${filePath}:${i + 1}: line is not a telemetry event (missing producer_id/run_key/event_id/event_sequence)`,
      );
    }
    events.push(event);
  }
  return events;
}

/**
 * Groups events by producer+run, sorts each group by event_sequence, and
 * splits it into contiguous chunks of <= MAX_EVENTS_PER_BATCH events.
 * A sequence gap forces a chunk boundary because a batch must be
 * contiguous; the endpoint then reports per-event status for whatever it
 * can process.
 */
function chunkEvents(events) {
  const groups = new Map();
  for (const event of events) {
    const key = `${event.producer_id}\u0000${event.run_key}`;
    if (!groups.has(key)) {
      groups.set(key, []);
    }
    groups.get(key).push(event);
  }

  const chunks = [];
  for (const [key, groupEvents] of groups) {
    const [producerId, runKey] = key.split("\u0000");
    const sorted = [...groupEvents].sort(
      (a, b) => a.event_sequence - b.event_sequence,
    );

    // Duplicate sequences within one run would violate the unique event_id
    // contract; surface it here instead of mid-batch.
    for (let i = 1; i < sorted.length; i += 1) {
      if (sorted[i].event_sequence === sorted[i - 1].event_sequence) {
        throw new Error(
          `duplicate event_sequence ${sorted[i].event_sequence} in ${producerId}:${runKey}`,
        );
      }
    }

    let current = [];
    let previousSequence = null;
    const flush = () => {
      if (current.length > 0) {
        chunks.push({ producerId, runKey, events: current });
        current = [];
      }
    };
    for (const event of sorted) {
      if (
        current.length > 0 &&
        (current.length === MAX_EVENTS_PER_BATCH ||
          event.event_sequence !== previousSequence + 1)
      ) {
        flush();
      }
      current.push(event);
      previousSequence = event.event_sequence;
    }
    flush();
  }
  return chunks;
}

async function postBatch(baseUrl, token, chunk) {
  const body = JSON.stringify({
    batch_schema_version: 1,
    events: chunk.events,
  });
  const response = await fetch(
    `${baseUrl.replace(/\/+$/, "")}/api/telemetry/ingest`,
    {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${token}`,
      },
      body,
    },
  );
  const text = await response.text();
  let payload;
  try {
    payload = JSON.parse(text);
  } catch {
    payload = null;
  }
  return { status: response.status, payload };
}

function sequenceSpan(chunk) {
  const first = chunk.events[0].event_sequence;
  const last = chunk.events[chunk.events.length - 1].event_sequence;
  return `${first}-${last}`;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.files.length === 0) {
    usage();
    process.exit(1);
  }

  const token =
    process.env.TELEMETRY_INGEST_TOKEN ?? (await loadEnvLocalToken());
  if (!token) {
    console.error(
      "error: TELEMETRY_INGEST_TOKEN is not set and web/.env.local does not define it",
    );
    process.exit(1);
  }

  const totals = { accepted: 0, duplicates: 0, rejected: 0, failed: 0 };
  let hadFailure = false;

  for (const filePath of options.files) {
    const events = await parseNdjson(filePath);
    const chunks = chunkEvents(events);
    console.log(
      `file: ${path.basename(filePath)}  events: ${events.length}  batches: ${chunks.length}`,
    );

    for (const chunk of chunks) {
      const span = sequenceSpan(chunk);
      if (options.dryRun) {
        console.log(
          `  [dry-run] ${chunk.runKey} seq ${span} (${chunk.events.length} events)`,
        );
        continue;
      }

      let response;
      try {
        response = await postBatch(options.url, token, chunk);
      } catch (err) {
        totals.failed += chunk.events.length;
        hadFailure = true;
        console.error(
          `  FAIL ${chunk.runKey} seq ${span}: network error: ${err instanceof Error ? err.message : String(err)}`,
        );
        continue;
      }

      if (response.status !== 200 || !response.payload?.results) {
        totals.failed += chunk.events.length;
        hadFailure = true;
        console.error(
          `  FAIL ${chunk.runKey} seq ${span}: HTTP ${response.status}: ${JSON.stringify(response.payload ?? "(non-JSON body)")}`,
        );
        continue;
      }

      // The endpoint echoes one result per event in batch order.
      const results = response.payload.results;
      if (results.length !== chunk.events.length) {
        totals.failed += chunk.events.length;
        hadFailure = true;
        console.error(
          `  FAIL ${chunk.runKey} seq ${span}: expected ${chunk.events.length} results, got ${results.length}`,
        );
        continue;
      }

      let chunkRejected = 0;
      for (let i = 0; i < results.length; i += 1) {
        const { status } = results[i];
        const event = chunk.events[i];
        if (status === "accepted") {
          totals.accepted += 1;
        } else if (status === "duplicate") {
          totals.duplicates += 1;
        } else {
          totals.rejected += 1;
          chunkRejected += 1;
        }
        if (status !== "accepted") {
          console.log(
            `  ${status.toUpperCase()} ${chunk.runKey} seq ${event.event_sequence}` +
              (results[i].reason ? ` (${results[i].reason})` : ""),
          );
        }
      }
      const summary = response.payload.summary;
      console.log(
        `  OK ${chunk.runKey} seq ${span}: accepted=${summary.accepted} duplicates=${summary.duplicates} rejected=${summary.rejected}`,
      );
      if (chunkRejected > 0) {
        hadFailure = true;
      }
    }
  }

  if (options.dryRun) {
    return;
  }

  console.log(
    `total: accepted=${totals.accepted} duplicates=${totals.duplicates} rejected=${totals.rejected} failed=${totals.failed}`,
  );
  process.exitCode = hadFailure ? 1 : 0;
}

main().catch((err) => {
  console.error(`error: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
