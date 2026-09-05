/**
 * CSV export builders for telemetry reads.
 *
 * Pure functions over minimal row shapes: formatting here never touches the
 * database, so money and quoting rules are unit-testable. Amounts render in
 * dollars with exactly two decimals; unpriced rows render an empty amount
 * and keep their identity columns so nothing is silently dropped.
 */

export type CsvEventRow = {
  eventSequence: number;
  eventType: string;
  simTime: number | null;
  weaponDcsType: string | null;
  initiatorParticipantId: string | null;
  coalition: string | null;
};

export type CsvExpenditureRow = {
  eventSequence: number;
  participantDisplayName: string | null;
  participantCallsign: string | null;
  assetKey: string | null;
  aircraftDcsType: string | null;
  coalition: string | null;
  weaponDisplayName: string | null;
  weaponDcsType: string | null;
  unitCostCents: number | null;
  catalogue: string;
  catalogueVersion: number;
};

function escapeCell(value: string): string {
  if (/[",\r\n]/.test(value)) {
    return `"${value.replace(/"/g, '""')}"`;
  }
  return value;
}

function textCell(value: string | null): string {
  return value ?? "";
}

function moneyCell(cents: number | null): string {
  if (cents === null) {
    return "";
  }
  return (cents / 100).toFixed(2);
}

function toCsv(header: string[], rows: string[][]): string {
  const lines = [header, ...rows].map((row) => row.map(escapeCell).join(","));
  return `${lines.join("\r\n")}\r\n`;
}

export function eventsToCsv(events: readonly CsvEventRow[]): string {
  return toCsv(
    [
      "event_sequence",
      "event_type",
      "sim_time",
      "weapon_dcs_type",
      "initiator_participant_id",
      "coalition",
    ],
    events.map((event) => [
      String(event.eventSequence),
      event.eventType,
      event.simTime === null ? "" : String(event.simTime),
      textCell(event.weaponDcsType),
      textCell(event.initiatorParticipantId),
      textCell(event.coalition),
    ]),
  );
}

export function expendituresToCsv(
  expenditures: readonly CsvExpenditureRow[],
): string {
  return toCsv(
    [
      "event_sequence",
      "participant",
      "callsign",
      "asset_key",
      "aircraft_dcs_type",
      "coalition",
      "weapon",
      "weapon_dcs_type",
      "unit_cost_usd",
      "catalogue",
      "catalogue_version",
    ],
    expenditures.map((expenditure) => [
      String(expenditure.eventSequence),
      textCell(expenditure.participantDisplayName),
      textCell(expenditure.participantCallsign),
      textCell(expenditure.assetKey),
      textCell(expenditure.aircraftDcsType),
      textCell(expenditure.coalition),
      textCell(expenditure.weaponDisplayName),
      textCell(expenditure.weaponDcsType),
      moneyCell(expenditure.unitCostCents),
      expenditure.catalogue,
      String(expenditure.catalogueVersion),
    ]),
  );
}
