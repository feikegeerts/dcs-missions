import { EventEmitter } from "node:events";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { defaultProcessObservationProvider } from "./abort-signal.js";
import { Collector } from "./collector.js";
import { deliver } from "./delivery.js";
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
        kind: "collection-error",
        phase: "shutdown",
        error: errorMessage(error),
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
      this.log({ kind: "collection-error", error: errorMessage(error) });
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
        .then((summary) => this.log({ kind: "delivery", ...summary }))
        .catch((error: unknown) =>
          this.log({
            kind: "delivery-error",
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

  private log(value: object): void {
    this.dependencies.print(JSON.stringify(value));
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
  return {
    status,
    input: resolve(input),
    state: resolve(state),
    schema: resolve(
      values.get("--schema") ?? defaultSchemaPath(moduleDirectory),
    ),
    intervalMs,
    maxCycleBytes,
    url: values.get("--url") ?? environment.TELEMETRY_WEB_URL ?? DEFAULT_URL,
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
  if (existsSync(databasePath)) {
    const spool = new DurableSpool(databasePath, { readonly: true });
    try {
      spoolRuns = spool.listRuns();
      deliveryHealth = spool.getDeliveryHealth();
      retryState = spool.listRunRetryStates();
      lifecycleOutbox = spool.listLifecycleObservations();
      deliveryCircuit = spool.getDeliveryCircuit();
      sourceTails = spool.listSourceTails();
    } finally {
      spool.close();
    }
  }
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
  };
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
