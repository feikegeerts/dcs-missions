/**
 * Mission Control dashboard aggregation.
 *
 * Pure helpers shared by the mission catalog, mission dossier, run
 * scoreboard, and player profiles. No I/O, no store access — safe to unit
 * test offline.
 *
 * Identity rules (reviewed):
 * - UCID (`participant_id`) is the underlying human identity; in-game names
 *   are display labels only.
 * - AI combatants are run-scoped asset incarnations: each `asset_key` is a
 *   distinct entry and never receives a cross-run career profile.
 * - A missing UCID is never proof of AI control. Named-but-unresolved
 *   shooter observations stay visible in the run and out of career totals.
 * - Asset-to-owner attribution prefers explicit expenditure linkage
 *   (`asset_key` fired under a UCID). Sortie-slot correlation applies only
 *   when exactly one distinct UCID occupied that slot DCS name during the
 *   run; shared slots stay unattributed rather than guessed.
 * - Costs are summed in exact cents; only presentation rounds to whole
 *   dollars.
 */

import { createHash } from "node:crypto";

import { buildAiCallsigns, type AiCallsignMap } from "./ai-names";
import type { TelemetryEvent } from "./types";

/** Dashboard reads cap a single scope at this many runs. Totals always cover
 * the full scope, never just the displayed page. At current single-server
 * volumes this is one indexed query; revisit with summary tables if run
 * volume ever makes the fan-out expensive. */
export const DASHBOARD_RUN_SCOPE_LIMIT = 1000;

/** Maximum runs listed on one dossier page. Aggregates ignore pagination. */
export const DOSSIER_RUNS_PER_PAGE = 20;

/** Whole-dollar presentation: exact cents in, `$12,450` out. */
export function formatWholeUsd(cents: number): string {
  if (!Number.isSafeInteger(cents)) {
    throw new Error("USD cent value must be a safe integer");
  }
  const dollars = Math.round(cents / 100);
  return `$${dollars.toLocaleString("en-US")}`;
}

/** Nullable cost presentation. Missing pricing is "unavailable", never $0. */
export function formatCostCents(cents: number | null): string {
  return cents === null ? "unavailable" : formatWholeUsd(cents);
}

/**
 * Known-subtotal presentation. A partial total names its coverage gap; a
 * fully unpriced bucket reports unavailable instead of a misleading $0.
 */
export function formatPartialCost(
  knownCents: number,
  unpricedCount: number,
): string {
  if (unpricedCount > 0 && knownCents === 0) {
    return `${unpricedCount} unpriced · value unavailable`;
  }
  if (unpricedCount > 0) {
    return `${formatWholeUsd(knownCents)} + ${unpricedCount} unpriced`;
  }
  return formatWholeUsd(knownCents);
}

export type CoalitionKey = "blue" | "red";

/** Blue/red pass through; neutral, null, and anything else sort into the
 * shared "other" bucket instead of being forced onto a side. */
export function normalizeCoalition(value: unknown): CoalitionKey | null {
  return value === "blue" ? "blue" : value === "red" ? "red" : null;
}

export type MissionCatalogEntry = {
  key: string;
  title: string;
  description: string;
};

const KNOWN_MISSIONS: Record<string, { title: string; description: string }> = {
  "duel-dynamic": {
    title: "Duel Dynamic",
    description:
      "1–4 player aircraft versus a matching AI package wave, respawned as one package 30 seconds after each wipe.",
  },
};

function titleizeMissionKey(key: string): string {
  return key
    .split(/[-_]+/)
    .filter((word) => word.length > 0)
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join(" ");
}

export function missionCatalogEntry(
  missionName: string | null | undefined,
): MissionCatalogEntry {
  if (missionName === null || missionName === undefined || missionName === "") {
    return {
      key: "unknown",
      title: "Unknown mission",
      description: "Runs recorded without a mission name.",
    };
  }
  const known = KNOWN_MISSIONS[missionName];
  if (known) {
    return {
      key: missionName,
      title: known.title,
      description: known.description,
    };
  }
  return {
    key: missionName,
    title: titleizeMissionKey(missionName),
    description: `Runs recorded under mission name “${missionName}”.`,
  };
}

export type MissionGroup<T> = {
  entry: MissionCatalogEntry;
  runs: T[];
  latestUpdatedAt: string | null;
};

function missionGroupKey(missionName: string | null | undefined): string {
  return missionName === null || missionName === undefined || missionName === ""
    ? "unknown"
    : missionName;
}

/** Group runs by exact mission name. Sorted by latest activity, newest first. */
export function groupRunsByMission<
  T extends { missionName: string | null; updatedAt: string | Date },
