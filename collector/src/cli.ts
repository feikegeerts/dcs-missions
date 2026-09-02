import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { Collector } from "./collector.js";
import { DurableSpool } from "./spool.js";
import { createEventValidator } from "./validator.js";

interface CliOptions {
  input: string;
  state: string;
  schema: string;
  dryRun: boolean;
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
    if (!["--input", "--state", "--schema"].includes(argument)) {
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
      "usage: collector --input <telemetry-directory> --state <state-directory> [--schema <path>] [--dry-run]",
    );
  }

  return {
    input: resolve(input),
    state: resolve(state),
    schema: resolve(
      values.get("--schema") ??
        join(
          moduleDirectory,
          "..",
          "..",
          "..",
          "contracts",
          "telemetry-event-v1.schema.json",
        ),
    ),
    dryRun,
  };
}

function main(): void {
  const options = parseArguments(process.argv.slice(2));
  const spool = new DurableSpool(join(options.state, "collector.sqlite3"));
  try {
    const collector = new Collector({
      inputDirectory: options.input,
      spool,
      validator: createEventValidator(options.schema),
      dryRun: options.dryRun,
    });
    console.log(JSON.stringify(collector.collect(), null, 2));
  } finally {
    spool.close();
  }
}

try {
  main();
} catch (error: unknown) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
