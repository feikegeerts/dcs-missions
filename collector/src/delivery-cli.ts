import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { deliver } from "./delivery.js";
import {
  defaultProcessObservationProvider,
  type ProcessBinding,
} from "./abort-signal.js";
import { DurableSpool } from "./spool.js";

const USAGE =
  "usage: delivery [status | prune] --state <state-directory> [--url <base>] [--dcs-log <path>] [--producer-id-file <path>] [--dcs-pid <id> --dcs-created-at <ISO> --dcs-run-key <key> --hook-generation <n> --dcs-image <name> --dcs-process-scope <text> --dcs-profile <path> --telemetry-input <path>] [--dry-run]";

export interface CliOptions {
  mode: "deliver" | "status" | "prune";
  state: string;
  url: string;
  dryRun: boolean;
  dcsLog?: string;
  producerIdFile?: string;
  processBinding?: ProcessBinding;
}

export interface StatusOutput {
  mode: "status";
  spool_path: string;
  generated_at: string;
  runs: Array<
    ReturnType<DurableSpool["listRuns"]>[number] & {
      last_attempt_at: string | null;
      last_success_at: string | null;
      last_error: string | null;
    }
  >;
  totals: {
    runs: number;
    events_spooled: number;
    quarantined: number;
  };
  latest: {
    last_attempt_at: string | null;
    last_success_at: string | null;
  };
}

export function parseCliArguments(
  arguments_: string[],
  webUrl = process.env.TELEMETRY_WEB_URL,
): CliOptions {
  let mode: CliOptions["mode"] = "deliver";
  let argumentIndex = 0;
  const first = arguments_[0];
  if (first !== undefined && !first.startsWith("--")) {
    if (first !== "status" && first !== "prune") {
      throw new Error(`unknown command: ${first}\n${USAGE}`);
    }
    mode = first;
    argumentIndex = 1;
  }

  const values = new Map<string, string>();
  let dryRun = false;
  for (let index = argumentIndex; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === undefined) {
      throw new Error("argument list ended unexpectedly");
    }
    if (argument === "--dry-run") {
      dryRun = true;
      continue;
    }
    if (
      ![
        "--state",
        "--url",
        "--dcs-log",
        "--producer-id-file",
        "--dcs-pid",
        "--dcs-created-at",
        "--dcs-run-key",
        "--hook-generation",
        "--dcs-image",
        "--dcs-process-scope",
        "--dcs-profile",
        "--telemetry-input",
      ].includes(argument)
    ) {
      throw new Error(`unknown argument: ${argument}\n${USAGE}`);
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
    throw new Error(USAGE);
  }
  if (mode === "status" && dryRun) {
    throw new Error(`--dry-run is not valid for status\n${USAGE}`);
  }
  if (mode !== "deliver" && values.has("--url")) {
    throw new Error(`--url is only valid for delivery\n${USAGE}`);
  }
  const deliveryOnly = [
    "--dcs-log",
    "--producer-id-file",
    "--dcs-pid",
    "--dcs-created-at",
    "--dcs-run-key",
    "--hook-generation",
    "--dcs-image",
    "--dcs-process-scope",
    "--dcs-profile",
    "--telemetry-input",
  ];
  if (mode !== "deliver" && deliveryOnly.some((flag) => values.has(flag))) {
    throw new Error(
      `DCS lifecycle options are only valid for delivery\n${USAGE}`,
    );
  }

  const processFlags = [
    "--dcs-pid",
    "--dcs-created-at",
    "--dcs-run-key",
    "--hook-generation",
    "--dcs-image",
    "--dcs-process-scope",
    "--dcs-profile",
    "--telemetry-input",
  ];
  const suppliedProcessFlags = processFlags.filter((flag) => values.has(flag));
  if (
    suppliedProcessFlags.length !== 0 &&
    suppliedProcessFlags.length !== processFlags.length
  ) {
    throw new Error(`all DCS process binding options are required\n${USAGE}`);
  }
  let processBinding: ProcessBinding | undefined;
  if (suppliedProcessFlags.length === processFlags.length) {
    const pid = Number(values.get("--dcs-pid"));
    const creationTime = values.get("--dcs-created-at")!;
    const hookGeneration = Number(values.get("--hook-generation"));
    if (!Number.isSafeInteger(pid) || pid < 1) {
      throw new Error("--dcs-pid must be a positive integer");
    }
    if (!Number.isFinite(Date.parse(creationTime))) {
      throw new Error("--dcs-created-at must be an ISO timestamp");
    }
    if (!Number.isSafeInteger(hookGeneration) || hookGeneration < 1) {
      throw new Error("--hook-generation must be a positive integer");
    }
    processBinding = {
      pid,
      creationTime,
      runKey: values.get("--dcs-run-key")!,
      hookGeneration,
      expectedImage: values.get("--dcs-image")!,
      commandLineScope: values.get("--dcs-process-scope")!,
      profilePath: resolve(values.get("--dcs-profile")!),
      inputPath: resolve(values.get("--telemetry-input")!),
    };
    if (
      processBinding.expectedImage.length === 0 ||
      processBinding.runKey.length === 0 ||
      processBinding.commandLineScope.length === 0
    ) {
      throw new Error("DCS image and process scope must not be empty");
    }
  }

  return {
    mode,
    state: resolve(state),
    url: values.get("--url") ?? webUrl ?? "http://localhost:3000",
    dryRun,
    ...(values.has("--dcs-log")
      ? { dcsLog: resolve(values.get("--dcs-log")!) }
      : {}),
    ...(values.has("--producer-id-file")
      ? { producerIdFile: resolve(values.get("--producer-id-file")!) }
      : {}),
    ...(processBinding === undefined ? {} : { processBinding }),
  };
}

