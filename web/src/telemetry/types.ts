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
  initiator: Record<string, unknown> | null;
  target: Record<string, unknown> | null;
  participant: Record<string, unknown> | null;
  asset: Record<string, unknown> | null;
  weapon: Record<string, unknown> | null;
  coalition: string | null;
  location: Record<string, unknown> | null;
  payload: Record<string, unknown>;
}
