import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

import Database from "better-sqlite3";

import { canonicalJson } from "./canonical-json.js";
import type {
  DeliverableEvent,
  QuarantineRecord,
  SourceCursor,
  SpoolInsertResult,
  TelemetryEvent,
} from "./types.js";

interface EventRow {
  event_id: string;
  producer_id: string;
  run_key: string;
  event_sequence: number;
  event_type: string;
  event_json: string;
}

interface CursorRow {
  source_path: string;
  file_device: string;
  file_inode: string;
  file_birthtime_ns: string;
  byte_offset: number;
  producer_id: string | null;
  run_key: string | null;
}

interface DeliveryStateRow {
  acknowledged_through: number;
}

interface CountRow {
  count: number;
}

interface DeliveryHealthRow {
  producer_id: string;
  run_key: string;
  last_attempt_at: string;
  last_success_at: string | null;
  last_error: string | null;
}

interface PrunableRunRow {
  producer_id: string;
  run_key: string;
  event_count: number;
}

export interface DeliveryHealthRecord {
  producerId: string;
  runKey: string;
  lastAttemptAt: string;
  lastSuccessAt: string | null;
  lastError: string | null;
}

export interface PrunedRun {
  producerId: string;
  runKey: string;
  eventCount: number;
}

export interface PruneResult {
  prunedRuns: PrunedRun[];
  totalEventsPruned: number;
}

export interface RunSpoolSummary {
  producer_id: string;
  run_key: string;
  event_count: number;
  minimum_sequence: number;
  maximum_sequence: number;
  acknowledged_through: number;
  next_deliverable_sequence: number | null;
}

export class DurableSpool {
  readonly databasePath: string;
  private readonly database: Database.Database;

  constructor(databasePath: string) {
    this.databasePath = databasePath;
    mkdirSync(dirname(databasePath), { recursive: true });
    this.database = new Database(databasePath);
    this.database.pragma("journal_mode = WAL");
    this.database.pragma("synchronous = FULL");
    this.database.pragma("foreign_keys = ON");
    this.database.pragma("busy_timeout = 5000");
    this.migrate();
  }

  close(): void {
    this.database.close();
  }

  inspectEvent(event: TelemetryEvent): SpoolInsertResult {
    const eventJson = canonicalJson(event);
    const existingById = this.getEventRowById(event.event_id);
    if (existingById !== undefined) {
      return existingById.event_json === eventJson
        ? { status: "duplicate" }
        : {
            status: "conflict",
            message: `event_id ${event.event_id} already exists with different content`,
          };
    }

    const existingBySequence = this.getEventRowBySequence(
      event.producer_id,
      event.run_key,
      event.event_sequence,
    );
    if (existingBySequence !== undefined) {
      return {
        status: "conflict",
        message:
          `sequence ${event.event_sequence} for ${event.producer_id}/${event.run_key} ` +
          `already belongs to ${existingBySequence.event_id}`,
      };
    }

    return { status: "inserted" };
  }

  insertEvent(event: TelemetryEvent): SpoolInsertResult {
    const inspected = this.inspectEvent(event);
    if (inspected.status !== "inserted") {
      return inspected;
    }

    this.database
      .prepare(
        `INSERT INTO spool_events (
          event_id, producer_id, run_key, event_sequence, event_type, event_json
        ) VALUES (?, ?, ?, ?, ?, ?)`,
      )
      .run(
        event.event_id,
        event.producer_id,
        event.run_key,
        event.event_sequence,
        event.event_type,
        canonicalJson(event),
      );
    return { status: "inserted" };
  }

  getCursor(sourcePath: string): SourceCursor | null {
    const row = this.database
      .prepare("SELECT * FROM source_cursors WHERE source_path = ?")
      .get(sourcePath) as CursorRow | undefined;
    if (row === undefined) {
      return null;
    }

    return {
      source_path: row.source_path,
      identity: {
        device: row.file_device,
        inode: row.file_inode,
        birthtime_ns: row.file_birthtime_ns,
      },
      offset: row.byte_offset,
      producer_id: row.producer_id,
      run_key: row.run_key,
    };
  }

