import { execFileSync } from "node:child_process";

import type { DurableSpool, RunSpoolSummary } from "./spool.js";

export type AbortReason =
  "dcs-process-not-running" | "simulation-stop-observed";
export type ProcessState = "known-running" | "known-not-running" | "unknown";

export interface ProcessBinding {
  pid: number;
  creationTime: string;
  runKey: string;
  hookGeneration: number;
  expectedImage: string;
  commandLineScope: string;
  profilePath: string;
  inputPath: string;
}

export interface ProcessRecord {
  pid: number;
  creationTime: string;
  image: string;
  commandLine: string | null;
}

export interface ProcessObservation {
  state: ProcessState;
  pid?: number;
  creationTime?: string;
  runKey?: string;
  hookGeneration?: number;
  profilePath?: string;
  inputPath?: string;
}

export interface HookStopObservation {
  generation: number;
  runKey: string;
}

export interface LifecycleStopObservation extends HookStopObservation {
  evidenceIdentity: string;
  tailState: "clear" | "unknown";
}

export interface HookRunObservation {
  generation: number;
  runKey: string;
  producerId: string;
}

export interface AbortSignalDecision {
  producerId: string;
  runKey: string;
  reason: AbortReason | null;
  generation?: number;
}

export interface AbortSignalSummary {
  producerId: string;
  runKey: string;
  reason: AbortReason;
  generation?: number;
  posted: boolean;
  retryRequired: boolean;
  status?: number;
  error?: string;
}

export function decideAbortSignal(args: {
  producerId: string;
  runKey: string;
  hasMissionEnded: boolean;
  processState: ProcessState;
  stopGeneration?: number;
  remoteHeartbeatState?: "present" | "absent" | "unknown";
}): AbortSignalDecision {
  if (args.hasMissionEnded) {
    return { producerId: args.producerId, runKey: args.runKey, reason: null };
  }
  if (args.stopGeneration !== undefined) {
    return {
      producerId: args.producerId,
      runKey: args.runKey,
      reason: "simulation-stop-observed",
      generation: args.stopGeneration,
    };
  }
  if (args.processState === "known-not-running") {
    return {
      producerId: args.producerId,
      runKey: args.runKey,
      reason: "dcs-process-not-running",
    };
  }
  return { producerId: args.producerId, runKey: args.runKey, reason: null };
}

export function stopObservations(dcsLogText: string): HookStopObservation[] {
  return lifecycleStopObservations(dcsLogText).map(
    ({ generation, runKey }) => ({
      generation,
      runKey,
    }),
  );
}

export function lifecycleStopObservations(
  dcsLogText: string,
): LifecycleStopObservation[] {
  const observations: LifecycleStopObservation[] = [];
  const stopLine =
    /TELEMETRY_BRIDGE_HOOK STOP generation=(\d+) spooled=(\d+) spool=(.*?) failures=(\S+) stuck=(\S+) unspooled=(\S+)/g;
  for (const match of dcsLogText.matchAll(stopLine)) {
    const generationText = match[1];
    const spoolPath = match[3];
    if (generationText === undefined || spoolPath === undefined) {
      continue;
    }
    const generation = Number(generationText);
    const runKey = spoolPath
      .split(/[\\/]/)
      .pop()
      ?.replace(/\.ndjson$/, "");
    if (
      Number.isSafeInteger(generation) &&
      generation >= 1 &&
      runKey !== undefined &&
      runKey.length > 0
    ) {
      const fullEvidence = match[0];
      observations.push({
        generation,
        runKey,
        evidenceIdentity: fullEvidence,
        tailState:
          match[4] === "0" && match[5] === "nil" && match[6] === "0"
            ? "clear"
            : "unknown",
      });
    }
  }
  return observations;
}

export function runObservations(dcsLogText: string): HookRunObservation[] {
  const observations: HookRunObservation[] = [];
  const handshake =
    /TELEMETRY_BRIDGE_HOOK handshake-ok generation=(\d+) run=(\S+) producer=(\S+)/g;
  for (const match of dcsLogText.matchAll(handshake)) {
    const generation = Number(match[1]);
    const runKey = match[2];
    const producerId = match[3];
    if (
      Number.isSafeInteger(generation) &&
      generation >= 1 &&
      runKey !== undefined &&
      producerId !== undefined
    ) {
      observations.push({ generation, runKey, producerId });
    }
  }
  return observations;
}

export function classifyProcessRecord(
  binding: ProcessBinding,
  record: ProcessRecord | null,
): ProcessObservation {
  const scope = {
    pid: binding.pid,
    creationTime: binding.creationTime,
    runKey: binding.runKey,
    hookGeneration: binding.hookGeneration,
    profilePath: binding.profilePath,
    inputPath: binding.inputPath,
  };
  if (
    record === null ||
    Date.parse(record.creationTime) !== Date.parse(binding.creationTime)
  ) {
    return { state: "known-not-running", ...scope };
  }
  if (
    record.pid !== binding.pid ||
    record.image.toLowerCase() !== binding.expectedImage.toLowerCase() ||
    record.commandLine === null ||
    !record.commandLine
      .toLowerCase()
      .includes(binding.commandLineScope.toLowerCase())
  ) {
    return { state: "unknown", ...scope };
  }
  return { state: "known-running", ...scope };
}

const SECRET_ENV_SUFFIX =
  /(_|^)(TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|CREDENTIALS?)$/i;

