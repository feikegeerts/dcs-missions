export interface TelemetryEvent {
  schema_version: 1;
  event_id: string;
  source: "moose-mission";
  producer_id: string;
  source_version: string;
  run_key: string;
  event_sequence: number;
  event_type: string;
  sim_time: number;
  wall_time: string | null;
  initiator: unknown;
  target: unknown;
  participant: unknown;
  asset: unknown;
  weapon: unknown;
  coalition: unknown;
  location: unknown;
  payload: Record<string, unknown>;
}

export interface FileIdentity {
  device: string;
  inode: string;
  birthtime_ns: string;
}

export interface SourceCursor {
  source_path: string;
  identity: FileIdentity;
  offset: number;
  producer_id: string | null;
  run_key: string | null;
}

export interface QuarantineRecord {
  quarantine_id: string;
  source_path: string;
  identity: FileIdentity;
  start_offset: number;
  end_offset: number;
  raw_line: Buffer;
  error_code: string;
  error_message: string;
  error_details: unknown;
}

export type EventValidationResult =
  | { ok: true; event: TelemetryEvent }
  | {
      ok: false;
      code: "schema-invalid" | "semantic-invalid";
      message: string;
      details: unknown;
    };

export type SpoolInsertResult =
  | { status: "inserted" }
  | { status: "duplicate" }
  | { status: "conflict"; message: string };

export interface DeliverableEvent {
  event: TelemetryEvent;
  canonical_json: string;
}
