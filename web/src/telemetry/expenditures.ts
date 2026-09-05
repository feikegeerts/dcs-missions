import type { OrdinanceCatalogue } from "./catalogue";
import { ordnanceCatalogueV1, resolveValuation } from "./catalogue";
import type { TelemetryEvent } from "./types";

export type CatalogueAssignment = {
  catalogue: string;
  version: number;
};

/**
 * The catalogue newly created runs are explicitly assigned. Only v1 exists
 * today; when a newer version is human-approved, this is the single place
 * that decides what new runs pin. Historical runs without an assignment
 * stay unassigned — assignment is never backfilled.
 */
export function currentOrdnanceAssignment(): CatalogueAssignment {
  return {
    catalogue: ordnanceCatalogueV1.catalogue,
    version: ordnanceCatalogueV1.version,
  };
}

/**
 * Resolve the pinned catalogue object for an assignment. Returns null for
 * unknown versions rather than pricing against the wrong catalogue: an
 * expenditure is never recorded with a mismatched value.
 */
export function catalogueForAssignment(
  assignment: CatalogueAssignment | null,
): OrdinanceCatalogue | null {
  if (assignment === null) {
    return null;
  }
  if (
    assignment.catalogue === ordnanceCatalogueV1.catalogue &&
    assignment.version === ordnanceCatalogueV1.version
  ) {
    return ordnanceCatalogueV1;
  }
  return null;
}

export type ExpenditureProjection = {
  sourceEventId: string;
  producerId: string;
  runKey: string;
  eventSequence: number;
  participantId: string | null;
  participantDisplayName: string | null;
  participantCallsign: string | null;
  assetKey: string | null;
  aircraftDcsType: string | null;
  coalition: string | null;
  weaponDcsType: string | null;
  weaponDisplayName: string | null;
  catalogue: string;
  catalogueVersion: number;
  unitCostCents: number | null;
};

export type ParticipantObservation = {
  producerId: string;
  runKey: string;
  participantId: string;
  displayName: string | null;
  callsign: string | null;
  coalition: string | null;
  eventSequence: number;
};

export type ParticipantLabel = {
  participantId: string;
  displayName: string | null;
  callsign: string | null;
};

export type ExpenditureGroup = {
  participantId: string | null;
  participantDisplayName: string | null;
  participantCallsign: string | null;
  assetKey: string | null;
  aircraftDcsType: string | null;
  coalition: string | null;
  weaponDcsType: string | null;
  weaponDisplayName: string | null;
  expenditureCount: number;
  knownSubtotalCents: number;
  unpricedCount: number;
  partial: boolean;
};

export type ExpenditureDrilldown = {
  expenditureCount: number;
  knownSubtotalCents: number;
  unpricedCount: number;
  partial: boolean;
  groups: ExpenditureGroup[];
};

export type WeaponRollup = {
  weaponDcsType: string | null;
  weaponDisplayName: string | null;
  expenditureCount: number;
  knownSubtotalCents: number;
  unpricedCount: number;
  partial: boolean;
};

export type WeaponSummary = {
  expenditureCount: number;
  knownSubtotalCents: number;
  unpricedCount: number;
  partial: boolean;
  weapons: WeaponRollup[];
};

type ExpenditureAggregateInput = ExpenditureProjection;

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

/** Convert a PostgreSQL-style USD decimal to exact integer cents. */
export function decimalUsdToCents(value: string): number {
  const match = /^(0|[1-9]\d*)(?:\.(\d{1,2}))?$/.exec(value);
  if (!match) {
    throw new Error(`Invalid USD decimal: ${value}`);
  }
  const cents =
    BigInt(match[1]) * 100n + BigInt((match[2] ?? "").padEnd(2, "0"));
  if (cents > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error("USD cent value exceeds JavaScript's exact integer range");
  }
  return Number(cents);
}

export function catalogueUsdToCents(value: number): number {
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error("Catalogue USD value must be positive and finite");
  }
  return decimalUsdToCents(value.toFixed(2));
}

