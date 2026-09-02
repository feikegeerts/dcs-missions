import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import type { TelemetryEvent } from "../src/types.js";

export const repositoryRoot = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
);

export const schemaPath = join(
  repositoryRoot,
  "contracts",
  "telemetry-event-v1.schema.json",
);

export interface TestWorkspace {
  root: string;
  input: string;
  state: string;
  cleanup(): void;
}

export function createWorkspace(): TestWorkspace {
  const root = mkdtempSync(join(tmpdir(), "dcs-collector-"));
  const input = join(root, "input");
  const state = join(root, "state");
  mkdirSync(input, { recursive: true });
  mkdirSync(state, { recursive: true });
  return {
    root,
    input,
    state,
    cleanup(): void {
      rmSync(root, { recursive: true, force: true });
    },
  };
}

export function fixture(name: string): TelemetryEvent {
  return JSON.parse(
    readFileSync(
      join(repositoryRoot, "contracts", "fixtures", "valid", name),
      "utf8",
    ),
  ) as TelemetryEvent;
}

export function invalidFixture(kind: string, name: string): unknown {
  return JSON.parse(
    readFileSync(
      join(repositoryRoot, "contracts", "fixtures", kind, name),
      "utf8",
    ),
  ) as unknown;
}

export function cloneEvent(event: TelemetryEvent): TelemetryEvent {
  return JSON.parse(JSON.stringify(event)) as TelemetryEvent;
}

export function forRun(
  event: TelemetryEvent,
  runKey: string,
  producerId = event.producer_id,
): TelemetryEvent {
  const changed = cloneEvent(event);
  changed.producer_id = producerId;
  changed.run_key = runKey;
  changed.event_id = `${producerId}:${runKey}:${changed.event_sequence}`;
  return changed;
}

export function ndjson(events: unknown[], finalNewline = true): string {
  const body = events.map((event) => JSON.stringify(event)).join("\n");
  return finalNewline && events.length > 0 ? `${body}\n` : body;
}

export function writeRun(
  inputDirectory: string,
  name: string,
  events: unknown[],
  finalNewline = true,
): string {
  const path = join(inputDirectory, name);
  writeFileSync(path, ndjson(events, finalNewline), "utf8");
  return path;
}
