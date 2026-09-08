import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { deliver } from "./delivery.js";
import {
  defaultProcessObservationProvider,
  type ProcessBinding,
} from "./abort-signal.js";
import { DurableSpool } from "./spool.js";
import {
  acquireOwnership,
  OwnershipConflictError,
  readOwner,
  releaseOwnership,
} from "./ownership.js";

const USAGE =
  "usage: delivery [status | prune] --state <state-directory> [--input <telemetry-directory>] [--schema <path>] [--lock-port <n>] [--url <base>] [--dcs-log <path>] [--producer-id-file <path>] [--dcs-pid <id> --dcs-created-at <ISO> --dcs-run-key <key> --hook-generation <n> --dcs-image <name> --dcs-process-scope <text> --dcs-profile <path> --telemetry-input <path>] [--dry-run]";

export interface CliOptions {
  mode: "deliver" | "status" | "prune";
  state: string;
  url: string;
  dryRun: boolean;
  dcsLog?: string;
  producerIdFile?: string;
  processBinding?: ProcessBinding;
  input?: string;
  schema: string;
  lockPort?: number;
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
      retry_attempt_count: number;
      next_retry_at: string | null;
      retry_classification: string | null;
      retry_error: string | null;
      blocked_at_sequence: number | null;
      blocked_event_id: string | null;
      blocked_reason: string | null;
      lifecycle_pending: number;
      tail_uncertain: boolean;
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
  circuit: {
    open: boolean;
    open_since: string | null;
    next_probe_at: string | null;
    attempt_count: number;
    last_status: string | null;
  };
  lifecycle_outbox: ReturnType<DurableSpool["listLifecycleObservations"]>;
  source_tails: ReturnType<DurableSpool["listSourceTails"]>;
}

export function parseCliArguments(
  arguments_: string[],
  webUrl = process.env.TELEMETRY_WEB_URL,
): CliOptions {
  const moduleDirectory = dirname(fileURLToPath(import.meta.url));
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
        "--input",
        "--schema",
        "--lock-port",
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
    mode,
    state: resolve(state),
    url: values.get("--url") ?? webUrl ?? "http://localhost:3000",
    dryRun,
    ...(values.has("--input")
      ? { input: resolve(values.get("--input")!) }
      : {}),
    schema: resolve(
      values.get("--schema") ?? defaultSchemaPath(moduleDirectory),
    ),
    ...(lockPort === undefined ? {} : { lockPort }),
    ...(values.has("--dcs-log")
      ? { dcsLog: resolve(values.get("--dcs-log")!) }
      : {}),
    ...(values.has("--producer-id-file")
      ? { producerIdFile: resolve(values.get("--producer-id-file")!) }
      : {}),
    ...(processBinding === undefined ? {} : { processBinding }),
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

export function runStatus(
  spool: DurableSpool,
  nowProvider: () => string = () => new Date().toISOString(),
): StatusOutput {
  const health = spool.getDeliveryHealth();
  const healthByRun = new Map(
    health.map((row) => [`${row.producerId}\0${row.runKey}`, row]),
  );
  const retryByRun = new Map(
    spool
      .listRunRetryStates()
      .map((row) => [`${row.producerId}\0${row.runKey}`, row]),
  );
  const lifecycle = spool.listLifecycleObservations();
  const runs = spool.listRuns().map((run) => {
    const row = healthByRun.get(`${run.producer_id}\0${run.run_key}`);
    const retry = retryByRun.get(`${run.producer_id}\0${run.run_key}`);
    const pending = lifecycle.filter(
      (item) =>
        item.producerId === run.producer_id &&
        item.runKey === run.run_key &&
        item.state === "pending",
    );
    return {
      ...run,
      last_attempt_at: row?.lastAttemptAt ?? null,
      last_success_at: row?.lastSuccessAt ?? null,
      last_error: row?.lastError ?? null,
      retry_attempt_count: retry?.attemptCount ?? 0,
      next_retry_at: retry?.nextAttemptAt ?? null,
      retry_classification: retry?.lastClassification ?? null,
      retry_error: retry?.lastError ?? null,
      blocked_at_sequence: retry?.blockedAtSequence ?? null,
      blocked_event_id: retry?.blockedEventId ?? null,
      blocked_reason: retry?.blockedReason ?? null,
      lifecycle_pending: pending.length,
      tail_uncertain:
        pending.some((item) => item.tailState === "unknown") ||
        spool.runHasPartialTail(run.producer_id, run.run_key),
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
    circuit: statusCircuit(spool),
    lifecycle_outbox: lifecycle,
    source_tails: spool.listSourceTails(),
  };
}

function statusCircuit(spool: DurableSpool): StatusOutput["circuit"] {
  const circuit = spool.getDeliveryCircuit();
  return circuit === null
    ? {
        open: false,
        open_since: null,
        next_probe_at: null,
        attempt_count: 0,
        last_status: null,
      }
    : {
        open: true,
        open_since: circuit.openSince,
        next_probe_at: circuit.nextProbeAt,
        attempt_count: circuit.attemptCount,
        last_status: circuit.lastStatus,
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

  const databasePath = join(parsed.state, "collector.sqlite3");
  if (parsed.mode === "status" && !existsSync(databasePath)) {
    const output: StatusOutput = {
      mode: "status",
      spool_path: databasePath,
      generated_at: (options.nowProvider ?? (() => new Date().toISOString()))(),
      runs: [],
      totals: { runs: 0, events_spooled: 0, quarantined: 0 },
      latest: { last_attempt_at: null, last_success_at: null },
      circuit: {
        open: false,
        open_since: null,
        next_probe_at: null,
        attempt_count: 0,
        last_status: null,
      },
      lifecycle_outbox: [],
      source_tails: [],
    };
    (options.print ?? console.log)(JSON.stringify(output, null, 2));
    return 0;
  }

  const diagnosticOwner = readOwner(parsed.state);
  const ownershipInput =
    parsed.input ??
    parsed.processBinding?.inputPath ??
    diagnosticOwner?.canonical_input ??
    parsed.state;
  const lock =
    parsed.mode === "status"
      ? undefined
      : await acquireOwnership({
          input: ownershipInput,
          state: parsed.state,
          schema: parsed.schema,
          port: parsed.lockPort,
        });
  let spool: DurableSpool | undefined;
  try {
    spool = new DurableSpool(databasePath, {
      readonly: parsed.mode === "status",
    });
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
    spool?.close();
    if (lock !== undefined) {
      await releaseOwnership(lock);
    }
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
    process.exitCode = error instanceof OwnershipConflictError ? 3 : 1;
  }
}
