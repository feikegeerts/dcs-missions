import { createHash } from "node:crypto";
import { closeSync, fstatSync, openSync, readSync, readdirSync } from "node:fs";
import type { BigIntStats } from "node:fs";
import { join, resolve } from "node:path";
import { TextDecoder } from "node:util";

import { canonicalJson } from "./canonical-json.js";
import type { EventValidator } from "./validator.js";
import type { DurableSpool, RunSpoolSummary } from "./spool.js";
import type {
  FileIdentity,
  QuarantineRecord,
  SourceCursor,
  SpoolInsertResult,
  TelemetryEvent,
} from "./types.js";

export interface CollectorHooks {
  beforeSpoolInsert?(event: TelemetryEvent): void;
  afterSpoolPersisted?(event: TelemetryEvent): void;
  afterQuarantinePersisted?(record: QuarantineRecord): void;
  beforeCursorPersisted?(cursor: SourceCursor): void;
  afterCursorPersisted?(cursor: SourceCursor): void;
}

export interface CollectionSummary {
  dry_run: boolean;
  files_seen: number;
  identity_resets: number;
  truncation_resets: number;
  complete_lines: number;
  partial_files: number;
  partial_bytes: number;
  spooled: number;
  would_spool: number;
  duplicates: number;
  quarantined: number;
  would_quarantine: number;
  duplicate_quarantines: number;
  cursor_advances: number;
  bytes_read: number;
  incidents: CollectionIncident[];
  runs: RunSpoolSummary[];
}

export interface CollectionIncident {
  path: string;
  kind: "identity-reset" | "truncation";
  detail: string;
}

export interface CollectorOptions {
  inputDirectory: string;
  spool: DurableSpool;
  validator: EventValidator;
  dryRun?: boolean;
  maxBytesPerPass?: number;
  hooks?: CollectorHooks;
}

interface LineError {
  code: string;
  message: string;
  details: unknown;
}

interface DryRunEvent {
  event: TelemetryEvent;
  canonical: string;
}

const utf8Decoder = new TextDecoder("utf-8", { fatal: true });

export class Collector {
  private readonly inputDirectory: string;
  private readonly spool: DurableSpool;
  private readonly validator: EventValidator;
  private readonly dryRun: boolean;
  private readonly maxBytesPerPass: number;
  private readonly hooks: CollectorHooks;
  private readonly dryRunEventsById = new Map<string, DryRunEvent>();
  private readonly dryRunEventsBySequence = new Map<string, DryRunEvent>();
  private readonly dryRunCursors = new Map<string, SourceCursor>();

  constructor(options: CollectorOptions) {
    this.inputDirectory = resolve(options.inputDirectory);
    this.spool = options.spool;
    this.validator = options.validator;
    this.dryRun = options.dryRun ?? false;
    this.maxBytesPerPass = options.maxBytesPerPass ?? Infinity;
    if (
      this.maxBytesPerPass !== Infinity &&
      (!Number.isSafeInteger(this.maxBytesPerPass) || this.maxBytesPerPass < 1)
    ) {
      throw new Error("maxBytesPerPass must be a positive safe integer");
    }
    this.hooks = options.hooks ?? {};
  }

  collect(): CollectionSummary {
    const summary: CollectionSummary = {
      dry_run: this.dryRun,
      files_seen: 0,
      identity_resets: 0,
      truncation_resets: 0,
      complete_lines: 0,
      partial_files: 0,
      partial_bytes: 0,
      spooled: 0,
      would_spool: 0,
      duplicates: 0,
      quarantined: 0,
      would_quarantine: 0,
      duplicate_quarantines: 0,
      cursor_advances: 0,
      bytes_read: 0,
      incidents: [],
      runs: [],
    };

    const files = readdirSync(this.inputDirectory, { withFileTypes: true })
      .filter((entry) => entry.isFile() && entry.name.endsWith(".ndjson"))
      .map((entry) => join(this.inputDirectory, entry.name))
      .sort();

    for (const path of files) {
      if (summary.bytes_read >= this.maxBytesPerPass) {
        break;
      }
      summary.files_seen += 1;
      this.collectFile(path, summary);
    }

    summary.runs = this.spool.listRuns();
    return summary;
  }

