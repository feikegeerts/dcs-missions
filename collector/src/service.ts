import { EventEmitter } from "node:events";
import { existsSync } from "node:fs";
import { statfs } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { defaultProcessObservationProvider } from "./abort-signal.js";
import { Collector } from "./collector.js";
import { deliver, validateDeliveryBaseUrl } from "./delivery.js";
import type { DeliveryOptions, DeliverySummary } from "./delivery.js";
import {
  acquireOwnership,
  canonicalizeOwnershipPaths,
  defaultLockPort,
  isLockHeld,
  OwnershipConflictError,
  readOwner,
  releaseOwnership,
} from "./ownership.js";
import type { OwnershipLock } from "./ownership.js";
import { DurableSpool } from "./spool.js";
import { createEventValidator } from "./validator.js";

const DEFAULT_INTERVAL_MS = 5000;
const DEFAULT_MAX_CYCLE_BYTES = 2_097_152;
const DEFAULT_URL = "https://dcs-missions.vercel.app";
const SHUTDOWN_TIMEOUT_MS = 15_000;

type TimeoutHandle = ReturnType<typeof setTimeout>;

export interface ServiceOptions {
  input: string;
  state: string;
  schema: string;
  intervalMs: number;
  maxCycleBytes: number;
  url: string;
  token: string;
  lockPort?: number;
}

export interface ServiceDependencies {
  fetchImpl?: typeof fetch;
  print?: (message: string) => void;
  setTimeoutImpl?: (
    callback: () => void,
    milliseconds: number,
  ) => TimeoutHandle;
  clearTimeoutImpl?: (handle: TimeoutHandle) => void;
  deliveryOptions?: Omit<
    Partial<DeliveryOptions>,
    "spool" | "baseUrl" | "token" | "fetchImpl"
  >;
}

export class ServiceController extends EventEmitter {
  private collectionTimer: TimeoutHandle | undefined;
  private deliveryTimer: TimeoutHandle | undefined;
  private deliveryInFlight: Promise<DeliverySummary> | undefined;
  private stopping = false;
  private tokenSkipLogged = false;

  private constructor(
    private readonly options: ServiceOptions,
    private readonly lock: OwnershipLock,
    private readonly spool: DurableSpool,
    private readonly collector: Collector,
    private readonly dependencies: Required<
      Pick<ServiceDependencies, "print" | "setTimeoutImpl" | "clearTimeoutImpl">
    > &
      ServiceDependencies,
  ) {
    super();
  }

  static async create(
    options: ServiceOptions,
    dependencies: ServiceDependencies = {},
  ): Promise<ServiceController> {
    validateDeliveryBaseUrl(options.url);
    const lock = await acquireOwnership({
      input: options.input,
      state: options.state,
      schema: options.schema,
      port: options.lockPort,
    });
    let spool: DurableSpool | undefined;
    try {
      spool = new DurableSpool(join(lock.canonicalState, "collector.sqlite3"));
      const collector = new Collector({
        inputDirectory: lock.canonicalInput,
        spool,
        validator: createEventValidator(lock.canonicalSchema),
        maxBytesPerPass: options.maxCycleBytes,
      });
      return new ServiceController(options, lock, spool, collector, {
        ...dependencies,
        print: dependencies.print ?? console.log,
        setTimeoutImpl: dependencies.setTimeoutImpl ?? setTimeout,
        clearTimeoutImpl: dependencies.clearTimeoutImpl ?? clearTimeout,
      });
    } catch (error: unknown) {
      spool?.close();
      await releaseOwnership(lock);
      throw error;
    }
  }

  start(): void {
    if (this.stopping || this.collectionTimer !== undefined) {
      return;
    }
    this.runCollectionCycle();
    this.logRecovery();
    this.runDeliveryCycle();
  }

  async stop(): Promise<number> {
    if (this.stopping) {
      return await new Promise<number>((resolvePromise) =>
        this.once("exit", resolvePromise),
      );
    }
    this.stopping = true;
    this.clearTimers();
    try {
      this.log({
        kind: "collection",
        phase: "shutdown",
        ...this.collector.collect(),
      });
    } catch (error: unknown) {
      this.log({
        kind: operationalFailureKind(error, "capture-failure"),
        component: "collection",
        phase: "shutdown",
        error: redact(errorMessage(error), this.options.token),
      });
    }

    let exitCode = 0;
    if (this.deliveryInFlight !== undefined) {
      const completed = await waitForDelivery(
        this.deliveryInFlight,
        SHUTDOWN_TIMEOUT_MS,
      );
      if (!completed) {
        exitCode = 1;
      }
    }

    if (exitCode === 0) {
      this.spool.close();
      await releaseOwnership(this.lock);
    }
    this.emit("exit", exitCode);
    return exitCode;
  }