export function participantObservation(
  event: TelemetryEvent,
): ParticipantObservation | null {
  const participant = objectOrNull(event.participant);
  if (stringOrNull(participant, "status") !== "known") {
    return null;
  }
  const participantId = stringOrNull(participant, "participant_id");
  if (participantId === null) {
    return null;
  }
  return {
    producerId: event.producer_id,
    runKey: event.run_key,
    participantId,
    displayName: stringOrNull(participant, "display_name"),
    callsign: stringOrNull(participant, "callsign"),
    coalition: stringOrNull(participant, "coalition"),
    eventSequence: event.event_sequence,
  };
}

export function deriveExpenditure(
  event: TelemetryEvent,
  assignment: CatalogueAssignment | null,
): ExpenditureProjection | null {
  if (event.event_type !== "ordnance.fired") {
    return null;
  }
  const catalogue = catalogueForAssignment(assignment);
  if (catalogue === null) {
    // Unassigned historical runs (and unknown future pins) project
    // nothing: no expenditure is better than a mispriced one.
    return null;
  }

  const participant = objectOrNull(event.participant);
  const initiator = objectOrNull(event.initiator);
  const asset = objectOrNull(event.asset);
  const weapon = objectOrNull(event.weapon);
  const participantId =
    stringOrNull(participant, "participant_id") ??
    stringOrNull(initiator, "participant_id");
  const weaponDcsType =
    stringOrNull(weapon, "status") === "known"
      ? stringOrNull(weapon, "dcs_type")
      : null;
  const valuation = resolveValuation(catalogue, weaponDcsType);

  return {
    sourceEventId: event.event_id,
    producerId: event.producer_id,
    runKey: event.run_key,
    eventSequence: event.event_sequence,
    participantId,
    participantDisplayName:
      stringOrNull(participant, "display_name") ??
      stringOrNull(initiator, "display_name"),
    participantCallsign:
      stringOrNull(participant, "callsign") ??
      stringOrNull(initiator, "callsign"),
    assetKey:
      stringOrNull(asset, "asset_key") ?? stringOrNull(initiator, "asset_key"),
    aircraftDcsType:
      stringOrNull(asset, "dcs_type") ?? stringOrNull(initiator, "dcs_type"),
    coalition: event.coalition,
    weaponDcsType,
    weaponDisplayName: stringOrNull(weapon, "display_name"),
    catalogue: catalogue.catalogue,
    catalogueVersion: catalogue.version,
    unitCostCents: valuation.priced
      ? catalogueUsdToCents(valuation.usdValue)
      : null,
  };
}

export function latestParticipantLabels(
  events: readonly TelemetryEvent[],
): Map<string, ParticipantLabel> {
  const observations = events
    .map(participantObservation)
    .filter((value): value is ParticipantObservation => value !== null)
    .sort((left, right) => left.eventSequence - right.eventSequence);
  const labels = new Map<
    string,
    ParticipantLabel & {
      displayNameSequence: number | null;
      callsignSequence: number | null;
    }
  >();
  for (const observation of observations) {
    const current = labels.get(observation.participantId) ?? {
      participantId: observation.participantId,
      displayName: null,
      callsign: null,
      displayNameSequence: null,
      callsignSequence: null,
    };
    if (observation.displayName !== null) {
      current.displayName = observation.displayName;
      current.displayNameSequence = observation.eventSequence;
    }
    if (observation.callsign !== null) {
      current.callsign = observation.callsign;
      current.callsignSequence = observation.eventSequence;
    }
    labels.set(observation.participantId, current);
  }
  return labels;
}

