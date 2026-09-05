import { and, asc, desc, eq, sql } from "drizzle-orm";

import { getDb } from "@/db/client";
import {
  missionRuns,
  ordnanceExpenditures,
  runParticipants,
  telemetryEvents,
} from "@/db/schema";
import type { ExpenditureProjection } from "./expenditures";
import type { TelemetryEvent } from "./types";

export type RunRow = typeof missionRuns.$inferSelect;
export type EventRow = typeof telemetryEvents.$inferSelect;
export type ExpenditureRow = typeof ordnanceExpenditures.$inferSelect;
export type RunParticipantRow = typeof runParticipants.$inferSelect;

export interface RunUpsertInput {
  producerId: string;
  runKey: string;
  missionName?: string | null;
  missionVersion?: string | null;
  mapName?: string | null;
  runClassification?: string | null;
  valuationCatalogue?: string | null;
  valuationCatalogueVersion?: number | null;
  firstSequence: number;
  lastSequence: number;
  acceptedDelta: number;
  startedAt?: string | null;
  endedAt?: string | null;
  status: "active" | "ended";
}

export interface RunParticipantUpsert {
  producerId: string;
  runKey: string;
  participantId: string;
  displayName: string | null;
  callsign: string | null;
  coalition: string | null;
  eventSequence: number;
}

export interface TelemetryStore {
  insertEvent(
    event: TelemetryEvent,
  ): Promise<"accepted" | "duplicate" | "rejected">;
  upsertRun(run: RunUpsertInput): Promise<void>;
  insertExpenditure(
    expenditure: ExpenditureProjection,
  ): Promise<"inserted" | "existing">;
  upsertRunParticipant(participant: RunParticipantUpsert): Promise<void>;
  listRuns(limit?: number): Promise<RunRow[]>;
  getRunByRunKey(runKey: string): Promise<RunRow | null>;
  listEvents(
    producerId: string,
    runKey: string,
    limit: number,
    offset: number,
  ): Promise<EventRow[]>;
  listExpenditures(
    producerId: string,
    runKey: string,
  ): Promise<ExpenditureRow[]>;
  listRunParticipants(
    producerId: string,
    runKey: string,
  ): Promise<RunParticipantRow[]>;
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
        valuationCatalogue: input.valuationCatalogue ?? null,
        valuationCatalogueVersion: input.valuationCatalogueVersion ?? null,
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
          // A run's catalogue assignment is pinned at creation and never
          // rewritten: existing assignments win, and runs that predate
          // catalogue assignment stay unassigned (no retroactive pricing).
          valuationCatalogue: sql`COALESCE(${missionRuns.valuationCatalogue}, EXCLUDED.valuation_catalogue)`,
          valuationCatalogueVersion: sql`COALESCE(${missionRuns.valuationCatalogueVersion}, EXCLUDED.valuation_catalogue_version)`,
          updatedAt: sql`now()`,
        },
      });
  }

  async insertExpenditure(
    expenditure: ExpenditureProjection,
  ): Promise<"inserted" | "existing"> {
    const rows = await getDb()
      .insert(ordnanceExpenditures)
      .values({
        sourceEventId: expenditure.sourceEventId,
        producerId: expenditure.producerId,
        runKey: expenditure.runKey,
        eventSequence: expenditure.eventSequence,
        participantId: expenditure.participantId,
        participantDisplayName: expenditure.participantDisplayName,
        participantCallsign: expenditure.participantCallsign,
        assetKey: expenditure.assetKey,
        aircraftDcsType: expenditure.aircraftDcsType,
        coalition: expenditure.coalition,
        weaponDcsType: expenditure.weaponDcsType,
        weaponDisplayName: expenditure.weaponDisplayName,
        catalogue: expenditure.catalogue,
        catalogueVersion: expenditure.catalogueVersion,
        unitCostCents: expenditure.unitCostCents,
      })
      .onConflictDoNothing({
        target: ordnanceExpenditures.sourceEventId,
      })
      .returning({ sourceEventId: ordnanceExpenditures.sourceEventId });
    return rows.length > 0 ? "inserted" : "existing";
  }

  async upsertRunParticipant(input: RunParticipantUpsert): Promise<void> {
    const db = getDb();
    await db
      .insert(runParticipants)
      .values({
        producerId: input.producerId,
        runKey: input.runKey,
        participantId: input.participantId,
        displayName: input.displayName,
        displayNameSequence:
          input.displayName != null ? input.eventSequence : null,
        callsign: input.callsign,
        callsignSequence: input.callsign != null ? input.eventSequence : null,
        coalition: input.coalition,
        latestEventSequence: input.eventSequence,
      })
      .onConflictDoUpdate({
        target: [
          runParticipants.producerId,
          runParticipants.runKey,
          runParticipants.participantId,
        ],
        set: {
          // Labels advance monotonically by event sequence: a replayed or
          // out-of-order observation never overwrites a newer label, and a
          // null label never clears a known one.
          displayName: sql`CASE WHEN EXCLUDED.display_name_sequence IS NOT NULL AND EXCLUDED.display_name_sequence >= COALESCE(${runParticipants.displayNameSequence}, -1) THEN EXCLUDED.display_name ELSE ${runParticipants.displayName} END`,
          displayNameSequence: sql`CASE WHEN EXCLUDED.display_name_sequence IS NOT NULL AND EXCLUDED.display_name_sequence >= COALESCE(${runParticipants.displayNameSequence}, -1) THEN EXCLUDED.display_name_sequence ELSE ${runParticipants.displayNameSequence} END`,
          callsign: sql`CASE WHEN EXCLUDED.callsign_sequence IS NOT NULL AND EXCLUDED.callsign_sequence >= COALESCE(${runParticipants.callsignSequence}, -1) THEN EXCLUDED.callsign ELSE ${runParticipants.callsign} END`,
          callsignSequence: sql`CASE WHEN EXCLUDED.callsign_sequence IS NOT NULL AND EXCLUDED.callsign_sequence >= COALESCE(${runParticipants.callsignSequence}, -1) THEN EXCLUDED.callsign_sequence ELSE ${runParticipants.callsignSequence} END`,
          coalition: sql`COALESCE(EXCLUDED.coalition, ${runParticipants.coalition})`,
          latestEventSequence: sql`GREATEST(${runParticipants.latestEventSequence}, EXCLUDED.latest_event_sequence)`,
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

  async listExpenditures(
    producerId: string,
    runKey: string,
  ): Promise<ExpenditureRow[]> {
    return getDb()
      .select()
      .from(ordnanceExpenditures)
      .where(
        and(
          eq(ordnanceExpenditures.producerId, producerId),
          eq(ordnanceExpenditures.runKey, runKey),
        ),
      )
      .orderBy(asc(ordnanceExpenditures.eventSequence));
  }

  async listRunParticipants(
    producerId: string,
    runKey: string,
  ): Promise<RunParticipantRow[]> {
    return getDb()
      .select()
      .from(runParticipants)
      .where(
        and(
          eq(runParticipants.producerId, producerId),
          eq(runParticipants.runKey, runKey),
        ),
      )
      .orderBy(asc(runParticipants.participantId));
  }
}