export function runStatus(
  spool: DurableSpool,
  nowProvider: () => string = () => new Date().toISOString(),
): StatusOutput {
  const health = spool.getDeliveryHealth();
  const healthByRun = new Map(
    health.map((row) => [`${row.producerId}\0${row.runKey}`, row]),
  );
  const runs = spool.listRuns().map((run) => {
    const row = healthByRun.get(`${run.producer_id}\0${run.run_key}`);
    return {
      ...run,
      last_attempt_at: row?.lastAttemptAt ?? null,
      last_success_at: row?.lastSuccessAt ?? null,
      last_error: row?.lastError ?? null,
    };
  });
  return {
    mode: "status",
    spool_path: spool.databasePath,
    generated_at: nowProvider(),
    runs,
    totals: {
      runs: runs.length,
      events_spooled: spool.eventCount(),
      quarantined: spool.quarantineCount(),
    },
    latest: {
      last_attempt_at: latestTimestamp(health.map((row) => row.lastAttemptAt)),
      last_success_at: latestTimestamp(health.map((row) => row.lastSuccessAt)),
    },
  };
}

export function runPrune(spool: DurableSpool, dryRun: boolean): object {
  const result = spool.pruneDeliveredRuns(dryRun);
  return {
    mode: "prune",
    dry_run: dryRun,
    pruned_runs: result.prunedRuns,
    total_events_pruned: result.totalEventsPruned,
  };
}

export async function runCli(
  arguments_: string[],
  options: {
    token?: string;
    webUrl?: string;
    print?: (message: string) => void;
    nowProvider?: () => string;
  } = {},
): Promise<number> {
  const parsed = parseCliArguments(arguments_, options.webUrl);
  const token = options.token ?? process.env.TELEMETRY_INGEST_TOKEN ?? "";
  if (parsed.mode === "deliver" && !parsed.dryRun && token.length === 0) {
    throw new Error(
      "TELEMETRY_INGEST_TOKEN is required unless --dry-run is used",
    );
  }

  const spool = new DurableSpool(join(parsed.state, "collector.sqlite3"));
  try {
    let output: object;
    let exitCode = 0;
    if (parsed.mode === "status") {
      output = runStatus(spool, options.nowProvider);
    } else if (parsed.mode === "prune") {
      output = runPrune(spool, parsed.dryRun);
    } else {
      const summary = await deliver({
        spool,
        baseUrl: parsed.url,
        token,
        dryRun: parsed.dryRun,
        nowProvider: options.nowProvider,
        dcsLogTextProvider: () =>
          readLogText(parsed.dcsLog ?? process.env.TELEMETRY_DCS_LOG),
        dcsProducerIdProvider: () => readProducerId(parsed.producerIdFile),
        processObservationProvider: () =>
          defaultProcessObservationProvider(parsed.processBinding),
      });
      output = summary;
      if (summary.had_failure) {
        exitCode = 1;
      }
    }
    (options.print ?? console.log)(JSON.stringify(output, null, 2));
    return exitCode;
  } finally {
    spool.close();
  }
}

function readLogText(path: string | undefined): string {
  if (path === undefined || path.length === 0) {
    return "";
  }
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

function readProducerId(path: string | undefined): string | null {
  if (path === undefined || path.length === 0) {
    return null;
  }
  try {
    const producerId = readFileSync(path, "utf8");
    return /^[A-Za-z0-9._:-]+$/.test(producerId) ? producerId : null;
  } catch {
    return null;
  }
}

function latestTimestamp(values: Array<string | null>): string | null {
  return values.reduce<string | null>(
    (latest, value) =>
      value !== null && (latest === null || value > latest) ? value : latest,
    null,
  );
}

if (
  process.argv[1] !== undefined &&
  resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))
) {
  try {
    process.exitCode = await runCli(process.argv.slice(2));
  } catch (error: unknown) {
    const token = process.env.TELEMETRY_INGEST_TOKEN ?? "";
    const message = error instanceof Error ? error.message : String(error);
    console.error(
      token.length === 0 ? message : message.split(token).join("[REDACTED]"),
    );
    process.exitCode = 1;
  }
}