>(runs: readonly T[]): Array<MissionGroup<T>> {
  const groups = new Map<string, MissionGroup<T>>();
  for (const run of runs) {
    const key = missionGroupKey(run.missionName);
    let group = groups.get(key);
    if (!group) {
      group = {
        entry: missionCatalogEntry(run.missionName),
        runs: [],
        latestUpdatedAt: null,
      };
      groups.set(key, group);
    }
    group.runs.push(run);
    const updatedAt =
      run.updatedAt instanceof Date
        ? run.updatedAt.toISOString()
        : run.updatedAt;
    if (group.latestUpdatedAt === null || updatedAt > group.latestUpdatedAt) {
      group.latestUpdatedAt = updatedAt;
    }
  }
  return [...groups.values()].sort((left, right) =>
    (right.latestUpdatedAt ?? "").localeCompare(left.latestUpdatedAt ?? ""),
  );
}

/**
 * Opaque public player identifier. The raw UCID never appears in URLs or
 * markup; the hash is deterministic so the same UCID always resolves to the
 * same profile without a lookup table.
 */
export function publicPlayerIdFor(ucid: string): string {
  return `p-${createHash("sha256").update(`dcs-player:${ucid}`).digest("hex").slice(0, 16)}`;
}

function addCents(left: number, right: number): number {
  const result = left + right;
  if (!Number.isSafeInteger(result)) {
    throw new Error("USD cent total exceeds JavaScript's exact integer range");
  }
  return result;
}

export type ScoreboardParticipantInput = {
  participantId: string;
  displayName: string | null;
  callsign: string | null;
  coalition: string | null;
  latestEventSequence?: number;
};

export type ScoreboardExpenditureInput = {
  participantId: string | null;
  participantDisplayName: string | null;
  assetKey: string | null;
  aircraftDcsType: string | null;
  coalition: string | null;
  unitCostCents: number | null;
};

export type ScoreboardLossInput = {
  assetKey: string;
  aircraftDcsType: string | null;
  coalition: string | null;
  unitCostCents: number | null;
};

export type ScoreboardKillInput = {
  targetAssetKey: string;
  targetCoalition: string | null;
  targetDcsName: string | null;
  targetDcsType: string | null;
  killerAssetKey: string | null;
  killerCoalition: string | null;
  killerDcsName: string | null;
  killerDcsType: string | null;
};

export type ScoreboardAssistInput = {
  targetAssetKey: string;
  attackerAssetKey: string;
  attackerCoalition: string | null;
  attackerDcsName: string | null;
  attackerDcsType: string | null;
};

export type ScoreboardAssetInput = {
  assetKey: string;
  dcsName: string | null;
  dcsType: string | null;
  coalition: string | null;
};

export type ScoreboardSortieInput = {
  participantId: string | null;
  slotDcsName: string;
};

export type ScoreboardRow = {
  kind: "human" | "ai" | "unresolved";
  key: string;
  participantId: string | null;
  publicPlayerId: string | null;
  displayName: string;
  callsign: string | null;
  coalition: CoalitionKey | null;
  aircraft: string | null;
  assetKeys: string[];
  kills: number;
  friendlyKills: number;
  losses: number;
  assists: number;
  shots: number;
  ordnanceCostCents: number;
  ordnanceUnpriced: number;
  aircraftLossCents: number;
  aircraftUnpriced: number;
  totalCents: number;
  totalUnpriced: number;
  partial: boolean;
};

export type CoalitionTotals = {
  kills: number;
  friendlyKills: number;
  losses: number;
  assists: number;
  shots: number;
  ordnanceCents: number;
  ordnanceUnpriced: number;
  aircraftCents: number;
  aircraftUnpriced: number;
  totalCents: number;
  partial: boolean;
};

export type RunScoreboard = {
  blue: CoalitionTotals;
  red: CoalitionTotals;
  unattributedKills: number;
  unattributedLosses: number;
  unattributedShots: number;
  humans: ScoreboardRow[];
  ai: ScoreboardRow[];
  unresolved: ScoreboardRow[];
};

function emptyTotals(): CoalitionTotals {
  return {
    kills: 0,
    friendlyKills: 0,
    losses: 0,
    assists: 0,
    shots: 0,
    ordnanceCents: 0,
    ordnanceUnpriced: 0,
    aircraftCents: 0,
    aircraftUnpriced: 0,
    totalCents: 0,
    partial: false,
  };
}

