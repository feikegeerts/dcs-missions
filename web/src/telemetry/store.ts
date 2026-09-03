import { and, asc, desc, eq, sql } from "drizzle-orm";

import { getDb } from "@/db/client";
import { missionRuns, telemetryEvents } from "@/db/schema";
import type { TelemetryEvent } from "./types";

export type RunRow = typeof missionRuns.$inferSelect;
export type EventRow = typeof telemetryEvents.$inferSelect;

export interface RunUpsertInput {
  producerId: string;
  runKey: string;
  missionName?: string | null;
  missionVersion?: string | null;
  mapName?: string | null;
  runClassification?: string | null;
  firstSequence: number;
  lastSequence: number;
  acceptedDelta: number;
  startedAt?: string | null;
  endedAt?: string | null;
  status: "active" | "ended";
}

export interface TelemetryStore {
  insertEvent(
    event: TelemetryEvent,
  ): Promise<"accepted" | "duplicate" | "rejected">;
  upsertRun(run: RunUpsertInput): Promise<void>;
  listRuns(limit?: number): Promise<RunRow[]>;
  getRunByRunKey(runKey: string): Promise<RunRow | null>;
  listEvents(
    producerId: string,
    runKey: string,
    limit: number,
    offset: number,
  ): Promise<EventRow[]>;
}

function nullableObjectField(
  value: Record<string, unknown> | null,
  key: string,
): string | null {
  const field = value?.[key];
  return typeof field === "string" ? field : null;
}

function objectOrNull(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function eventRow(event: TelemetryEvent) {
  const location = objectOrNull(event.location);
  const weapon = objectOrNull(event.weapon);
  const initiator = objectOrNull(event.initiator);
  const target = objectOrNull(event.target);
  const asset = objectOrNull(event.asset);
  const locationStatus = nullableObjectField(location, "status");
  const weaponStatus = nullableObjectField(weapon, "status");

  return {
    eventId: event.event_id,
    producerId: event.producer_id,
    runKey: event.run_key,
    eventSequence: event.event_sequence,
    eventType: event.event_type,
    simTime: event.sim_time,
    wallTime: event.wall_time ? new Date(event.wall_time) : null,
    source: event.source,
    sourceVersion: event.source_version,
    schemaVersion: event.schema_version,
    coalition: event.coalition,
    locationStatus,
    locationX:
      locationStatus === "known" && typeof location?.x === "number"
        ? location.x
        : null,
    locationY:
      locationStatus === "known" && typeof location?.y === "number"
        ? location.y
        : null,
    locationZ:
      locationStatus === "known" && typeof location?.z === "number"
        ? location.z
        : null,
    weaponStatus,
    weaponDcsType:
      weaponStatus === "known" ? nullableObjectField(weapon, "dcs_type") : null,
    weaponCategory:
      weaponStatus === "known" ? nullableObjectField(weapon, "category") : null,
    initiatorStatus: nullableObjectField(initiator, "status"),
    initiatorKind: nullableObjectField(initiator, "kind"),
    initiatorParticipantId: nullableObjectField(initiator, "participant_id"),
    initiatorDcsName: nullableObjectField(initiator, "dcs_name"),
    targetStatus: nullableObjectField(target, "status"),
    targetKind: nullableObjectField(target, "kind"),
    targetDcsName: nullableObjectField(target, "dcs_name"),
    assetStatus: nullableObjectField(asset, "status"),
    assetKey: nullableObjectField(asset, "asset_key"),
    assetDcsName: nullableObjectField(asset, "dcs_name"),
    payload: event.payload,
    eventJson: event,
  };
}

function isUniqueViolation(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    error.code === "23505"
  );
}

export class NeonTelemetryStore implements TelemetryStore {
  async insertEvent(
    event: TelemetryEvent,
  ): Promise<"accepted" | "duplicate" | "rejected"> {
    try {
      const rows = await getDb()
        .insert(telemetryEvents)
        .values(eventRow(event))
        .onConflictDoNothing({ target: telemetryEvents.eventId })
        .returning({ eventId: telemetryEvents.eventId });
      return rows.length > 0 ? "accepted" : "duplicate";
    } catch (error) {
      if (isUniqueViolation(error)) {
        return "rejected";
      }
      throw error;
    }
  }

  async upsertRun(input: RunUpsertInput): Promise<void> {
    const db = getDb();
    await db
      .insert(missionRuns)
      .values({
        producerId: input.producerId,
        runKey: input.runKey,
        missionName: input.missionName ?? null,
        missionVersion: input.missionVersion ?? null,
        mapName: input.mapName ?? null,
        runClassification: input.runClassification ?? null,
        firstSequence: input.firstSequence,
        lastSequence: input.lastSequence,
        eventCount: input.acceptedDelta,
        startedAt: input.startedAt ? new Date(input.startedAt) : null,
        endedAt: input.endedAt ? new Date(input.endedAt) : null,
        status: input.status,
      })
      .onConflictDoUpdate({
        target: [missionRuns.producerId, missionRuns.runKey],
        set: {
          firstSequence: sql`LEAST(${missionRuns.firstSequence}, EXCLUDED.first_sequence)`,
          lastSequence: sql`GREATEST(${missionRuns.lastSequence}, EXCLUDED.last_sequence)`,
          eventCount: sql`${missionRuns.eventCount} + EXCLUDED.event_count`,
          startedAt: sql`COALESCE(EXCLUDED.started_at, ${missionRuns.startedAt})`,
          endedAt: sql`COALESCE(EXCLUDED.ended_at, ${missionRuns.endedAt})`,
          status: sql`CASE WHEN EXCLUDED.status = 'ended' THEN 'ended' ELSE ${missionRuns.status} END`,
          missionName: sql`COALESCE(EXCLUDED.mission_name, ${missionRuns.missionName})`,
          missionVersion: sql`COALESCE(EXCLUDED.mission_version, ${missionRuns.missionVersion})`,
          mapName: sql`COALESCE(EXCLUDED.map_name, ${missionRuns.mapName})`,
          runClassification: sql`COALESCE(EXCLUDED.run_classification, ${missionRuns.runClassification})`,
          updatedAt: sql`now()`,
        },
      });
  }

  async listRuns(limit = 100): Promise<RunRow[]> {
    return getDb()
      .select()
      .from(missionRuns)
      .orderBy(desc(missionRuns.updatedAt))
      .limit(limit);
  }

  async getRunByRunKey(runKey: string): Promise<RunRow | null> {
    const rows = await getDb()
      .select()
      .from(missionRuns)
      .where(eq(missionRuns.runKey, runKey))
      .limit(1);
    return rows[0] ?? null;
  }

  async listEvents(
    producerId: string,
    runKey: string,
    limit: number,
    offset: number,
  ): Promise<EventRow[]> {
    return getDb()
      .select()
      .from(telemetryEvents)
      .where(
        and(
          eq(telemetryEvents.producerId, producerId),
          eq(telemetryEvents.runKey, runKey),
        ),
      )
      .orderBy(asc(telemetryEvents.eventSequence))
      .limit(limit)
      .offset(offset);
  }
}
