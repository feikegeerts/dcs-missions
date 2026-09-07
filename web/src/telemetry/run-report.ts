import type {
  AssetLossRow,
  AssistAttributionRow,
  ExpenditureRow,
  KillAttributionRow,
  RunParticipantRow,
  RunRow,
} from "./store";
import type { TelemetryEvent } from "./types";

/** Data boundary shared by the database-backed page and report renderer.
 * Type-only store imports: importing this module never connects to Neon. */
export type RunReportData = {
  run: RunRow;
  runEvents: TelemetryEvent[];
  expenditures: ExpenditureRow[];
  losses: AssetLossRow[];
  kills: KillAttributionRow[];
  assists: AssistAttributionRow[];
  participants: RunParticipantRow[];
};

/** Timeline pagination has no bearing on scoreboard or sortie totals. */
export function timelinePage(events: readonly TelemetryEvent[], page: number) {
  const pageSize = 50;
  const currentPage = Number.isSafeInteger(page) && page > 0 ? page : 1;
  const offset = (currentPage - 1) * pageSize;
  const window = events.slice(offset, offset + pageSize + 1);
  return {
    currentPage,
    hasNextPage: window.length > pageSize,
    pageEvents: window.slice(0, pageSize).map((event) => ({
      eventId: event.event_id,
      eventSequence: event.event_sequence,
      eventType: event.event_type,
      simTime: event.sim_time,
      weaponDcsType:
        event.weapon?.status === "known" &&
        typeof event.weapon.dcs_type === "string"
          ? event.weapon.dcs_type
          : null,
    })),
  };
}