function emptyRow(init: {
  kind: ScoreboardRow["kind"];
  key: string;
  participantId: string | null;
  displayName: string;
  callsign: string | null;
  coalition: CoalitionKey | null;
}): ScoreboardRow {
  return {
    ...init,
    publicPlayerId:
      init.participantId === null
        ? null
        : publicPlayerIdFor(init.participantId),
    aircraft: null,
    assetKeys: [],
    kills: 0,
    friendlyKills: 0,
    losses: 0,
    assists: 0,
    shots: 0,
    ordnanceCostCents: 0,
    ordnanceUnpriced: 0,
    aircraftLossCents: 0,
    aircraftUnpriced: 0,
    totalCents: 0,
    totalUnpriced: 0,
    partial: false,
  };
}

function refreshRowTotals(row: ScoreboardRow): void {
  row.totalCents = addCents(row.ordnanceCostCents, row.aircraftLossCents);
  row.totalUnpriced = row.ordnanceUnpriced + row.aircraftUnpriced;
  row.partial = row.totalUnpriced > 0;
}

function addOrdnanceToTotals(
  totals: CoalitionTotals,
  unitCostCents: number | null,
): void {
  if (unitCostCents === null) {
    totals.ordnanceUnpriced += 1;
  } else {
    totals.ordnanceCents = addCents(totals.ordnanceCents, unitCostCents);
  }
  totals.shots += 1;
  totals.totalCents = addCents(totals.ordnanceCents, totals.aircraftCents);
  totals.partial = totals.ordnanceUnpriced + totals.aircraftUnpriced > 0;
}

function addAircraftToTotals(
  totals: CoalitionTotals,
  unitCostCents: number | null,
): void {
  if (unitCostCents === null) {
    totals.aircraftUnpriced += 1;
  } else {
    totals.aircraftCents = addCents(totals.aircraftCents, unitCostCents);
  }
  totals.losses += 1;
  totals.totalCents = addCents(totals.ordnanceCents, totals.aircraftCents);
  totals.partial = totals.ordnanceUnpriced + totals.aircraftUnpriced > 0;
}

function addAircraftToRow(row: ScoreboardRow, dcsType: string | null): void {
  if (row.aircraft === null && dcsType !== null) {
    row.aircraft = dcsType;
  }
}

function trackAsset(row: ScoreboardRow, assetKey: string | null): void {
  if (assetKey !== null && !row.assetKeys.includes(assetKey)) {
    row.assetKeys.push(assetKey);
  }
}

function compareRows(left: ScoreboardRow, right: ScoreboardRow): number {
  return (
    right.kills - left.kills ||
    left.losses - right.losses ||
    right.assists - left.assists ||
    left.displayName.localeCompare(right.displayName)
  );
}

function aiLabel(input: {
  dcsName: string | null;
  dcsType: string | null;
  assetKey: string;
}): string {
  if (input.dcsName !== null && input.dcsName !== "") {
    return input.dcsName;
  }
  if (input.dcsType !== null && input.dcsType !== "") {
    return `${input.dcsType} · ${input.assetKey}`;
  }
  return input.assetKey;
}

function assetKeysForCallsigns(input: BuildScoreboardInput): string[] {
  const keys: string[] = [];
  const add = (assetKey: string | null | undefined) => {
    if (assetKey !== null && assetKey !== undefined && assetKey !== "") {
      keys.push(assetKey);
    }
  };
  for (const asset of input.assets) {
    add(asset.assetKey);
  }
  for (const expenditure of input.expenditures) {
    add(expenditure.assetKey);
  }
  for (const loss of input.losses) {
    add(loss.assetKey);
  }
  for (const kill of input.kills) {
    add(kill.targetAssetKey);
    add(kill.killerAssetKey);
  }
  for (const assist of input.assists) {
    add(assist.targetAssetKey);
    add(assist.attackerAssetKey);
  }
  return keys;
}

export type BuildScoreboardInput = {
  runKey?: string;
  aiCallsigns?: AiCallsignMap;
  participants: readonly ScoreboardParticipantInput[];
  expenditures: readonly ScoreboardExpenditureInput[];
  losses: readonly ScoreboardLossInput[];
  kills: readonly ScoreboardKillInput[];
  assists: readonly ScoreboardAssistInput[];
  assets: readonly ScoreboardAssetInput[];
  sorties: readonly ScoreboardSortieInput[];
};

/**
 * Build one run's blue/red scoreboard.
 *
 * Every tracked combatant appears: UCID humans (one row per coalition when a
 * side switch is observed), AI asset incarnations (including zero-action
 * spawns), and named-but-unresolved shooters. Unknown killers and
 * unowned losses count toward coalition/unattributed buckets without being
 * assigned to a person or aircraft.
 */