  private collectFile(path: string, summary: CollectionSummary): void {
    const sourcePath = resolve(path);
    const descriptor = openSync(sourcePath, "r");
    try {
      const stats = fstatSync(descriptor, { bigint: true });
      const identity = identityFromStats(stats);
      const size = safeFileSize(stats.size, sourcePath);
      const storedCursor = this.cursorFor(sourcePath);
      let cursor = storedCursor ?? emptyCursor(sourcePath, identity);

      if (
        storedCursor !== null &&
        !sameIdentity(storedCursor.identity, identity)
      ) {
        summary.identity_resets += 1;
        summary.incidents.push({
          path: sourcePath,
          kind: "identity-reset",
          detail: "persisted file identity differs from the current source",
        });
        cursor = emptyCursor(sourcePath, identity);
      } else if (cursor.offset > size) {
        summary.truncation_resets += 1;
        summary.incidents.push({
          path: sourcePath,
          kind: "truncation",
          detail: `persisted offset ${cursor.offset} exceeds source size ${size}`,
        });
        cursor = emptyCursor(sourcePath, identity);
      }

      const available = size - cursor.offset;
      const passBudget = this.maxBytesPerPass - summary.bytes_read;
      const remaining = Buffer.alloc(Math.min(available, passBudget));
      const baseOffset = cursor.offset;
      let bytesRead = 0;
      while (bytesRead < remaining.length) {
        const count = readSync(
          descriptor,
          remaining,
          bytesRead,
          remaining.length - bytesRead,
          cursor.offset + bytesRead,
        );
        if (count === 0) {
          break;
        }
        bytesRead += count;
      }
      summary.bytes_read += bytesRead;
      const captured = remaining.subarray(0, bytesRead);

      let lineStart = 0;
      let fileCompleteLines = 0;
      for (let index = 0; index < captured.length; index += 1) {
        if (captured[index] !== 0x0a) {
          continue;
        }

        const absoluteStart = baseOffset + lineStart;
        const absoluteEnd = baseOffset + index + 1;
        const rawLine = captured.subarray(lineStart, index);
        summary.complete_lines += 1;
        fileCompleteLines += 1;
        cursor = this.processCompleteLine(
          rawLine,
          absoluteStart,
          absoluteEnd,
          cursor,
          summary,
        );
        lineStart = index + 1;
      }

      const partialLength = captured.length - lineStart;
      if (partialLength > 0) {
        summary.partial_files += 1;
        summary.partial_bytes += partialLength;
      }

      if (
        fileCompleteLines === 0 &&
        (storedCursor === null ||
          !sameIdentity(storedCursor.identity, cursor.identity) ||
          storedCursor.offset !== cursor.offset)
      ) {
        this.persistCursor(cursor, summary);
      }
      if (!this.dryRun) {
        this.spool.recordSourceTail({
          sourcePath,
          producerId: cursor.producer_id,
          runKey: cursor.run_key,
          observedSize: size,
          durableOffset: cursor.offset,
          tailState: partialLength > 0 ? "partial" : "clear",
          observedAt: new Date().toISOString(),
        });
      }
    } finally {
      closeSync(descriptor);
    }
  }

  private processCompleteLine(
    rawLine: Buffer,
    startOffset: number,
    endOffset: number,
    cursor: SourceCursor,
    summary: CollectionSummary,
  ): SourceCursor {
    const parsed = parseLine(rawLine, this.validator);
    if ("code" in parsed) {
      this.persistQuarantine(
        quarantineRecord(
          cursor.source_path,
          cursor.identity,
          startOffset,
          endOffset,
          rawLine,
          parsed,
        ),
        summary,
      );
      return this.advanceCursor(cursor, endOffset, summary);
    }

    const event = parsed.event;
    if (
      cursor.producer_id !== null &&
      (cursor.producer_id !== event.producer_id ||
        cursor.run_key !== event.run_key)
    ) {
      this.persistQuarantine(
        quarantineRecord(
          cursor.source_path,
          cursor.identity,
          startOffset,
          endOffset,
          rawLine,
          {
            code: "source-run-mismatch",
            message:
              "one NDJSON source file may contain only one producer and run",
            details: {
              expected_producer_id: cursor.producer_id,
              expected_run_key: cursor.run_key,
              actual_producer_id: event.producer_id,
              actual_run_key: event.run_key,
            },
          },
        ),
        summary,
      );
      return this.advanceCursor(cursor, endOffset, summary);
    }

    this.hooks.beforeSpoolInsert?.(event);
    const insertion = this.insertEvent(event);
    if (insertion.status === "conflict") {
      this.persistQuarantine(
        quarantineRecord(
          cursor.source_path,
          cursor.identity,
          startOffset,
          endOffset,
          rawLine,
          {
            code: "spool-identity-conflict",
            message: insertion.message,
            details: { event_id: event.event_id },
          },
        ),
        summary,
      );
      return this.advanceCursor(cursor, endOffset, summary);
    }

    if (insertion.status === "inserted") {
      if (this.dryRun) {
        summary.would_spool += 1;
      } else {
        summary.spooled += 1;
        this.hooks.afterSpoolPersisted?.(event);
      }
    } else {
      summary.duplicates += 1;
    }

    const identifiedCursor: SourceCursor = {
      ...cursor,
      producer_id: cursor.producer_id ?? event.producer_id,
      run_key: cursor.run_key ?? event.run_key,
    };
    return this.advanceCursor(identifiedCursor, endOffset, summary);
  }

