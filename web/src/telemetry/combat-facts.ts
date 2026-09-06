import type { TelemetryEvent } from "./types";

export type KillAttributionFact = {
  factId: string;
  producerId: string;
  runKey: string;
  targetAssetKey: string;
  targetDcsName: string | null;
  targetDcsType: string | null;
  targetCoalition: string | null;
  killerAssetKey: string | null;
  killerDcsName: string | null;
  killerDcsType: string | null;
  killerCoalition: string | null;
  killingBlowSimTime: number;
  killingBlowEventId: string;
  weaponDcsType: string | null;
  weaponCategory: string | null;
  sourceEventIds: string[];
};

export type AssistAttributionFact = {
  factId: string;
  producerId: string;
  runKey: string;
  targetAssetKey: string;
  attackerAssetKey: string;
  attackerDcsName: string | null;
  attackerDcsType: string | null;
  attackerCoalition: string | null;
  targetDcsName: string | null;
  targetDcsType: string | null;
  targetCoalition: string | null;
  representativeHitSimTime: number;
  representativeHitEventId: string;
  sourceEventIds: string[];
};

type OrderedEvent = {
  event: TelemetryEvent;
  target: Record<string, unknown>;
  targetAssetKey: string;
};

function objectOrNull(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function stringOrNull(
  value: Record<string, unknown> | null,
  field: string,
): string | null {
  const candidate = value?.[field];
  return typeof candidate === "string" && candidate.length > 0
    ? candidate
    : null;
}

function compareEvents(left: TelemetryEvent, right: TelemetryEvent): number {
  return (
    left.event_sequence - right.event_sequence ||
    left.sim_time - right.sim_time ||
    left.event_id.localeCompare(right.event_id)
  );
}

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

function incarnationKey(event: TelemetryEvent, targetAssetKey: string): string {
  return JSON.stringify([event.producer_id, event.run_key, targetAssetKey]);
}

function orderedUniqueEvents(events: readonly OrderedEvent[]): OrderedEvent[] {
  const byId = new Map<string, OrderedEvent>();
  for (const entry of events) {
    byId.set(entry.event.event_id, entry);
  }
  return [...byId.values()].sort((left, right) =>
    compareEvents(left.event, right.event),
  );
}

function killEventsByIncarnation(
  events: readonly TelemetryEvent[],
): Map<string, OrderedEvent[]> {
  const grouped = new Map<string, OrderedEvent[]>();
  for (const event of events) {
    if (event.event_type !== "asset.kill-reported") {
      continue;
    }
    const target = objectOrNull(event.target);
    const targetAssetKey = stringOrNull(target, "asset_key");
    if (target === null || targetAssetKey === null) {
      continue;
    }
    const key = incarnationKey(event, targetAssetKey);
    const existing = grouped.get(key) ?? [];
    existing.push({ event, target, targetAssetKey });
    grouped.set(key, existing);
  }
  for (const [key, groupedEvents] of grouped) {
    grouped.set(key, orderedUniqueEvents(groupedEvents));
  }
  return grouped;
}

/** Reconcile one primary attribution from the first reported kill per target. */
export function reconcileKillAttributions(
  events: readonly TelemetryEvent[],
): KillAttributionFact[] {
  const facts: KillAttributionFact[] = [];
  for (const kills of killEventsByIncarnation(events).values()) {
    const killingBlow = kills[0];
    if (!killingBlow) {
      continue;
    }
    const { event, target, targetAssetKey } = killingBlow;
    const initiator = objectOrNull(event.initiator);
    const killerAssetKey = stringOrNull(initiator, "asset_key");
    const weapon = objectOrNull(event.weapon);
    const sourceEventIds = kills.map((entry) => entry.event.event_id);
    facts.push({
      factId: JSON.stringify([
        "kill.attributed",
        event.producer_id,
        event.run_key,
        targetAssetKey,
        sourceEventIds,
      ]),
      producerId: event.producer_id,
      runKey: event.run_key,
      targetAssetKey,
      targetDcsName: stringOrNull(target, "dcs_name"),
      targetDcsType: stringOrNull(target, "dcs_type"),
      targetCoalition: stringOrNull(target, "coalition"),
      killerAssetKey,
      killerDcsName:
        killerAssetKey === null ? null : stringOrNull(initiator, "dcs_name"),
      killerDcsType:
        killerAssetKey === null ? null : stringOrNull(initiator, "dcs_type"),
      killerCoalition:
        killerAssetKey === null ? null : stringOrNull(initiator, "coalition"),
      killingBlowSimTime: event.sim_time,
      killingBlowEventId: event.event_id,
      weaponDcsType: stringOrNull(weapon, "dcs_type"),
      weaponCategory: stringOrNull(weapon, "category"),
      sourceEventIds,
    });
  }
  return facts.sort(
    (left, right) =>
      compareText(left.producerId, right.producerId) ||
      compareText(left.runKey, right.runKey) ||
      compareText(left.targetAssetKey, right.targetAssetKey),
  );
}

/** Reconcile qualifying hits in the inclusive 30-second pre-kill window. */
export function reconcileAssistAttributions(
  events: readonly TelemetryEvent[],
): AssistAttributionFact[] {
  const kills = killEventsByIncarnation(events);
  const qualifying = new Map<string, OrderedEvent[]>();

  for (const event of events) {
    if (event.event_type !== "asset.hit") {
      continue;
    }
    const target = objectOrNull(event.target);
    const targetAssetKey = stringOrNull(target, "asset_key");
    const initiator = objectOrNull(event.initiator);
    const attackerAssetKey = stringOrNull(initiator, "asset_key");
    if (
      target === null ||
      targetAssetKey === null ||
      attackerAssetKey === null
    ) {
      continue;
    }
    const targetKills = kills.get(incarnationKey(event, targetAssetKey));
    const killingBlow = targetKills?.[0]?.event;
    if (
      !killingBlow ||
      event.sim_time < killingBlow.sim_time - 30 ||
      event.sim_time > killingBlow.sim_time
    ) {
      continue;
    }
    const killerAssetKey = stringOrNull(
      objectOrNull(killingBlow.initiator),
      "asset_key",
    );
    if (attackerAssetKey === killerAssetKey) {
      continue;
    }
    const key = JSON.stringify([
      event.producer_id,
      event.run_key,
      targetAssetKey,
      attackerAssetKey,
    ]);
    const existing = qualifying.get(key) ?? [];
    existing.push({ event, target, targetAssetKey });
    qualifying.set(key, existing);
  }

  const facts: AssistAttributionFact[] = [];
  for (const hits of qualifying.values()) {
    const orderedHits = orderedUniqueEvents(hits);
    const representative = orderedHits[0];
    if (!representative) {
      continue;
    }
    const { event, target, targetAssetKey } = representative;
    const initiator = objectOrNull(event.initiator);
    const attackerAssetKey = stringOrNull(initiator, "asset_key");
    if (attackerAssetKey === null) {
      continue;
    }
    const sourceEventIds = orderedHits.map((entry) => entry.event.event_id);
    facts.push({
      factId: JSON.stringify([
        "assist.attributed",
        event.producer_id,
        event.run_key,
        targetAssetKey,
        attackerAssetKey,
        sourceEventIds,
      ]),
      producerId: event.producer_id,
      runKey: event.run_key,
      targetAssetKey,
      attackerAssetKey,
      attackerDcsName: stringOrNull(initiator, "dcs_name"),
      attackerDcsType: stringOrNull(initiator, "dcs_type"),
      attackerCoalition: stringOrNull(initiator, "coalition"),
      targetDcsName: stringOrNull(target, "dcs_name"),
      targetDcsType: stringOrNull(target, "dcs_type"),
      targetCoalition: stringOrNull(target, "coalition"),
      representativeHitSimTime: event.sim_time,
      representativeHitEventId: event.event_id,
      sourceEventIds,
    });
  }
  return facts.sort(
    (left, right) =>
      compareText(left.producerId, right.producerId) ||
      compareText(left.runKey, right.runKey) ||
      compareText(left.targetAssetKey, right.targetAssetKey) ||
      compareText(left.attackerAssetKey, right.attackerAssetKey),
  );
}