export function buildRunScoreboard(input: BuildScoreboardInput): RunScoreboard {
  const blue = emptyTotals();
  const red = emptyTotals();
  const totalsFor = (coalition: CoalitionKey | null): CoalitionTotals | null =>
    coalition === "blue" ? blue : coalition === "red" ? red : null;

  // Asset ownership: explicit expenditure linkage first. Sortie-slot
  // correlation only when one distinct UCID occupied that slot DCS name.
  const ownerByAsset = new Map<string, string>();
  for (const expenditure of input.expenditures) {
    if (expenditure.assetKey !== null && expenditure.participantId !== null) {
      const existing = ownerByAsset.get(expenditure.assetKey);
      if (existing === undefined) {
        ownerByAsset.set(expenditure.assetKey, expenditure.participantId);
      }
    }
  }
  const occupantsBySlot = new Map<string, Set<string>>();
  for (const sortie of input.sorties) {
    if (sortie.participantId === null || sortie.slotDcsName === "") {
      continue;
    }
    let occupants = occupantsBySlot.get(sortie.slotDcsName);
    if (!occupants) {
      occupants = new Set<string>();
      occupantsBySlot.set(sortie.slotDcsName, occupants);
    }
    occupants.add(sortie.participantId);
  }
  const slotOwner = new Map<string, string>();
  for (const [slot, occupants] of occupantsBySlot) {
    if (occupants.size === 1) {
      const sole = [...occupants][0];
      if (sole !== undefined) {
        slotOwner.set(slot, sole);
      }
    }
  }

  const assetByKey = new Map<string, ScoreboardAssetInput>();
  for (const asset of input.assets) {
    const existing = assetByKey.get(asset.assetKey);
    if (!existing) {
      assetByKey.set(asset.assetKey, asset);
      continue;
    }
    assetByKey.set(asset.assetKey, {
      assetKey: asset.assetKey,
      dcsName: existing.dcsName ?? asset.dcsName,
      dcsType: existing.dcsType ?? asset.dcsType,
      coalition: existing.coalition ?? asset.coalition,
    });
  }

  const humans = new Map<string, ScoreboardRow>();
  const ai = new Map<string, ScoreboardRow>();
  const unresolved = new Map<string, ScoreboardRow>();
  const aiCallsigns =
    input.aiCallsigns ??
    buildAiCallsigns(input.runKey ?? "dashboard", assetKeysForCallsigns(input));

  const humanRow = (
    participantId: string,
    coalition: CoalitionKey | null,
    fallbackName: string | null,
  ): ScoreboardRow => {
    const key = `${participantId}|${coalition ?? "other"}`;
    let row = humans.get(key);
    if (!row) {
      row = emptyRow({
        kind: "human",
        key,
        participantId,
        displayName: fallbackName ?? participantId,
        callsign: null,
        coalition,
      });
      humans.set(key, row);
    }
    return row;
  };

  const aiRow = (
    assetKey: string,
    coalition: CoalitionKey | null,
    label: { dcsName: string | null; dcsType: string | null },
  ): ScoreboardRow => {
    let row = ai.get(assetKey);
    if (!row) {
      row = emptyRow({
        kind: "ai",
        key: `asset:${assetKey}`,
        participantId: null,
        displayName:
          aiCallsigns.get(assetKey) ?? aiLabel({ ...label, assetKey }),
        callsign: null,
        coalition,
      });
      ai.set(assetKey, row);
    } else if (row.coalition === null && coalition !== null) {
      row.coalition = coalition;
    }
    if (
      row.displayName === assetKey &&
      (label.dcsName ?? label.dcsType) !== null
    ) {
      row.displayName = aiLabel({ ...label, assetKey });
    }
    return row;
  };

  const unresolvedRow = (
    displayName: string,
    coalition: CoalitionKey | null,
  ): ScoreboardRow => {
    const key = `${displayName}|${coalition ?? "other"}`;
    let row = unresolved.get(key);
    if (!row) {
      row = emptyRow({
        kind: "unresolved",
        key,
        participantId: null,
        displayName,
        callsign: null,
        coalition,
      });
      unresolved.set(key, row);
    }
    return row;
  };

  const ownerOf = (assetKey: string | null): string | null => {
    if (assetKey === null) {
      return null;
    }
    const direct = ownerByAsset.get(assetKey);
    if (direct !== undefined) {
      return direct;
    }
    const snapshot = assetByKey.get(assetKey);
    const slotName = snapshot?.dcsName ?? null;
    if (slotName === null) {
      return null;
    }
    return slotOwner.get(slotName) ?? null;
  };

  const humanRowForOwner = (
    owner: string,
    coalition: CoalitionKey | null,
    fallbackName: string | null,
  ): ScoreboardRow => {
    const exact = humans.get(`${owner}|${coalition ?? "other"}`);
    if (exact) {
      return exact;
    }
    // A side switch renders on its own coalition row: each side keeps only
    // the statistics observed under its own colors.
    if (coalition !== null) {
      const unplaced = [...humans.values()].find(
        (row) => row.participantId === owner && row.coalition === null,
      );
      if (unplaced) {
        humans.delete(unplaced.key);
        unplaced.coalition = coalition;
        unplaced.key = `${owner}|${coalition}`;
        humans.set(unplaced.key, unplaced);
        return unplaced;
      }
      return humanRow(owner, coalition, fallbackName);
    }
    const anyCoalition = [...humans.values()].find(
      (row) => row.participantId === owner,
    );
    return anyCoalition ?? humanRow(owner, coalition, fallbackName);
  };

  // Anchor every recorded human so zero-action participants still appear.
  for (const participant of input.participants) {
    const coalition = normalizeCoalition(participant.coalition);
    const row = humanRow(
      participant.participantId,
      coalition,
      participant.displayName,
    );
    if (
      participant.displayName !== null &&
      (row.displayName === participant.participantId || row.displayName === "")
    ) {
      row.displayName = participant.displayName;
    }
    if (row.callsign === null && participant.callsign !== null) {
      row.callsign = participant.callsign;
    }
    if (row.coalition === null && coalition !== null) {
      row.coalition = coalition;
    }
  }

  // Anchor every tracked asset incarnation, including zero-action spawns.
  for (const asset of assetByKey.values()) {
    if (ownerOf(asset.assetKey) !== null) {
      continue;
    }
    const row = aiRow(
      asset.assetKey,
      normalizeCoalition(asset.coalition),
      asset,
    );
    addAircraftToRow(row, asset.dcsType);
    trackAsset(row, asset.assetKey);
  }

  // Expenditures: shots and ordnance cost.
  let unattributedShots = 0;
  for (const expenditure of input.expenditures) {
    const coalition = normalizeCoalition(expenditure.coalition);
    const totals = totalsFor(coalition);
    if (totals) {
      addOrdnanceToTotals(totals, expenditure.unitCostCents);
    } else {
      unattributedShots += 1;
    }
    const owner = expenditure.participantId ?? ownerOf(expenditure.assetKey);
    if (owner !== null) {
      const row = humanRowForOwner(
        owner,
        coalition,
        expenditure.participantId !== null
          ? expenditure.participantDisplayName
          : null,
      );
      row.shots += 1;
      if (expenditure.unitCostCents === null) {
        row.ordnanceUnpriced += 1;
      } else {
        row.ordnanceCostCents = addCents(
          row.ordnanceCostCents,
          expenditure.unitCostCents,
        );
      }
      addAircraftToRow(row, expenditure.aircraftDcsType);
      trackAsset(row, expenditure.assetKey);
      refreshRowTotals(row);
      continue;
    }
    if (expenditure.assetKey !== null) {
      const snapshot = assetByKey.get(expenditure.assetKey);
      const row = aiRow(expenditure.assetKey, coalition, {
        dcsName: snapshot?.dcsName ?? null,
        dcsType: snapshot?.dcsType ?? expenditure.aircraftDcsType ?? null,
      });
      row.shots += 1;
      if (expenditure.unitCostCents === null) {
        row.ordnanceUnpriced += 1;
      } else {
        row.ordnanceCostCents = addCents(
          row.ordnanceCostCents,
          expenditure.unitCostCents,
        );
      }
      addAircraftToRow(row, expenditure.aircraftDcsType);
      trackAsset(row, expenditure.assetKey);
      refreshRowTotals(row);
      continue;
    }
    const displayName = expenditure.participantDisplayName;
    if (displayName !== null && displayName !== "") {
      const row = unresolvedRow(displayName, coalition);
      row.shots += 1;
      if (expenditure.unitCostCents === null) {
        row.ordnanceUnpriced += 1;
      } else {
        row.ordnanceCostCents = addCents(
          row.ordnanceCostCents,
          expenditure.unitCostCents,
        );
      }
      refreshRowTotals(row);
      continue;
    }
    unattributedShots += 1;
  }

  // Losses: aircraft destroyed or crashed — never pilot deaths.
  let unattributedLosses = 0;
  for (const loss of input.losses) {
    const coalition = normalizeCoalition(loss.coalition);
    const totals = totalsFor(coalition);
    if (totals) {
      addAircraftToTotals(totals, loss.unitCostCents);
    } else {
      unattributedLosses += 1;
    }
    const owner = ownerOf(loss.assetKey);
    if (owner !== null) {
      const row = humanRowForOwner(owner, coalition, null);
      row.losses += 1;
      if (loss.unitCostCents === null) {
        row.aircraftUnpriced += 1;
      } else {
        row.aircraftLossCents = addCents(
          row.aircraftLossCents,
          loss.unitCostCents,
        );
      }
      addAircraftToRow(row, loss.aircraftDcsType);
      trackAsset(row, loss.assetKey);
      refreshRowTotals(row);
      continue;
    }
    const snapshot = assetByKey.get(loss.assetKey);
    const row = aiRow(loss.assetKey, coalition, {
      dcsName: snapshot?.dcsName ?? null,
      dcsType: snapshot?.dcsType ?? loss.aircraftDcsType ?? null,
    });
    row.losses += 1;
    if (loss.unitCostCents === null) {
      row.aircraftUnpriced += 1;
    } else {
      row.aircraftLossCents = addCents(
        row.aircraftLossCents,
        loss.unitCostCents,
      );
    }
    addAircraftToRow(row, loss.aircraftDcsType);
    trackAsset(row, loss.assetKey);
    refreshRowTotals(row);
  }

  // Kills: one primary attacker per destroyed asset. Friendly fire stays
  // flagged on the row and the coalition total instead of reading as
  // hostile success.
  let unattributedKills = 0;
  for (const kill of input.kills) {
    const killerCoalition = normalizeCoalition(kill.killerCoalition);
    const targetCoalition = normalizeCoalition(kill.targetCoalition);
    const totals = totalsFor(killerCoalition);
    const friendly =
      killerCoalition !== null && killerCoalition === targetCoalition;
    if (totals) {
      totals.kills += 1;
      if (friendly) {
        totals.friendlyKills += 1;
      }
    } else {
      unattributedKills += 1;
    }
    if (kill.killerAssetKey === null) {
      continue;
    }
    const owner = ownerOf(kill.killerAssetKey);
    if (owner !== null) {
      const row = humanRowForOwner(owner, killerCoalition, null);
      row.kills += 1;
      if (friendly) {
        row.friendlyKills += 1;
      }
      addAircraftToRow(row, kill.killerDcsType);
      trackAsset(row, kill.killerAssetKey);
      refreshRowTotals(row);
      continue;
    }
    const snapshot = assetByKey.get(kill.killerAssetKey);
    const row = aiRow(kill.killerAssetKey, killerCoalition, {
      dcsName: snapshot?.dcsName ?? kill.killerDcsName ?? null,
      dcsType: snapshot?.dcsType ?? kill.killerDcsType ?? null,
    });
    row.kills += 1;
    if (friendly) {
      row.friendlyKills += 1;
    }
    addAircraftToRow(row, kill.killerDcsType);
    trackAsset(row, kill.killerAssetKey);
    refreshRowTotals(row);
  }

  // Ensure every kill target exists as a roster entry so victims without a
  // separate loss projection still appear.
  for (const kill of input.kills) {
    if (ownerOf(kill.targetAssetKey) !== null) {
      continue;
    }
    if (ai.has(kill.targetAssetKey)) {
      continue;
    }
    const snapshot = assetByKey.get(kill.targetAssetKey);
    const row = aiRow(
      kill.targetAssetKey,
      normalizeCoalition(kill.targetCoalition),
      {
        dcsName: snapshot?.dcsName ?? kill.targetDcsName ?? null,
        dcsType: snapshot?.dcsType ?? kill.targetDcsType ?? null,
      },
    );
    addAircraftToRow(row, kill.targetDcsType);
    trackAsset(row, kill.targetAssetKey);
  }

  // Assists: qualifying contributors who were not the primary killer.
  for (const assist of input.assists) {
    const attackerCoalition = normalizeCoalition(assist.attackerCoalition);
    const totals = totalsFor(attackerCoalition);
    if (totals) {
      totals.assists += 1;
    }
    const owner = ownerOf(assist.attackerAssetKey);
    if (owner !== null) {
      const row = humanRowForOwner(owner, attackerCoalition, null);
      row.assists += 1;
      addAircraftToRow(row, assist.attackerDcsType);
      trackAsset(row, assist.attackerAssetKey);
      continue;
    }
    const snapshot = assetByKey.get(assist.attackerAssetKey);
    const row = aiRow(assist.attackerAssetKey, attackerCoalition, {
      dcsName: snapshot?.dcsName ?? assist.attackerDcsName ?? null,
      dcsType: snapshot?.dcsType ?? assist.attackerDcsType ?? null,
    });
    row.assists += 1;
    addAircraftToRow(row, assist.attackerDcsType);
    trackAsset(row, assist.attackerAssetKey);
  }

  // Drop human-anchored AI placeholders: assets owned by a human render on
  // the human row only.
  for (const [assetKey, row] of [...ai]) {
    if (
      ownerOf(assetKey) !== null &&
      row.kills === 0 &&
      row.losses === 0 &&
      row.assists === 0 &&
      row.shots === 0
    ) {
      ai.delete(assetKey);
    }
  }

  return {
    blue,
    red,
    unattributedKills,
    unattributedLosses,
    unattributedShots,
    humans: [...humans.values()].sort(compareRows),
    ai: [...ai.values()].sort(compareRows),
    unresolved: [...unresolved.values()].sort(compareRows),
  };
}

