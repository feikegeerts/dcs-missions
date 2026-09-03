import { join, resolve } from "node:path";

import { deliver } from "./delivery.js";
import { DurableSpool } from "./spool.js";

interface CliOptions {
  state: string;
  url: string;
  dryRun: boolean;
}

function parseArguments(arguments_: string[]): CliOptions {
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
    if (!["--state", "--url"].includes(argument)) {
      throw new Error(`unknown argument: ${argument}`);
    }
    const value = arguments_[index + 1];
    if (value === undefined) {
      throw new Error(`missing value for ${argument}`);
    }
    values.set(argument, value);
    index += 1;
  }

  const state = values.get("--state");
  if (state === undefined) {
    throw new Error(
      "usage: delivery --state <state-directory> [--url <base>] [--dry-run]",
    );
  }
  return {
    state: resolve(state),
    url:
      values.get("--url") ??
      process.env.TELEMETRY_WEB_URL ??
      "http://localhost:3000",
    dryRun,
  };
}

async function main(): Promise<void> {
  const options = parseArguments(process.argv.slice(2));
  const token = process.env.TELEMETRY_INGEST_TOKEN ?? "";
  if (!options.dryRun && token.length === 0) {
    throw new Error(
      "TELEMETRY_INGEST_TOKEN is required unless --dry-run is used",
    );
  }

  const spool = new DurableSpool(join(options.state, "collector.sqlite3"));
  try {
    const summary = await deliver({
      spool,
      baseUrl: options.url,
      token,
      dryRun: options.dryRun,
    });
    console.log(JSON.stringify(summary, null, 2));
    if (summary.had_failure) {
      process.exitCode = 1;
    }
  } finally {
    spool.close();
  }
}

try {
  await main();
} catch (error: unknown) {
  const token = process.env.TELEMETRY_INGEST_TOKEN ?? "";
  const message = error instanceof Error ? error.message : String(error);
  console.error(
    token.length === 0 ? message : message.split(token).join("[REDACTED]"),
  );
  process.exitCode = 1;
}