  setCursor(cursor: SourceCursor): void {
    this.database
      .prepare(
        `INSERT INTO source_cursors (
          source_path, file_device, file_inode, file_birthtime_ns, byte_offset,
          producer_id, run_key
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(source_path) DO UPDATE SET
          file_device = excluded.file_device,
          file_inode = excluded.file_inode,
          file_birthtime_ns = excluded.file_birthtime_ns,
          byte_offset = excluded.byte_offset,
          producer_id = excluded.producer_id,
          run_key = excluded.run_key`,
      )
      .run(
        cursor.source_path,
        cursor.identity.device,
        cursor.identity.inode,
        cursor.identity.birthtime_ns,
        cursor.offset,
        cursor.producer_id,
        cursor.run_key,
      );
  }

  quarantine(record: QuarantineRecord): "inserted" | "duplicate" {
    const result = this.database
      .prepare(
        `INSERT OR IGNORE INTO quarantine (
          quarantine_id, source_path, file_device, file_inode,
          file_birthtime_ns, start_offset, end_offset, raw_line, error_code,
          error_message, error_details_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        record.quarantine_id,
        record.source_path,
        record.identity.device,
        record.identity.inode,
        record.identity.birthtime_ns,
        record.start_offset,
        record.end_offset,
        record.raw_line,
        record.error_code,
        record.error_message,
        canonicalJson(record.error_details),
      );
    return result.changes === 0 ? "duplicate" : "inserted";
  }

  nextDeliverable(producerId: string, runKey: string): DeliverableEvent | null {
    const expectedSequence = this.acknowledgedThrough(producerId, runKey) + 1;
    const row = this.getEventRowBySequence(
      producerId,
      runKey,
      expectedSequence,
    );
    if (row === undefined) {
      return null;
    }
    if (expectedSequence === 1 && row.event_type !== "mission.started") {
      return null;
    }
    return {
      event: JSON.parse(row.event_json) as TelemetryEvent,
      canonical_json: row.event_json,
    };
  }

  /**
   * Returns the contiguous run of spooled, not-yet-acknowledged events for a
   * run without advancing its acknowledgement cursor.
   */
  listDeliverable(
    producerId: string,
    runKey: string,
    limit: number,
  ): DeliverableEvent[] {
    if (!Number.isInteger(limit) || limit < 1) {
      return [];
    }

    const acknowledgedThrough = this.acknowledgedThrough(producerId, runKey);
    const expectedFirstSequence = acknowledgedThrough + 1;
    const rows = this.database
      .prepare(
        `SELECT * FROM spool_events
         WHERE producer_id = ? AND run_key = ? AND event_sequence > ?
         ORDER BY event_sequence
         LIMIT ?`,
      )
      .all(producerId, runKey, acknowledgedThrough, limit) as EventRow[];

    const deliverable: DeliverableEvent[] = [];
    for (let index = 0; index < rows.length; index += 1) {
      const row = rows[index];
      if (
        row === undefined ||
        row.event_sequence !== expectedFirstSequence + index
      ) {
        break;
      }
      if (row.event_sequence === 1 && row.event_type !== "mission.started") {
        return [];
      }
      deliverable.push({
        event: JSON.parse(row.event_json) as TelemetryEvent,
        canonical_json: row.event_json,
      });
    }
    return deliverable;
  }

  /** Returns one exact spooled event without changing delivery state. */
  getEvent(
    producerId: string,
    runKey: string,
    sequence: number,
  ): DeliverableEvent | null {
    const row = this.getEventRowBySequence(producerId, runKey, sequence);
    if (row === undefined) {
      return null;
    }
    return {
      event: JSON.parse(row.event_json) as TelemetryEvent,
      canonical_json: row.event_json,
    };
  }

  acknowledge(eventId: string): "acknowledged" | "duplicate" {
    return this.database.transaction(() => {
      const event = this.getEventRowById(eventId);
      if (event === undefined) {
        throw new Error(`cannot acknowledge unknown event ${eventId}`);
      }

      const acknowledgedThrough = this.acknowledgedThrough(
        event.producer_id,
        event.run_key,
      );
      if (event.event_sequence <= acknowledgedThrough) {
        const existing = this.database
          .prepare("SELECT event_id FROM acknowledgements WHERE event_id = ?")
          .get(eventId) as { event_id: string } | undefined;
        if (existing !== undefined) {
          return "duplicate";
        }
        throw new Error(
          `event ${eventId} is behind acknowledgement cursor ${acknowledgedThrough}`,
        );
      }

      const expectedSequence = acknowledgedThrough + 1;
      if (event.event_sequence !== expectedSequence) {
        throw new Error(
          `cannot acknowledge sequence ${event.event_sequence}; expected ${expectedSequence}`,
        );
      }
      if (expectedSequence === 1 && event.event_type !== "mission.started") {
        throw new Error(
          "sequence 1 must be mission.started before later delivery",
        );
      }

      this.database
        .prepare(
          `INSERT INTO acknowledgements (
            producer_id, run_key, event_sequence, event_id
          ) VALUES (?, ?, ?, ?)`,
        )
        .run(
          event.producer_id,
          event.run_key,
          event.event_sequence,
          event.event_id,
        );
      this.database
        .prepare(
          `INSERT INTO run_delivery_state (
            producer_id, run_key, acknowledged_through
          ) VALUES (?, ?, ?)
          ON CONFLICT(producer_id, run_key) DO UPDATE SET
            acknowledged_through = excluded.acknowledged_through`,
        )
        .run(event.producer_id, event.run_key, event.event_sequence);
      return "acknowledged";
    })();
  }

  eventCount(): number {
    return this.count("spool_events");
  }

  quarantineCount(): number {
    return this.count("quarantine");
  }

  listRuns(): RunSpoolSummary[] {
    const rows = this.database
      .prepare(
        `SELECT
          events.producer_id,
          events.run_key,
          COUNT(*) AS event_count,
          MIN(events.event_sequence) AS minimum_sequence,
          MAX(events.event_sequence) AS maximum_sequence,
          COALESCE(state.acknowledged_through, 0) AS acknowledged_through
        FROM spool_events AS events
        LEFT JOIN run_delivery_state AS state
          ON state.producer_id = events.producer_id
          AND state.run_key = events.run_key
        GROUP BY events.producer_id, events.run_key
        ORDER BY events.producer_id, events.run_key`,
      )
      .all() as Array<Omit<RunSpoolSummary, "next_deliverable_sequence">>;

    return rows.map((row) => ({
      ...row,
      next_deliverable_sequence:
        this.nextDeliverable(row.producer_id, row.run_key)?.event
          .event_sequence ?? null,
    }));
  }

  hasMissionEnded(producerId: string, runKey: string): boolean {
    const row = this.database
      .prepare(
        `SELECT 1 AS one FROM spool_events
         WHERE producer_id = ? AND run_key = ? AND event_type = 'mission.ended'
         LIMIT 1`,
      )
      .get(producerId, runKey) as { one: number } | undefined;
    return row !== undefined;
  }

  recordDeliveryAttempt(record: {
    producerId: string;
    runKey: string;
    at: string;
    success: boolean;
    error: string | null;
  }): void {
    this.database
      .prepare(
        `INSERT INTO delivery_health (
          producer_id, run_key, last_attempt_at, last_success_at, last_error
        ) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(producer_id, run_key) DO UPDATE SET
          last_attempt_at = excluded.last_attempt_at,
          last_success_at = CASE
            WHEN ? THEN excluded.last_attempt_at
            ELSE delivery_health.last_success_at
          END,
          last_error = CASE WHEN ? THEN NULL ELSE excluded.last_error END`,
      )
      .run(
        record.producerId,
        record.runKey,
        record.at,
        record.success ? record.at : null,
        record.success ? null : record.error,
        record.success ? 1 : 0,
        record.success ? 1 : 0,
      );
  }

  getDeliveryHealth(): DeliveryHealthRecord[] {
    const rows = this.database
      .prepare(
        `SELECT producer_id, run_key, last_attempt_at, last_success_at, last_error
         FROM delivery_health
         ORDER BY producer_id, run_key`,
      )
      .all() as DeliveryHealthRow[];
    return rows.map((row) => ({
      producerId: row.producer_id,
      runKey: row.run_key,
      lastAttemptAt: row.last_attempt_at,
      lastSuccessAt: row.last_success_at,
      lastError: row.last_error,
    }));
  }

  pruneDeliveredRuns(dryRun: boolean): PruneResult {
    const prune = this.database.transaction(() => {
      const rows = this.database
        .prepare(
          `SELECT
            events.producer_id,
            events.run_key,
            COUNT(*) AS event_count
          FROM spool_events AS events
          INNER JOIN run_delivery_state AS state
            ON state.producer_id = events.producer_id
            AND state.run_key = events.run_key
          GROUP BY events.producer_id, events.run_key
          HAVING state.acknowledged_through = MAX(events.event_sequence)
          ORDER BY events.producer_id, events.run_key`,
        )
        .all() as PrunableRunRow[];
      const prunedRuns = rows.map((row) => ({
        producerId: row.producer_id,
        runKey: row.run_key,
        eventCount: row.event_count,
      }));

      if (!dryRun) {
        const deleteAcknowledgements = this.database.prepare(
          `DELETE FROM acknowledgements
           WHERE producer_id = ? AND run_key = ?`,
        );
        const deleteEvents = this.database.prepare(
          `DELETE FROM spool_events
           WHERE producer_id = ? AND run_key = ?`,
        );
        for (const run of prunedRuns) {
          deleteAcknowledgements.run(run.producerId, run.runKey);
          deleteEvents.run(run.producerId, run.runKey);
        }
      }

      return {
        prunedRuns,
        totalEventsPruned: prunedRuns.reduce(
          (total, run) => total + run.eventCount,
          0,
        ),
      };
    });
    return prune();
  }

  private acknowledgedThrough(producerId: string, runKey: string): number {
    const row = this.database
      .prepare(
        `SELECT acknowledged_through FROM run_delivery_state
         WHERE producer_id = ? AND run_key = ?`,
      )
      .get(producerId, runKey) as DeliveryStateRow | undefined;
    return row?.acknowledged_through ?? 0;
  }

  private count(table: "spool_events" | "quarantine"): number {
    const row = this.database
      .prepare(`SELECT COUNT(*) AS count FROM ${table}`)
      .get() as CountRow;
    return row.count;
  }

  private getEventRowById(eventId: string): EventRow | undefined {
    return this.database
      .prepare("SELECT * FROM spool_events WHERE event_id = ?")
      .get(eventId) as EventRow | undefined;
  }

  private getEventRowBySequence(
    producerId: string,
    runKey: string,
    sequence: number,
  ): EventRow | undefined {
    return this.database
      .prepare(
        `SELECT * FROM spool_events
         WHERE producer_id = ? AND run_key = ? AND event_sequence = ?`,
      )
      .get(producerId, runKey, sequence) as EventRow | undefined;
  }

  private migrate(): void {
    this.database.exec(`
      CREATE TABLE IF NOT EXISTS spool_events (
        event_id TEXT PRIMARY KEY,
        producer_id TEXT NOT NULL,
        run_key TEXT NOT NULL,
        event_sequence INTEGER NOT NULL,
        event_type TEXT NOT NULL,
        event_json TEXT NOT NULL,
        inserted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        UNIQUE (producer_id, run_key, event_sequence)
      );

      CREATE TABLE IF NOT EXISTS source_cursors (
        source_path TEXT PRIMARY KEY,
        file_device TEXT NOT NULL,
        file_inode TEXT NOT NULL,
        file_birthtime_ns TEXT NOT NULL,
        byte_offset INTEGER NOT NULL CHECK (byte_offset >= 0),
        producer_id TEXT,
        run_key TEXT,
        CHECK (
          (producer_id IS NULL AND run_key IS NULL) OR
          (producer_id IS NOT NULL AND run_key IS NOT NULL)
        )
      );

      CREATE TABLE IF NOT EXISTS quarantine (
        quarantine_id TEXT PRIMARY KEY,
        source_path TEXT NOT NULL,
        file_device TEXT NOT NULL,
        file_inode TEXT NOT NULL,
        file_birthtime_ns TEXT NOT NULL,
        start_offset INTEGER NOT NULL,
        end_offset INTEGER NOT NULL,
        raw_line BLOB NOT NULL,
        error_code TEXT NOT NULL,
        error_message TEXT NOT NULL,
        error_details_json TEXT NOT NULL,
        quarantined_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      );

      CREATE TABLE IF NOT EXISTS acknowledgements (
        producer_id TEXT NOT NULL,
        run_key TEXT NOT NULL,
        event_sequence INTEGER NOT NULL,
        event_id TEXT NOT NULL UNIQUE,
        acknowledged_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (producer_id, run_key, event_sequence),
        FOREIGN KEY (event_id) REFERENCES spool_events(event_id)
      );

      CREATE TABLE IF NOT EXISTS run_delivery_state (
        producer_id TEXT NOT NULL,
        run_key TEXT NOT NULL,
        acknowledged_through INTEGER NOT NULL CHECK (acknowledged_through >= 0),
        PRIMARY KEY (producer_id, run_key)
      );

      CREATE TABLE IF NOT EXISTS delivery_health (
        producer_id TEXT NOT NULL,
        run_key TEXT NOT NULL,
        last_attempt_at TEXT NOT NULL,
        last_success_at TEXT,
        last_error TEXT,
        PRIMARY KEY (producer_id, run_key)
      );
    `);
  }
}