export type RunCombatSummary = {
  blueKills: number;
  redKills: number;
  friendlyKills: number;
  unattributedKills: number;
  lossCount: number;
  shots: number;
  ordnanceCents: number;
  ordnanceUnpriced: number;
  aircraftCents: number;
  aircraftUnpriced: number;
  totalCents: number;
  partial: boolean;
};

/** Lightweight per-run combat rollup for dossier lists: no roster, no
 * ownership inference — just coalition kill counts and exact-cent costs. */
export function summarizeRunCombat(input: {
  expenditures: readonly ScoreboardExpenditureInput[];
  losses: readonly ScoreboardLossInput[];
  kills: readonly ScoreboardKillInput[];
}): RunCombatSummary {
  let blueKills = 0;
  let redKills = 0;
  let friendlyKills = 0;
  let unattributedKills = 0;
  let shots = 0;
  let ordnanceCents = 0;
  let ordnanceUnpriced = 0;
  let aircraftCents = 0;
  let aircraftUnpriced = 0;
  for (const expenditure of input.expenditures) {
    shots += 1;
    if (expenditure.unitCostCents === null) {
      ordnanceUnpriced += 1;
    } else {
      ordnanceCents = addCents(ordnanceCents, expenditure.unitCostCents);
    }
  }
  for (const loss of input.losses) {
    if (loss.unitCostCents === null) {
      aircraftUnpriced += 1;
    } else {
      aircraftCents = addCents(aircraftCents, loss.unitCostCents);
    }
  }
  for (const kill of input.kills) {
    const killer = normalizeCoalition(kill.killerCoalition);
    if (killer === "blue") {
      blueKills += 1;
    } else if (killer === "red") {
      redKills += 1;
    } else {
      unattributedKills += 1;
    }
    if (
      killer !== null &&
      killer === normalizeCoalition(kill.targetCoalition)
    ) {
      friendlyKills += 1;
    }
  }
  const totalCents = addCents(ordnanceCents, aircraftCents);
  return {
    blueKills,
    redKills,
    friendlyKills,
    unattributedKills,
    lossCount: input.losses.length,
    shots,
    ordnanceCents,
    ordnanceUnpriced,
    aircraftCents,
    aircraftUnpriced,
    totalCents,
    partial: ordnanceUnpriced + aircraftUnpriced > 0,
  };
}

