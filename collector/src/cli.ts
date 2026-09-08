import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { Collector } from "./collector.js";
import {
  acquireOwnership,
  OwnershipConflictError,
  releaseOwnership,
} from "./ownership.js";
import { DurableSpool } from "./spool.js";
import { createEventValidator } from "./validator.js";

interface CliOptions {
  input: string;
  state: string;
  schema: string;
  dryRun: boolean;
  lockPort?: number;
}

function parseArguments(arguments_: string[]): CliOptions {
  const moduleDirectory = dirname(fileURLToPath(import.meta.url));
  const values = new Map<string, string>();
  let dryRun = false;

  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === undefined) {
      throw new Error("argument list ended unexpectedly");
    }
    if (argument === "--dry-run") {
      dryRun = true;
      continue;
    }
    if (!["--input", "--state", "--schema", "--lock-port"].includes(argument)) {
      throw new Error(`unknown argument: ${argument}`);
    }
    const value = arguments_[index + 1];
    if (value === undefined) {
      throw new Error(`missing value for ${argument}`);
    }
    values.set(argument, value);
    index += 1;
  }

  const input = values.get("--input");
  const state = values.get("--state");
  if (input === undefined || state === undefined) {
    throw new Error(
      "usage: collector --input <telemetry-directory> --state <state-directory> [--schema <path>] [--lock-port <n>] [--dry-run]",
    );
  }

  const lockPortText = values.get("--lock-port");
  const lockPort =
    lockPortText === undefined ? undefined : Number(lockPortText);
  if (
    lockPort !== undefined &&
    (!Number.isSafeInteger(lockPort) || lockPort < 1 || lockPort > 65_535)
  ) {
    throw new Error("--lock-port must be an integer from 1 through 65535");
  }

  return {
    input: resolve(input),
    state: resolve(state),
    schema: resolve(
      values.get("--schema") ?? defaultSchemaPath(moduleDirectory),
    ),
    dryRun,
    ...(lockPort === undefined ? {} : { lockPort }),
  };
}

function defaultSchemaPath(moduleDirectory: string): string {
  const sourceTreePath = join(
    moduleDirectory,
    "..",
    "..",
    "contracts",
    "telemetry-event-v1.schema.json",
  );
  return existsSync(sourceTreePath)
    ? sourceTreePath
    : join(
        moduleDirectory,
        "..",
        "..",
        "..",
        "contracts",
        "telemetry-event-v1.schema.json",
      );
}

async function main(): Promise<void> {
  const options = parseArguments(process.argv.slice(2));
  const lock = options.dryRun
    ? undefined
    : await acquireOwnership({
        input: options.input,
        state: options.state,
        schema: options.schema,
        port: options.lockPort,
      });
  let spool: DurableSpool | undefined;
  try {
    const databasePath = join(options.state, "collector.sqlite3");
    spool = options.dryRun
      ? new DurableSpool(existsSync(databasePath) ? databasePath : ":memory:", {
          readonly: existsSync(databasePath),
        })
      : new DurableSpool(databasePath);
    const collector = new Collector({
      inputDirectory: options.input,
      spool,
      validator: createEventValidator(options.schema),
      dryRun: options.dryRun,
    });
    console.log(JSON.stringify(collector.collect(), null, 2));
  } finally {
    spool?.close();
    if (lock !== undefined) {
      await releaseOwnership(lock);
    }
  }
}

try {
  await main();
} catch (error: unknown) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = error instanceof OwnershipConflictError ? 3 : 1;
}