  private runCollectionCycle(): void {
    if (this.stopping) {
      return;
    }
    try {
      this.log({
        kind: "collection",
        phase: "scheduled",
        ...this.collector.collect(),
      });
    } catch (error: unknown) {
      this.log({
        kind: operationalFailureKind(error, "capture-failure"),
        component: "collection",
        error: redact(errorMessage(error), this.options.token),
      });
    }
    this.collectionTimer = this.dependencies.setTimeoutImpl(
      () => this.runCollectionCycle(),
      this.options.intervalMs,
    );
  }

  private runDeliveryCycle(): void {
    if (this.stopping) {
      return;
    }
    if (this.options.token.length === 0) {
      if (!this.tokenSkipLogged) {
        this.log({
          kind: "delivery-skipped",
          message: "delivery skipped: TELEMETRY_INGEST_TOKEN not set",
        });
        this.tokenSkipLogged = true;
      }
    } else if (this.deliveryInFlight === undefined) {
      const delivery = deliver({
        spool: this.spool,
        baseUrl: this.options.url,
        token: this.options.token,
        fetchImpl: this.dependencies.fetchImpl,
        processObservationProvider: defaultProcessObservationProvider,
        ...this.dependencies.deliveryOptions,
      });
      this.deliveryInFlight = delivery;
      void delivery
        .then((summary) => {
          this.log({ kind: "delivery", ...summary });
          const failures = networkFailures(summary);
          if (failures.length > 0) {
            this.log({ kind: "network-failure", errors: failures });
          }
        })
        .catch((error: unknown) =>
          this.log({
            kind: operationalFailureKind(error, "delivery-error"),
            component: "delivery",
            error: redact(errorMessage(error), this.options.token),
          }),
        )
        .finally(() => {
          this.deliveryInFlight = undefined;
        });
    }
    this.deliveryTimer = this.dependencies.setTimeoutImpl(
      () => this.runDeliveryCycle(),
      this.options.intervalMs,
    );
  }

  private clearTimers(): void {
    if (this.collectionTimer !== undefined) {
      this.dependencies.clearTimeoutImpl(this.collectionTimer);
      this.collectionTimer = undefined;
    }
    if (this.deliveryTimer !== undefined) {
      this.dependencies.clearTimeoutImpl(this.deliveryTimer);
      this.deliveryTimer = undefined;
    }
  }

  private logRecovery(): void {
    try {
      this.log({
        kind: "recovery",
        lock_acquired: true,
        ...recoverySummary(this.spool),
      });
    } catch (error: unknown) {
      this.log({
        kind: "recovery",
        lock_acquired: true,
        state: "error",
        error: redact(errorMessage(error), this.options.token),
      });
    }
  }

  private log(value: object): void {
    this.dependencies.print(
      JSON.stringify(value, (_key, item: unknown) =>
        typeof item === "string" ? redact(item, this.options.token) : item,
      ),
    );
  }
}

interface ParsedServiceArguments extends ServiceOptions {
  status: boolean;
}