export type PlayerRunEntry = {
  runKey: string;
  missionName: string | null;
  mapName: string | null;
  startedAt: string | null;
  status: string;
  row: ScoreboardRow;
};

export type PlayerMissionEntry = {
  mission: MissionCatalogEntry;
  runs: number;
  kills: number;
  losses: number;
  assists: number;
  shots: number;
  ordnanceCents: number;
  aircraftCents: number;
  totalCents: number;
  totalUnpriced: number;
  partial: boolean;
};

export type PlayerCareer = {
  participantId: string;
  publicPlayerId: string;
  displayName: string;
  otherNames: string[];
  runs: number;
  kills: number;
  friendlyKills: number;
  losses: number;
  assists: number;
  shots: number;
  ordnanceCents: number;
  aircraftCents: number;
  totalCents: number;
  totalUnpriced: number;
  partial: boolean;
  killLossRatio: number | null;
  byMission: PlayerMissionEntry[];
  history: PlayerRunEntry[];
};

/** Aggregate one UCID's per-run scoreboard rows into a career profile. */
export function aggregatePlayerCareer(
  participantId: string,
  entries: readonly PlayerRunEntry[],
  displayNameFallback: string | null = null,
): PlayerCareer {
  const byMission = new Map<string, PlayerMissionEntry>();
  let kills = 0;
  let friendlyKills = 0;
  let losses = 0;
  let assists = 0;
  let shots = 0;
  let ordnanceCents = 0;
  let aircraftCents = 0;
  let totalUnpriced = 0;
  const names = new Map<string, number>();
  const ordered = [...entries].sort((left, right) =>
    (left.startedAt ?? left.runKey).localeCompare(
      right.startedAt ?? right.runKey,
    ),
  );

  for (const entry of ordered) {
    const row = entry.row;
    kills += row.kills;
    friendlyKills += row.friendlyKills;
    losses += row.losses;
    assists += row.assists;
    shots += row.shots;
    ordnanceCents = addCents(ordnanceCents, row.ordnanceCostCents);
    aircraftCents = addCents(aircraftCents, row.aircraftLossCents);
    totalUnpriced += row.totalUnpriced;
    if (row.displayName !== "") {
      names.set(row.displayName, (names.get(row.displayName) ?? 0) + 1);
    }
    const missionKey = entry.missionName ?? "unknown";
    let mission = byMission.get(missionKey);
    if (!mission) {
      mission = {
        mission: missionCatalogEntry(entry.missionName),
        runs: 0,
        kills: 0,
        losses: 0,
        assists: 0,
        shots: 0,
        ordnanceCents: 0,
        aircraftCents: 0,
        totalCents: 0,
        totalUnpriced: 0,
        partial: false,
      };
      byMission.set(missionKey, mission);
    }
    mission.runs += 1;
    mission.kills += row.kills;
    mission.losses += row.losses;
    mission.assists += row.assists;
    mission.shots += row.shots;
    mission.ordnanceCents = addCents(
      mission.ordnanceCents,
      row.ordnanceCostCents,
    );
    mission.aircraftCents = addCents(
      mission.aircraftCents,
      row.aircraftLossCents,
    );
    mission.totalCents = addCents(mission.ordnanceCents, mission.aircraftCents);
    mission.totalUnpriced += row.totalUnpriced;
    mission.partial = mission.totalUnpriced > 0;
  }

  const rankedNames = [...names.entries()].sort(
    (left, right) => right[1] - left[1] || left[0].localeCompare(right[0]),
  );
  const displayName =
    rankedNames[0]?.[0] ?? displayNameFallback ?? participantId;
  const totalCents = addCents(ordnanceCents, aircraftCents);

  return {
    participantId,
    publicPlayerId: publicPlayerIdFor(participantId),
    displayName,
    otherNames: rankedNames.slice(1).map(([name]) => name),
    runs: ordered.length,
    kills,
    friendlyKills,
    losses,
    assists,
    shots,
    ordnanceCents,
    aircraftCents,
    totalCents,
    totalUnpriced,
    partial: totalUnpriced > 0,
    killLossRatio:
      losses === 0
        ? kills === 0
          ? null
          : Number.POSITIVE_INFINITY
        : kills / losses,
    byMission: [...byMission.values()].sort((left, right) =>
      left.mission.title.localeCompare(right.mission.title),
    ),
    history: ordered,
  };
}