  private insertEvent(event: TelemetryEvent): SpoolInsertResult {
    if (!this.dryRun) {
      return this.spool.insertEvent(event);
    }

    const canonical = canonicalJson(event);
    const plannedById = this.dryRunEventsById.get(event.event_id);
    if (plannedById !== undefined) {
      return plannedById.canonical === canonical
        ? { status: "duplicate" }
        : {
            status: "conflict",
            message: `event_id ${event.event_id} has conflicting dry-run content`,
          };
    }
    const sequenceKey = runSequenceKey(event);
    const plannedBySequence = this.dryRunEventsBySequence.get(sequenceKey);
    if (plannedBySequence !== undefined) {
      return {
        status: "conflict",
        message: `sequence ${event.event_sequence} has conflicting dry-run content`,
      };
    }

    const persisted = this.spool.inspectEvent(event);
    if (persisted.status !== "inserted") {
      return persisted;
    }

    const planned = { event, canonical };
    this.dryRunEventsById.set(event.event_id, planned);
    this.dryRunEventsBySequence.set(sequenceKey, planned);
    return { status: "inserted" };
  }

  private persistQuarantine(
    record: QuarantineRecord,
    summary: CollectionSummary,
  ): void {
    if (this.dryRun) {
      summary.would_quarantine += 1;
      return;
    }

    const result = this.spool.quarantine(record);
    if (result === "inserted") {
      summary.quarantined += 1;
      this.hooks.afterQuarantinePersisted?.(record);
    } else {
      summary.duplicate_quarantines += 1;
    }
  }

  private advanceCursor(
    cursor: SourceCursor,
    offset: number,
    summary: CollectionSummary,
  ): SourceCursor {
    const advanced = { ...cursor, offset };
    this.persistCursor(advanced, summary);
    return advanced;
  }

  private persistCursor(
    cursor: SourceCursor,
    summary: CollectionSummary,
  ): void {
    summary.cursor_advances += 1;
    if (this.dryRun) {
      this.dryRunCursors.set(cursor.source_path, cursor);
      return;
    }

    this.hooks.beforeCursorPersisted?.(cursor);
    this.spool.setCursor(cursor);
    this.hooks.afterCursorPersisted?.(cursor);
  }

  private cursorFor(sourcePath: string): SourceCursor | null {
    return (
      this.dryRunCursors.get(sourcePath) ?? this.spool.getCursor(sourcePath)
    );
  }
}

function parseLine(
  rawLine: Buffer,
  validator: EventValidator,
): { event: TelemetryEvent } | LineError {
  const content =
    rawLine.length > 0 && rawLine[rawLine.length - 1] === 0x0d
      ? rawLine.subarray(0, rawLine.length - 1)
      : rawLine;

  let text: string;
  try {
    text = utf8Decoder.decode(content);
  } catch (error: unknown) {
    return {
      code: "invalid-utf8",
      message: "complete NDJSON line is not valid UTF-8",
      details: errorMessage(error),
    };
  }

  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch (error: unknown) {
    return {
      code: "invalid-json",
      message: "complete NDJSON line is not valid JSON",
      details: errorMessage(error),
    };
  }

  const validation = validator.validate(value);
  if (!validation.ok) {
    return {
      code: validation.code,
      message: validation.message,
      details: validation.details,
    };
  }
  return { event: validation.event };
}

function quarantineRecord(
  sourcePath: string,
  identity: FileIdentity,
  startOffset: number,
  endOffset: number,
  rawLine: Buffer,
  error: LineError,
): QuarantineRecord {
  const hash = createHash("sha256");
  for (const part of [
    sourcePath,
    identity.device,
    identity.inode,
    identity.birthtime_ns,
    String(startOffset),
    String(endOffset),
  ]) {
    hash.update(part);
    hash.update("\0");
  }
  hash.update(rawLine);
  return {
    quarantine_id: hash.digest("hex"),
    source_path: sourcePath,
    identity,
    start_offset: startOffset,
    end_offset: endOffset,
    raw_line: Buffer.from(rawLine),
    error_code: error.code,
    error_message: error.message,
    error_details: error.details,
  };
}

function identityFromStats(stats: BigIntStats): FileIdentity {
  return {
    device: stats.dev.toString(),
    inode: stats.ino.toString(),
    birthtime_ns: stats.birthtimeNs.toString(),
  };
}

function sameIdentity(left: FileIdentity, right: FileIdentity): boolean {
  return (
    left.device === right.device &&
    left.inode === right.inode &&
    left.birthtime_ns === right.birthtime_ns
  );
}

function emptyCursor(sourcePath: string, identity: FileIdentity): SourceCursor {
  return {
    source_path: sourcePath,
    identity,
    offset: 0,
    producer_id: null,
    run_key: null,
  };
}

function safeFileSize(size: bigint, path: string): number {
  if (size > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error(`source file is too large for a safe byte cursor: ${path}`);
  }
  return Number(size);
}

function runSequenceKey(event: TelemetryEvent): string {
  return `${event.producer_id}\0${event.run_key}\0${event.event_sequence}`;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
