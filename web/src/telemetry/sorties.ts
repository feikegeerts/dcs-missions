/**
 * Derive participant control periods without I/O or persistence concerns.
 *
 * Events are grouped by the enter/leave asset's DCS name (the slot snapshot),
 * with null or empty names skipped, and processed by event sequence within each
 * slot. An enter opens a sortie. If the prior sortie is still open, it becomes
 * `replaced` with no synthetic leave; this is the missing-left recovery
 * assumption. A left closes only the currently open sortie, and an unmatched
 * left is ignored. Participant identity always comes from the enter event and
 * may remain null. Results are ordered by enter sequence.
 *
 * A future projection identifies each derived fact by its supporting source
 * event IDs (enter plus left when present). This function assigns no separate
 * sortie ID; callers can map its supporting sequences back to those source
 * events when applying that identity rule.
 */

export type ParticipantEventInput = {
  event_sequence: number;
  event_type: "participant.entered" | "participant.left";
  sim_time: number;
  participant: {
    participant_id: string | null;
    display_name: string | null;
    callsign: string | null;
  } | null;
  asset: { dcs_name: string | null; dcs_type: string | null } | null;
};

export type Sortie = {
  participant_id: string | null;
  slot_dcs_name: string;
  entered_sequence: number;
  left_sequence: number | null;
  sim_started: number;
  sim_ended: number | null;
  status: "open" | "closed" | "replaced";
};

export function deriveSorties(events: ParticipantEventInput[]): Sortie[] {
  const orderedEvents = events
    .map((event, inputIndex) => ({ event, inputIndex }))
    .sort(
      (left, right) =>
        left.event.event_sequence - right.event.event_sequence ||
        left.inputIndex - right.inputIndex,
    );
  const sorties: Sortie[] = [];
  const openBySlot = new Map<string, Sortie>();

  for (const { event } of orderedEvents) {
    const slotName = event.asset?.dcs_name;
    if (slotName == null || slotName.length === 0) {
      continue;
    }

    if (event.event_type === "participant.entered") {
      const openSortie = openBySlot.get(slotName);
      if (openSortie) {
        openSortie.status = "replaced";
      }

      const sortie: Sortie = {
        participant_id: event.participant?.participant_id ?? null,
        slot_dcs_name: slotName,
        entered_sequence: event.event_sequence,
        left_sequence: null,
        sim_started: event.sim_time,
        sim_ended: null,
        status: "open",
      };
      sorties.push(sortie);
      openBySlot.set(slotName, sortie);
      continue;
    }

    const openSortie = openBySlot.get(slotName);
    if (!openSortie) {
      continue;
    }
    openSortie.left_sequence = event.event_sequence;
    openSortie.sim_ended = event.sim_time;
    openSortie.status = "closed";
    openBySlot.delete(slotName);
  }

  return sorties.sort(
    (left, right) => left.entered_sequence - right.entered_sequence,
  );
}

/**
 * Minimal stored-row shape for sortie mapping. Structural (not the store's
 * EventRow) so this helper stays import-cycle free and unit testable.
 */
export type StoredEventRowInput = {
  eventSequence: number;
  eventType: string;
  simTime: number;
  eventJson: unknown;
};

function nullableString(record: Record<string, unknown>, field: string) {
  const candidate = record[field];
  return typeof candidate === "string" ? candidate : null;
}

/**
 * Map one stored event row to a sortie input. Returns null for anything that
 * is not a participant enter/leave observation; `deriveSorties` itself skips
 * entries with no slot name.
 */
export function eventRowToSortieInput(
  row: StoredEventRowInput,
): ParticipantEventInput | null {
  if (
    row.eventType !== "participant.entered" &&
    row.eventType !== "participant.left"
  ) {
    return null;
  }
  const json =
    typeof row.eventJson === "object" && row.eventJson !== null
      ? (row.eventJson as Record<string, unknown>)
      : null;
  const participantJson =
    json !== null &&
    typeof json.participant === "object" &&
    json.participant !== null
      ? (json.participant as Record<string, unknown>)
      : null;
  const assetJson =
    json !== null && typeof json.asset === "object" && json.asset !== null
      ? (json.asset as Record<string, unknown>)
      : null;
  return {
    event_sequence: row.eventSequence,
    event_type: row.eventType,
    sim_time: row.simTime,
    participant:
      participantJson === null
        ? null
        : {
            participant_id: nullableString(participantJson, "participant_id"),
            display_name: nullableString(participantJson, "display_name"),
            callsign: nullableString(participantJson, "callsign"),
          },
    asset:
      assetJson === null
        ? null
        : {
            dcs_name: nullableString(assetJson, "dcs_name"),
            dcs_type: nullableString(assetJson, "dcs_type"),
          },
  };
}