function nullableString(
  record: Record<string, unknown> | null,
  field: string,
): string | null {
  if (record === null) {
    return null;
  }
  const candidate = record[field];
  return typeof candidate === "string" && candidate.length > 0
    ? candidate
    : null;
}

function actorRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

/**
 * Extract tracked asset incarnations from `asset.spawned` source events so
 * zero-action combatants still appear on the scoreboard.
 */
export function extractAssetSnapshots(
  events: readonly TelemetryEvent[],
): ScoreboardAssetInput[] {
  const snapshots: ScoreboardAssetInput[] = [];
  for (const event of events) {
    if (event.event_type !== "asset.spawned") {
      continue;
    }
    const asset = actorRecord(event.asset);
    if (asset === null) {
      continue;
    }
    const assetKey = nullableString(asset, "asset_key");
    if (assetKey === null) {
      continue;
    }
    snapshots.push({
      assetKey,
      dcsName: nullableString(asset, "dcs_name"),
      dcsType: nullableString(asset, "dcs_type"),
      coalition: nullableString(asset, "coalition") ?? event.coalition ?? null,
    });
  }
  return snapshots;
}

/** Minimal sortie input for single-occupant slot correlation. */
export function extractSortieOwners(
  events: readonly TelemetryEvent[],
): ScoreboardSortieInput[] {
  const owners: ScoreboardSortieInput[] = [];
  for (const event of events) {
    if (
      event.event_type !== "participant.entered" &&
      event.event_type !== "participant.left"
    ) {
      continue;
    }
    const asset = actorRecord(event.asset);
    const slotDcsName = nullableString(asset, "dcs_name");
    if (slotDcsName === null) {
      continue;
    }
    const participant = actorRecord(event.participant);
    owners.push({
      participantId: nullableString(participant, "participant_id"),
      slotDcsName,
    });
  }
  return owners;
}

/** Latest display label observed per UCID across participant rows. */
export function latestHumanLabel(
  rows: ReadonlyArray<{
    participantId: string;
    displayName: string | null;
    latestEventSequence?: number;
  }>,
  participantId: string,
): string | null {
  let best: string | null = null;
  let bestSequence = -1;
  for (const row of rows) {
    if (row.participantId !== participantId || row.displayName === null) {
      continue;
    }
    const sequence = row.latestEventSequence ?? 0;
    if (sequence >= bestSequence) {
      best = row.displayName;
      bestSequence = sequence;
    }
  }
  return best;
}