export function parseServiceArguments(
  arguments_: string[],
  environment: NodeJS.ProcessEnv = process.env,
): ParsedServiceArguments {
  const moduleDirectory = dirname(fileURLToPath(import.meta.url));
  const values = new Map<string, string>();
  let status = false;
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--status" || argument === "status") {
      status = true;
      continue;
    }
    if (
      argument === undefined ||
      ![
        "--input",
        "--state",
        "--schema",
        "--interval-ms",
        "--max-cycle-bytes",
        "--url",
        "--lock-port",
      ].includes(argument)
    ) {
      throw new Error(`unknown argument: ${String(argument)}`);
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
      "usage: service [--status] --input <dir> --state <dir> [--schema <path>] [--interval-ms 5000] [--max-cycle-bytes 2097152] [--url <base>] [--lock-port <n>]",
    );
  }
  const intervalMs = positiveInteger(
    values.get("--interval-ms"),
    DEFAULT_INTERVAL_MS,
    "--interval-ms",
  );
  const maxCycleBytes = positiveInteger(
    values.get("--max-cycle-bytes"),
    DEFAULT_MAX_CYCLE_BYTES,
    "--max-cycle-bytes",
  );
  const lockPort = optionalPort(values.get("--lock-port"));
  const url =
    values.get("--url") ?? environment.TELEMETRY_WEB_URL ?? DEFAULT_URL;
  validateDeliveryBaseUrl(url);
  return {
    status,
    input: resolve(input),
    state: resolve(state),
    schema: resolve(
      values.get("--schema") ?? defaultSchemaPath(moduleDirectory),
    ),
    intervalMs,
    maxCycleBytes,
    url,
    token: environment.TELEMETRY_INGEST_TOKEN ?? "",
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

export async function serviceStatus(options: ServiceOptions): Promise<object> {
  const paths = canonicalizeOwnershipPaths(options);
  const port = options.lockPort ?? defaultLockPort(paths.canonicalInput);
  const databasePath = join(paths.canonicalState, "collector.sqlite3");
  let spoolRuns: ReturnType<DurableSpool["listRuns"]> = [];
  let deliveryHealth: ReturnType<DurableSpool["getDeliveryHealth"]> = [];
  let retryState: ReturnType<DurableSpool["listRunRetryStates"]> = [];
  let lifecycleOutbox: ReturnType<DurableSpool["listLifecycleObservations"]> =
    [];
  let deliveryCircuit: ReturnType<DurableSpool["getDeliveryCircuit"]> = null;
  let sourceTails: ReturnType<DurableSpool["listSourceTails"]> = [];
  let backlog: ReturnType<DurableSpool["listBacklogSummaries"]> = [];
  let quarantineReasons: ReturnType<DurableSpool["listQuarantineReasons"]> = [];
  if (existsSync(databasePath)) {
    const spool = new DurableSpool(databasePath, { readonly: true });
    try {
      spoolRuns = spool.listRuns();
      deliveryHealth = spool.getDeliveryHealth();
      retryState = spool.listRunRetryStates();
      lifecycleOutbox = spool.listLifecycleObservations();
      deliveryCircuit = spool.getDeliveryCircuit();
      sourceTails = spool.listSourceTails();
      backlog = spool.listBacklogSummaries();
      quarantineReasons = spool.listQuarantineReasons();
    } finally {
      spool.close();
    }
  }
  const generatedAt = new Date().toISOString();
  return {
    lock: {
      port,
      held: await isLockHeld(port),
      owner: readOwner(paths.canonicalState),
    },
    input: paths.canonicalInput,
    state: paths.canonicalState,
    spool_runs: spoolRuns,
    delivery_health: deliveryHealth,
    delivery_retry_state: retryState,
    delivery_circuit: deliveryCircuit,
    lifecycle_outbox: lifecycleOutbox,
    source_tails: sourceTails,
    operational_status: {
      generated_at: generatedAt,
      backlog: backlogStatus(backlog, generatedAt),
      disk: {
        input: await diskStatus(paths.canonicalInput),
        state: await diskStatus(paths.canonicalState),
      },
      last_successful_delivery: latestTimestamp(
        deliveryHealth.map((row) => row.lastSuccessAt),
      ),
      next_retry_deadline: earliestTimestamp([
        ...retryState.map((row) => row.nextAttemptAt),
        ...lifecycleOutbox.map((row) => row.nextAttemptAt),
        deliveryCircuit?.nextProbeAt ?? null,
      ]),
      quarantine: {
        count: quarantineReasons.reduce((sum, row) => sum + row.count, 0),
        reasons: quarantineReasons,
      },
      blocks: retryState
        .filter((row) => row.blockedAtSequence !== null)
        .map((row) => ({
          producer_id: row.producerId,
          run_key: row.runKey,
          sequence: row.blockedAtSequence,
          reason: row.blockedReason,
        })),
      lifecycle: {
        pending: lifecycleOutbox.filter((row) => row.state === "pending")
          .length,
        pending_unknown_tail: lifecycleOutbox.filter(
          (row) => row.state === "pending" && row.tailState === "unknown",
        ).length,
      },
      source_tail: {
        uncertain: sourceTails.filter((row) => row.tailState === "partial")
          .length,
        sources: sourceTails
          .filter((row) => row.tailState === "partial")
          .map((row) => row.sourcePath),
      },
    },
  };
}

function recoverySummary(spool: DurableSpool): object {
  const backlog = spool.listBacklogSummaries();
  const circuit = spool.getDeliveryCircuit();
  const lifecycle = spool.listLifecycleObservations();
  return {
    run_count: spool.listRuns().length,
    backlog: {
      runs: backlog.length,
      events: backlog.reduce((sum, row) => sum + row.eventCount, 0),
      bytes: backlog.reduce((sum, row) => sum + row.byteCount, 0),
    },
    circuit:
      circuit === null
        ? { open: false, next_probe_at: null }
        : { open: true, next_probe_at: circuit.nextProbeAt },
    lifecycle_pending: lifecycle.filter((row) => row.state === "pending")
      .length,
  };
}

function backlogStatus(
  rows: ReturnType<DurableSpool["listBacklogSummaries"]>,
  generatedAt: string,
): object {
  const now = Date.parse(generatedAt);
  const runs = rows.map((row) => ({
    producer_id: row.producerId,
    run_key: row.runKey,
    count: row.eventCount,
    bytes: row.byteCount,
    oldest_at: row.oldestInsertedAt,
    age_seconds: Math.max(
      0,
      Math.floor((now - Date.parse(row.oldestInsertedAt)) / 1000),
    ),
  }));
  const oldestAt = earliestTimestamp(rows.map((row) => row.oldestInsertedAt));
  return {
    runs,
    aggregate: {
      run_count: runs.length,
      count: rows.reduce((sum, row) => sum + row.eventCount, 0),
      bytes: rows.reduce((sum, row) => sum + row.byteCount, 0),
      oldest_at: oldestAt,
      age_seconds:
        oldestAt === null
          ? null
          : Math.max(0, Math.floor((now - Date.parse(oldestAt)) / 1000)),
    },
  };
}

async function diskStatus(path: string): Promise<object> {
  try {
    const stats = await statfs(path, { bigint: true });
    return {
      path,
      available_bytes: (stats.bavail * stats.bsize).toString(),
      free_bytes: (stats.bfree * stats.bsize).toString(),
      total_bytes: (stats.blocks * stats.bsize).toString(),
      error: null,
    };
  } catch (error: unknown) {
    return {
      path,
      available_bytes: null,
      free_bytes: null,
      total_bytes: null,
      error: errorMessage(error).slice(0, 500),
    };
  }
}

function latestTimestamp(values: Array<string | null>): string | null {
  return (
    values
      .filter((value): value is string => value !== null)
      .sort((left, right) => Date.parse(right) - Date.parse(left))[0] ?? null
  );
}

function earliestTimestamp(values: Array<string | null>): string | null {
  return (
    values
      .filter((value): value is string => value !== null)
      .sort((left, right) => Date.parse(left) - Date.parse(right))[0] ?? null
  );
}

function networkFailures(summary: DeliverySummary): string[] {
  if (summary.dry_run) return [];
  const messages = [
    ...summary.runs.map((run) => run.error),
    ...(summary.abort_signals ?? []).map((signal) => signal.error),
  ].filter((message): message is string => message !== undefined);
  return messages.filter(
    (message) =>
      message.startsWith("network error:") ||
      message.startsWith("request timed out") ||
      message.includes("authenticated redirect") ||
      message.includes("response URL drift"),
  );
}

function operationalFailureKind(
  error: unknown,
  fallback: "capture-failure" | "delivery-error",
): "disk-exhaustion" | "capture-failure" | "delivery-error" {
  const code =
    typeof error === "object" && error !== null && "code" in error
      ? String(error.code)
      : "";
  const message = errorMessage(error);
  return /^(ENOSPC|EDQUOT|SQLITE_FULL|SQLITE_IOERR|SQLITE_READONLY)$/.test(
    code,
  ) || /database or disk is full|disk I\/O error/i.test(message)
    ? "disk-exhaustion"
    : fallback;
}

async function main(): Promise<number> {
  const options = parseServiceArguments(process.argv.slice(2));
  if (options.status) {
    console.log(JSON.stringify(await serviceStatus(options)));
    return 0;
  }
  const controller = await ServiceController.create(options);
  const stopped = new Promise<number>((resolvePromise) => {
    controller.once("exit", resolvePromise);
  });
  let signalReceived = false;
  const stop = (): void => {
    if (!signalReceived) {
      signalReceived = true;
      void controller.stop();
    }
  };
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  controller.start();
  return await stopped;
}

function positiveInteger(
  value: string | undefined,
  fallback: number,
  flag: string,
): number {
  const parsed = value === undefined ? fallback : Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1) {
    throw new Error(`${flag} must be a positive integer`);
  }
  return parsed;
}

