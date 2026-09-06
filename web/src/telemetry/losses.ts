import { resolveValuation } from "./catalogue";
import {
  catalogueForAssignment,
  catalogueUsdToCents,
  type CatalogueAssignment,
} from "./expenditures";
import type { TelemetryEvent } from "./types";

export { currentOrdnanceAssignment } from "./expenditures";

export type AssetLostFact = {
  factId: string;
  producerId: string;
  runKey: string;
  assetKey: string;
  dcsType: string | null;
  coalition: string | null;
  catalogue: string;
  catalogueVersion: number;
  unitCostCents: number | null;
  sourceEventIds: string[];
};

export type AssetLossSummary = {
  lossCount: number;
  knownSubtotalCents: number;
  unpricedCount: number;
  partial: boolean;
};

type PendingLoss = {
  producerId: string;
  runKey: string;
  assetKey: string;
  dcsType: string | null;
  coalition: string | null;
  sourceEvents: Array<{ id: string; sequence: number }>;
  sourceEventIdSet: Set<string>;
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

function addCents(left: number, right: number): number {
  const result = left + right;
  if (!Number.isSafeInteger(result)) {
    throw new Error("USD cent total exceeds JavaScript's exact integer range");
  }
  return result;
}

function factIdFor(loss: PendingLoss, sourceEventIds: string[]): string {
  return JSON.stringify([
    "asset.lost",
    loss.producerId,
    loss.runKey,
    loss.assetKey,
    sourceEventIds,
  ]);
}

/**
 * Reconcile ordered source observations into one aircraft-loss fact per tracked
 * asset incarnation. Pilot outcomes and despawns remain separate observations.
 *
 * A loss is derived only from `asset.dead` and `asset.crashed`. `asset.despawned`
 * (any reason) and `pilot.*` events never create a fact. Incarnation identity is
 * the tracked `asset_key` (never a display name), so repeated signals for one
 * incarnation collapse to a single fact and a single charge. The fact identity is
 * canonical — its supporting event ids are sorted by `event_sequence` — so the
 * same source stream recreates the same identities and totals regardless of
 * arrival order.
 */
export function reconcileAssetLosts(
  events: readonly TelemetryEvent[],
  assignment: CatalogueAssignment | null,
): AssetLostFact[] {
  const catalogue = catalogueForAssignment(assignment);
  if (catalogue === null) {
    return [];
  }

  const pendingByIncarnation = new Map<string, PendingLoss>();
  for (const event of events) {
    if (
      event.event_type !== "asset.dead" &&
      event.event_type !== "asset.crashed"
    ) {
      continue;
    }

    const asset = objectOrNull(event.asset);
    if (stringOrNull(asset, "status") !== "known") {
      continue;
    }
    const assetKey = stringOrNull(asset, "asset_key");
    if (assetKey === null) {
      continue;
    }

    const incarnationKey = JSON.stringify([
      event.producer_id,
      event.run_key,
      assetKey,
    ]);
    let pending = pendingByIncarnation.get(incarnationKey);
    if (!pending) {
      pending = {
        producerId: event.producer_id,
        runKey: event.run_key,
        assetKey,
        dcsType: stringOrNull(asset, "dcs_type"),
        coalition: event.coalition,
        sourceEvents: [],
        sourceEventIdSet: new Set(),
      };
      pendingByIncarnation.set(incarnationKey, pending);
    }
    if (!pending.sourceEventIdSet.has(event.event_id)) {
      pending.sourceEvents.push({
        id: event.event_id,
        sequence: event.event_sequence,
      });
      pending.sourceEventIdSet.add(event.event_id);
    }
  }

  return [...pendingByIncarnation.values()].map((loss) => {
    const valuation = resolveValuation(catalogue, loss.dcsType);
    const orderedSourceEventIds = [...loss.sourceEvents]
      .sort((left, right) => left.sequence - right.sequence)
      .map((entry) => entry.id);
    return {
      factId: factIdFor(loss, orderedSourceEventIds),
      producerId: loss.producerId,
      runKey: loss.runKey,
      assetKey: loss.assetKey,
      dcsType: loss.dcsType,
      coalition: loss.coalition,
      catalogue: catalogue.catalogue,
      catalogueVersion: catalogue.version,
      unitCostCents: valuation.priced
        ? catalogueUsdToCents(valuation.usdValue)
        : null,
      sourceEventIds: orderedSourceEventIds,
    };
  });
}

export function aggregateAssetLosts(
  losses: readonly AssetLostFact[],
): AssetLossSummary {
  let knownSubtotalCents = 0;
  let unpricedCount = 0;
  for (const loss of losses) {
    if (loss.unitCostCents === null) {
      unpricedCount += 1;
    } else {
      knownSubtotalCents = addCents(knownSubtotalCents, loss.unitCostCents);
    }
  }
  return {
    lossCount: losses.length,
    knownSubtotalCents,
    unpricedCount,
    partial: unpricedCount > 0,
  };
}
