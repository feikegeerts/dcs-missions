import { sql } from "drizzle-orm";
import {
  bigint,
  check,
  date,
  doublePrecision,
  foreignKey,
  index,
  integer,
  jsonb,
  numeric,
  pgTable,
  primaryKey,
  smallint,
  text,
  timestamp,
  unique,
} from "drizzle-orm/pg-core";

export const telemetryEvents = pgTable(
  "telemetry_events",
  {
    eventId: text("event_id").primaryKey(),
    producerId: text("producer_id").notNull(),
    runKey: text("run_key").notNull(),
    eventSequence: bigint("event_sequence", { mode: "number" }).notNull(),
    eventType: text("event_type").notNull(),
    simTime: doublePrecision("sim_time").notNull(),
    wallTime: timestamp("wall_time", { withTimezone: true }),
    source: text("source").notNull(),
    sourceVersion: text("source_version").notNull(),
    schemaVersion: smallint("schema_version").notNull(),
    coalition: text("coalition"),
    locationStatus: text("location_status"),
    locationX: doublePrecision("location_x"),
    locationY: doublePrecision("location_y"),
    locationZ: doublePrecision("location_z"),
    weaponStatus: text("weapon_status"),
    weaponDcsType: text("weapon_dcs_type"),
    weaponCategory: text("weapon_category"),
    initiatorStatus: text("initiator_status"),
    initiatorKind: text("initiator_kind"),
    initiatorParticipantId: text("initiator_participant_id"),
    initiatorDcsName: text("initiator_dcs_name"),
    targetStatus: text("target_status"),
    targetKind: text("target_kind"),
    targetDcsName: text("target_dcs_name"),
    assetStatus: text("asset_status"),
    assetKey: text("asset_key"),
    assetDcsName: text("asset_dcs_name"),
    payload: jsonb("payload").notNull(),
    eventJson: jsonb("event_json").notNull(),
    createdAt: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (table) => [
    unique("telemetry_events_producer_run_sequence_unique").on(
      table.producerId,
      table.runKey,
      table.eventSequence,
    ),
    index("telemetry_events_run_sequence_idx").on(
      table.runKey,
      table.eventSequence,
    ),
    index("telemetry_events_event_type_idx").on(table.eventType),
    index("telemetry_events_sim_time_idx").on(table.simTime),
    index("telemetry_events_coalition_idx").on(table.coalition),
    index("telemetry_events_weapon_dcs_type_idx").on(table.weaponDcsType),
  ],
);

export const missionRuns = pgTable(
  "mission_runs",
  {
    producerId: text("producer_id").notNull(),
    runKey: text("run_key").notNull(),
    missionName: text("mission_name"),
    missionVersion: text("mission_version"),
    mapName: text("map_name"),
    runClassification: text("run_classification"),
    firstSequence: bigint("first_sequence", { mode: "number" })
      .notNull()
      .default(1),
    lastSequence: bigint("last_sequence", { mode: "number" })
      .notNull()
      .default(0),
    eventCount: integer("event_count").notNull().default(0),
    startedAt: timestamp("started_at", { withTimezone: true }),
    endedAt: timestamp("ended_at", { withTimezone: true }),
    status: text("status").notNull().default("active"),
    createdAt: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (table) => [
    primaryKey({ columns: [table.producerId, table.runKey] }),
    index("mission_runs_run_key_idx").on(table.runKey),
  ],
);

export const valuationCatalogues = pgTable(
  "valuation_catalogues",
  {
    catalogue: text("catalogue").notNull(),
    version: integer("version").notNull(),
    effectiveDate: date("effective_date", { mode: "string" }).notNull(),
    currency: text("currency").notNull(),
    pricingConvention: text("pricing_convention").notNull(),
    typeKeySource: text("type_key_source").notNull(),
    createdAt: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (table) => [
    primaryKey({ columns: [table.catalogue, table.version] }),
    check("valuation_catalogues_version_positive", sql`${table.version} > 0`),
    index("valuation_catalogues_effective_date_idx").on(table.effectiveDate),
  ],
);

export const valuationItems = pgTable(
  "valuation_items",
  {
    catalogue: text("catalogue").notNull(),
    catalogueVersion: integer("catalogue_version").notNull(),
    dcsType: text("dcs_type").notNull(),
    displayName: text("display_name").notNull(),
    faction: text("faction").notNull(),
    category: text("category").notNull(),
    usdValue: numeric("usd_value", { precision: 14, scale: 2 }).notNull(),
    valueBasis: text("value_basis").notNull(),
    source: text("source").notNull(),
    matrixStatus: text("matrix_status").notNull(),
    matrixEvidence: text("matrix_evidence").notNull(),
    notes: text("notes").notNull(),
    createdAt: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (table) => [
    primaryKey({
      columns: [table.catalogue, table.catalogueVersion, table.dcsType],
    }),
    foreignKey({
      columns: [table.catalogue, table.catalogueVersion],
      foreignColumns: [
        valuationCatalogues.catalogue,
        valuationCatalogues.version,
      ],
      name: "valuation_items_catalogue_version_fk",
    }).onDelete("restrict"),
    check("valuation_items_usd_value_positive", sql`${table.usdValue} > 0`),
    index("valuation_items_dcs_type_idx").on(table.dcsType),
    index("valuation_items_faction_category_idx").on(
      table.faction,
      table.category,
    ),
  ],
);

export type TelemetryEventRow = typeof telemetryEvents.$inferSelect;
export type MissionRunRow = typeof missionRuns.$inferSelect;
export type ValuationCatalogueRow = typeof valuationCatalogues.$inferSelect;
export type NewValuationCatalogueRow = typeof valuationCatalogues.$inferInsert;
export type ValuationItemRow = typeof valuationItems.$inferSelect;
export type NewValuationItemRow = typeof valuationItems.$inferInsert;