function optionalPort(value: string | undefined): number | undefined {
  if (value === undefined) {
    return undefined;
  }
  const port = Number(value);
  if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) {
    throw new Error("--lock-port must be an integer from 1 through 65535");
  }
  return port;
}

function redact(message: string, token: string): string {
  return (
    token.length === 0 ? message : message.split(token).join("[REDACTED]")
  ).slice(0, 500);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function waitForDelivery(
  delivery: Promise<DeliverySummary>,
  timeoutMs: number,
): Promise<boolean> {
  let timeout: ReturnType<typeof setTimeout> | undefined;
  const completed = await Promise.race([
    delivery.then(
      () => true,
      () => true,
    ),
    new Promise<false>((resolvePromise) => {
      timeout = setTimeout(() => resolvePromise(false), timeoutMs);
    }),
  ]);
  if (timeout !== undefined) {
    clearTimeout(timeout);
  }
  return completed;
}

if (
  process.argv[1] !== undefined &&
  resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))
) {
  try {
    const exitCode = await main();
    if (exitCode === 1) {
      process.exit(1);
    }
    process.exitCode = exitCode;
  } catch (error: unknown) {
    const token = process.env.TELEMETRY_INGEST_TOKEN ?? "";
    console.error(redact(errorMessage(error), token));
    process.exitCode = error instanceof OwnershipConflictError ? 3 : 1;
  }
}
