import { and, asc, desc, eq, sql } from "drizzle-orm";

import { getDb } from "@/db/client";
import {
  assetLosses,
  assistAttributions,
  killAttributions,
  missionRuns,
  ordnanceExpenditures,
  runParticipants,
  telemetryEvents,
} from "@/db/schema";
import type { ExpenditureProjection } from "./expenditures";
import type {
  AssistAttributionFact,
  KillAttributionFact,
} from "./combat-facts";
import type { AssetLostFact } from "./losses";
import type { TelemetryEvent } from "./types";

export type RunRow = typeof missionRuns.$inferSelect;
export type EventRow = typeof telemetryEvents.$inferSelect;
export type ExpenditureRow = typeof ordnanceExpenditures.$inferSelect;
export type RunParticipantRow = typeof runParticipants.$inferSelect;
export type AssetLossRow = typeof assetLosses.$inferSelect;
export type KillAttributionRow = typeof killAttributions.$inferSelect;
export type AssistAttributionRow = typeof assistAttributions.$inferSelect;

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
  upsertAssetLoss(loss: AssetLostFact): Promise<void>;
  upsertKillAttribution(attribution: KillAttributionFact): Promise<void>;
  upsertAssistAttribution(attribution: AssistAttributionFact): Promise<void>;
  upsertRunParticipant(participant: RunParticipantUpsert): Promise<void>;
  listRuns(
    limit?: number,
    offset?: number,
    classification?: "test" | "historical" | null,
  ): Promise<RunRow[]>;
  getRunByRunKey(runKey: string): Promise<RunRow | null>;
  listEvents(
    producerId: string,
    runKey: string,
    limit: number,
    offset: number,
  ): Promise<EventRow[]>;
  listRunEvents(producerId: string, runKey: string): Promise<TelemetryEvent[]>;
  listExpenditures(
    producerId: string,
    runKey: string,
  ): Promise<ExpenditureRow[]>;
  listAssetLosses(producerId: string, runKey: string): Promise<AssetLossRow[]>;
  listKillAttributions(
    producerId: string,
    runKey: string,
  ): Promise<KillAttributionRow[]>;
  listAssistAttributions(
    producerId: string,
    runKey: string,
  ): Promise<AssistAttributionRow[]>;
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

  async upsertAssetLoss(loss: AssetLostFact): Promise<void> {
    await getDb()
      .insert(assetLosses)
      .values({
        factId: loss.factId,
        producerId: loss.producerId,
        runKey: loss.runKey,
        assetKey: loss.assetKey,
        aircraftDcsType: loss.dcsType,
        coalition: loss.coalition,
        catalogue: loss.catalogue,
        catalogueVersion: loss.catalogueVersion,
        unitCostCents: loss.unitCostCents,
        sourceEventIds: loss.sourceEventIds,
      })
      .onConflictDoUpdate({
        target: [
          assetLosses.producerId,
          assetLosses.runKey,
          assetLosses.assetKey,
        ],
        set: {
          factId: loss.factId,
          aircraftDcsType: loss.dcsType,
          coalition: loss.coalition,
          catalogue: loss.catalogue,
          catalogueVersion: loss.catalogueVersion,
          unitCostCents: loss.unitCostCents,
          sourceEventIds: loss.sourceEventIds,
          updatedAt: sql`now()`,
        },
        // A stale concurrent projection must not replace a fact supported by
        // a later, larger full-run snapshot.
        setWhere: sql`jsonb_array_length(EXCLUDED.source_event_ids) >= jsonb_array_length(${assetLosses.sourceEventIds})`,
      });
  }

  async upsertKillAttribution(attribution: KillAttributionFact): Promise<void> {
    await getDb()
      .insert(killAttributions)
      .values(attribution)
      .onConflictDoUpdate({
        target: [
          killAttributions.producerId,
          killAttributions.runKey,
          killAttributions.targetAssetKey,
        ],
        set: {
          factId: attribution.factId,
          targetDcsName: attribution.targetDcsName,
          targetDcsType: attribution.targetDcsType,
          targetCoalition: attribution.targetCoalition,
          killerAssetKey: attribution.killerAssetKey,
          killerDcsName: attribution.killerDcsName,
          killerDcsType: attribution.killerDcsType,
          killerCoalition: attribution.killerCoalition,
          killingBlowSimTime: attribution.killingBlowSimTime,
          killingBlowEventId: attribution.killingBlowEventId,
          weaponDcsType: attribution.weaponDcsType,
          weaponCategory: attribution.weaponCategory,
          sourceEventIds: attribution.sourceEventIds,
          updatedAt: sql`now()`,
        },
        setWhere: sql`jsonb_array_length(EXCLUDED.source_event_ids) >= jsonb_array_length(${killAttributions.sourceEventIds})`,
      });
  }

  async upsertAssistAttribution(
    attribution: AssistAttributionFact,
  ): Promise<void> {
    await getDb()
      .insert(assistAttributions)
      .values(attribution)
      .onConflictDoUpdate({
        target: [
          assistAttributions.producerId,
          assistAttributions.runKey,
          assistAttributions.targetAssetKey,
          assistAttributions.attackerAssetKey,
        ],
        set: {
          factId: attribution.factId,
          attackerDcsName: attribution.attackerDcsName,
          attackerDcsType: attribution.attackerDcsType,
          attackerCoalition: attribution.attackerCoalition,
          targetDcsName: attribution.targetDcsName,
          targetDcsType: attribution.targetDcsType,
          targetCoalition: attribution.targetCoalition,
          representativeHitSimTime: attribution.representativeHitSimTime,
          representativeHitEventId: attribution.representativeHitEventId,
          sourceEventIds: attribution.sourceEventIds,
          updatedAt: sql`now()`,
        },
        setWhere: sql`jsonb_array_length(EXCLUDED.source_event_ids) >= jsonb_array_length(${assistAttributions.sourceEventIds})`,
      });
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

  async listRuns(
    limit = 100,
    offset = 0,
    classification: "test" | "historical" | null = null,
  ): Promise<RunRow[]> {
    return getDb()
      .select()
      .from(missionRuns)
      .where(
        classification === null
          ? undefined
          : eq(missionRuns.runClassification, classification),
      )
      .orderBy(desc(missionRuns.updatedAt))
      .limit(limit)
      .offset(offset);
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

  async listRunEvents(
    producerId: string,
    runKey: string,
  ): Promise<TelemetryEvent[]> {
    const rows = await getDb()
      .select({ event: telemetryEvents.eventJson })
      .from(telemetryEvents)
      .where(
        and(
          eq(telemetryEvents.producerId, producerId),
          eq(telemetryEvents.runKey, runKey),
        ),
      )
      .orderBy(asc(telemetryEvents.eventSequence));
    return rows.map(({ event }) => event as TelemetryEvent);
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

  async listAssetLosses(
    producerId: string,
    runKey: string,
  ): Promise<AssetLossRow[]> {
    return getDb()
      .select()
      .from(assetLosses)
      .where(
        and(
          eq(assetLosses.producerId, producerId),
          eq(assetLosses.runKey, runKey),
        ),
      )
      .orderBy(asc(assetLosses.assetKey));
  }

  async listKillAttributions(
    producerId: string,
    runKey: string,
  ): Promise<KillAttributionRow[]> {
    return getDb()
      .select()
      .from(killAttributions)
      .where(
        and(
          eq(killAttributions.producerId, producerId),
          eq(killAttributions.runKey, runKey),
        ),
      )
      .orderBy(asc(killAttributions.targetAssetKey));
  }

  async listAssistAttributions(
    producerId: string,
    runKey: string,
  ): Promise<AssistAttributionRow[]> {
    return getDb()
      .select()
      .from(assistAttributions)
      .where(
        and(
          eq(assistAttributions.producerId, producerId),
          eq(assistAttributions.runKey, runKey),
        ),
      )
      .orderBy(
        asc(assistAttributions.targetAssetKey),
        asc(assistAttributions.attackerAssetKey),
      );
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