/**
 * Returns a copy of `source` safe to pass to helper subprocesses:
 * `TELEMETRY_INGEST_TOKEN` and any obviously secret-named variables are
 * removed. The lifecycle CIM query needs no secrets, and token-bearing
 * environments must not propagate to subprocesses.
 */
export function childProcessEnv(
  source: NodeJS.ProcessEnv = process.env,
): NodeJS.ProcessEnv {
  const stripped: NodeJS.ProcessEnv = {};
  for (const [key, value] of Object.entries(source)) {
    if (value === undefined || key === "TELEMETRY_INGEST_TOKEN") {
      continue;
    }
    if (SECRET_ENV_SUFFIX.test(key)) {
      continue;
    }
    stripped[key] = value;
  }
  return stripped;
}

export function defaultProcessObservationProvider(
  binding?: ProcessBinding,
  platform = process.platform,
  execute: typeof execFileSync = execFileSync,
): ProcessObservation {
  if (binding === undefined || platform !== "win32") {
    return { state: "unknown" };
  }
  try {
    const script = [
      `$p = Get-CimInstance Win32_Process -Filter 'ProcessId = ${binding.pid}'`,
      "if ($null -eq $p) { 'null'; exit 0 }",
      "$o = [ordered]@{",
      "pid = [int]$p.ProcessId;",
      "creationTime = $p.CreationDate.ToUniversalTime().ToString('o');",
      "image = [string]$p.Name;",
      "commandLine = if ($null -eq $p.CommandLine) { $null } else { [string]$p.CommandLine }",
      "}",
      "$o | ConvertTo-Json -Compress",
    ].join("; ");
    const output = execute(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-Command", script],
      {
        encoding: "utf8",
        timeout: 5000,
        windowsHide: true,
        env: childProcessEnv(),
      },
    );
    const parsed = JSON.parse(output.trim()) as unknown;
    if (parsed === null) {
      return classifyProcessRecord(binding, null);
    }
    if (!isProcessRecord(parsed)) {
      return { state: "unknown" };
    }
    return classifyProcessRecord(binding, parsed);
  } catch {
    return { state: "unknown" };
  }
}

export async function sendAbortSignals(options: {
  baseUrl: string;
  token: string;
  fetchImpl: typeof fetch;
  timeoutMs: number;
  spool: DurableSpool;
  dcsLogText: string;
  processObservation: ProcessObservation;
  producerId: string | null;
  runs: RunSpoolSummary[];
}): Promise<AbortSignalSummary[]> {
  if (options.producerId === null) {
    return [];
  }
  const stopByRun = new Map(
    stopObservations(options.dcsLogText).map((stop) => [stop.runKey, stop]),
  );
  const observedRuns = runObservations(options.dcsLogText);
  const summaries: AbortSignalSummary[] = [];
  for (const run of options.runs) {
    if (run.producer_id !== options.producerId) {
      continue;
    }
    const observedRun = observedRuns.find(
      (observed) =>
        observed.producerId === run.producer_id &&
        observed.runKey === run.run_key,
    );
    const candidateStop = stopByRun.get(run.run_key);
    const stop =
      candidateStop !== undefined &&
      observedRun?.generation === candidateStop.generation
        ? candidateStop
        : undefined;
    const processState =
      observedRun !== undefined &&
      options.processObservation.runKey === run.run_key &&
      options.processObservation.hookGeneration === observedRun.generation
        ? options.processObservation.state
        : "unknown";
    const decision = decideAbortSignal({
      producerId: run.producer_id,
      runKey: run.run_key,
      hasMissionEnded: options.spool.hasMissionEnded(
        run.producer_id,
        run.run_key,
      ),
      processState,
      ...(stop === undefined ? {} : { stopGeneration: stop.generation }),
    });
    if (decision.reason === null) {
      continue;
    }

    const summary: AbortSignalSummary = {
      producerId: decision.producerId,
      runKey: decision.runKey,
      reason: decision.reason,
      ...(decision.generation === undefined
        ? {}
        : { generation: decision.generation }),
      posted: false,
      retryRequired: true,
    };
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), options.timeoutMs);
    try {
      const response = await options.fetchImpl(
        `${options.baseUrl.replace(/\/+$/, "")}/api/telemetry/runs/${encodeURIComponent(decision.runKey)}`,
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            authorization: `Bearer ${options.token}`,
          },
          body: JSON.stringify({
            reason: decision.reason,
            producer_id: decision.producerId,
            ...(decision.generation === undefined
              ? {}
              : { generation: decision.generation }),
          }),
          signal: controller.signal,
        },
      );
      summary.status = response.status;
      if (response.status === 200) {
        summary.posted = true;
        summary.retryRequired = false;
      } else {
        summary.error = `HTTP ${response.status}`;
      }
    } catch (error: unknown) {
      const message = controller.signal.aborted
        ? `request timed out after ${options.timeoutMs} ms`
        : error instanceof Error
          ? error.message
          : String(error);
      summary.error = redact(message, options.token);
    } finally {
      clearTimeout(timeout);
    }
    summaries.push(summary);
  }
  return summaries;
}

function isProcessRecord(value: unknown): value is ProcessRecord {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  const record = value as Record<string, unknown>;
  return (
    Number.isSafeInteger(record.pid) &&
    typeof record.creationTime === "string" &&
    Number.isFinite(Date.parse(record.creationTime)) &&
    typeof record.image === "string" &&
    (typeof record.commandLine === "string" || record.commandLine === null)
  );
}

function redact(message: string, token: string): string {
  return token.length === 0 ? message : message.split(token).join("[REDACTED]");
}