export function aggregateExpenditures(
  expenditures: readonly ExpenditureAggregateInput[],
  participantLabels: ReadonlyMap<string, ParticipantLabel> = new Map(),
): ExpenditureDrilldown {
  let knownSubtotalCents = 0;
  let unpricedCount = 0;
  const groups = new Map<
    string,
    ExpenditureGroup & { firstEventSequence: number }
  >();

  for (const expenditure of expenditures) {
    if (expenditure.unitCostCents === null) {
      unpricedCount += 1;
    } else {
      knownSubtotalCents = addCents(
        knownSubtotalCents,
        expenditure.unitCostCents,
      );
    }
    const key = JSON.stringify([
      expenditure.participantId,
      expenditure.assetKey,
      expenditure.aircraftDcsType,
      expenditure.coalition,
      expenditure.weaponDcsType,
    ]);
    let group = groups.get(key);
    if (!group) {
      const currentLabel = expenditure.participantId
        ? participantLabels.get(expenditure.participantId)
        : undefined;
      group = {
        participantId: expenditure.participantId,
        participantDisplayName:
          currentLabel?.displayName ?? expenditure.participantDisplayName,
        participantCallsign:
          currentLabel?.callsign ?? expenditure.participantCallsign,
        assetKey: expenditure.assetKey,
        aircraftDcsType: expenditure.aircraftDcsType,
        coalition: expenditure.coalition,
        weaponDcsType: expenditure.weaponDcsType,
        weaponDisplayName: expenditure.weaponDisplayName,
        expenditureCount: 0,
        knownSubtotalCents: 0,
        unpricedCount: 0,
        partial: false,
        firstEventSequence: expenditure.eventSequence,
      };
      groups.set(key, group);
    }
    group.expenditureCount += 1;
    if (expenditure.unitCostCents === null) {
      group.unpricedCount += 1;
      group.partial = true;
    } else {
      group.knownSubtotalCents = addCents(
        group.knownSubtotalCents,
        expenditure.unitCostCents,
      );
    }
  }

  return {
    expenditureCount: expenditures.length,
    knownSubtotalCents,
    unpricedCount,
    partial: unpricedCount > 0,
    groups: [...groups.values()]
      .sort((left, right) => left.firstEventSequence - right.firstEventSequence)
      .map((group) => {
        const rest: Record<string, unknown> = { ...group };
        delete rest.firstEventSequence;
        return rest as ExpenditureGroup;
      }),
  };
}

/**
 * Roll ordnance expenditures up by weapon type. Pure display helper for the
 * Slice 15 ordnance-by-type view: no catalogue lookup, no pricing, just exact
 * cent addition over already-projected rows. Unknown weapons stay grouped
 * under a null key and mark the totals partial.
 */
export function aggregateByWeapon(
  expenditures: readonly ExpenditureAggregateInput[],
): WeaponSummary {
  let knownSubtotalCents = 0;
  let unpricedCount = 0;
  const weapons = new Map<
    string,
    WeaponRollup & { firstEventSequence: number }
  >();

  for (const expenditure of expenditures) {
    if (expenditure.unitCostCents === null) {
      unpricedCount += 1;
    } else {
      knownSubtotalCents = addCents(
        knownSubtotalCents,
        expenditure.unitCostCents,
      );
    }
    const key = JSON.stringify([expenditure.weaponDcsType]);
    let rollup = weapons.get(key);
    if (!rollup) {
      rollup = {
        weaponDcsType: expenditure.weaponDcsType,
        weaponDisplayName: expenditure.weaponDisplayName,
        expenditureCount: 0,
        knownSubtotalCents: 0,
        unpricedCount: 0,
        partial: false,
        firstEventSequence: expenditure.eventSequence,
      };
      weapons.set(key, rollup);
    }
    rollup.expenditureCount += 1;
    if (expenditure.unitCostCents === null) {
      rollup.unpricedCount += 1;
      rollup.partial = true;
    } else {
      rollup.knownSubtotalCents = addCents(
        rollup.knownSubtotalCents,
        expenditure.unitCostCents,
      );
    }
    // Prefer a known display name when one appears for the same type.
    if (
      rollup.weaponDisplayName == null &&
      expenditure.weaponDisplayName != null
    ) {
      rollup.weaponDisplayName = expenditure.weaponDisplayName;
    }
  }

  return {
    expenditureCount: expenditures.length,
    knownSubtotalCents,
    unpricedCount,
    partial: unpricedCount > 0,
    weapons: [...weapons.values()]
      .sort((left, right) => left.firstEventSequence - right.firstEventSequence)
      .map((rollup) => {
        const rest: Record<string, unknown> = { ...rollup };
        delete rest.firstEventSequence;
        return rest as WeaponRollup;
      }),
  };
}
