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

export const missionRuns = pgTable(
  "mission_runs",
  {
    producerId: text("producer_id").notNull(),
    runKey: text("run_key").notNull(),
    missionName: text("mission_name"),
    missionVersion: text("mission_version"),
    mapName: text("map_name"),
    runClassification: text("run_classification"),
    valuationCatalogue: text("valuation_catalogue"),
    valuationCatalogueVersion: integer("valuation_catalogue_version"),
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
    foreignKey({
      columns: [table.valuationCatalogue, table.valuationCatalogueVersion],
      foreignColumns: [
        valuationCatalogues.catalogue,
        valuationCatalogues.version,
      ],
      name: "mission_runs_valuation_catalogue_version_fk",
    }).onDelete("restrict"),
    check(
      "mission_runs_valuation_assignment_complete",
      sql`(${table.valuationCatalogue} IS NULL AND ${table.valuationCatalogueVersion} IS NULL) OR (${table.valuationCatalogue} IS NOT NULL AND ${table.valuationCatalogueVersion} IS NOT NULL)`,
    ),
    index("mission_runs_run_key_idx").on(table.runKey),
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

export const runParticipants = pgTable(
  "run_participants",
  {
    producerId: text("producer_id").notNull(),
    runKey: text("run_key").notNull(),
    participantId: text("participant_id").notNull(),
    displayName: text("display_name"),
    displayNameSequence: bigint("display_name_sequence", { mode: "number" }),
    callsign: text("callsign"),
    callsignSequence: bigint("callsign_sequence", { mode: "number" }),
    coalition: text("coalition"),
    latestEventSequence: bigint("latest_event_sequence", {
      mode: "number",
    }).notNull(),
    createdAt: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (table) => [
    primaryKey({
      columns: [table.producerId, table.runKey, table.participantId],
    }),
    foreignKey({
      columns: [table.producerId, table.runKey],
      foreignColumns: [missionRuns.producerId, missionRuns.runKey],
      name: "run_participants_mission_run_fk",
    }).onDelete("cascade"),
    index("run_participants_run_idx").on(table.producerId, table.runKey),
  ],
);

export const ordnanceExpenditures = pgTable(
  "ordnance_expenditures",
  {
    sourceEventId: text("source_event_id").primaryKey(),
    producerId: text("producer_id").notNull(),
    runKey: text("run_key").notNull(),
    eventSequence: bigint("event_sequence", { mode: "number" }).notNull(),
    participantId: text("participant_id"),
    participantDisplayName: text("participant_display_name"),
    participantCallsign: text("participant_callsign"),
    assetKey: text("asset_key"),
    aircraftDcsType: text("aircraft_dcs_type"),
    coalition: text("coalition"),
    weaponDcsType: text("weapon_dcs_type"),
    weaponDisplayName: text("weapon_display_name"),
    catalogue: text("catalogue").notNull(),
    catalogueVersion: integer("catalogue_version").notNull(),
    unitCostCents: bigint("unit_cost_cents", { mode: "number" }),
    createdAt: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (table) => [
    foreignKey({
      columns: [table.sourceEventId],
      foreignColumns: [telemetryEvents.eventId],
      name: "ordnance_expenditures_source_event_fk",
    }).onDelete("restrict"),
    foreignKey({
      columns: [table.producerId, table.runKey],
      foreignColumns: [missionRuns.producerId, missionRuns.runKey],
      name: "ordnance_expenditures_mission_run_fk",
    }).onDelete("cascade"),
    foreignKey({
      columns: [table.catalogue, table.catalogueVersion],
      foreignColumns: [
        valuationCatalogues.catalogue,
        valuationCatalogues.version,
      ],
      name: "ordnance_expenditures_catalogue_version_fk",
    }).onDelete("restrict"),
    check(
      "ordnance_expenditures_unit_cost_positive",
      sql`${table.unitCostCents} IS NULL OR ${table.unitCostCents} > 0`,
    ),
    index("ordnance_expenditures_run_sequence_idx").on(
      table.producerId,
      table.runKey,
      table.eventSequence,
    ),
    index("ordnance_expenditures_group_idx").on(
      table.producerId,
      table.runKey,
      table.participantId,
      table.assetKey,
      table.aircraftDcsType,
      table.coalition,
    ),
    index("ordnance_expenditures_weapon_dcs_type_idx").on(table.weaponDcsType),
  ],
);

export const assetLosses = pgTable(
  "asset_losses",
  {
    factId: text("fact_id").notNull(),
    producerId: text("producer_id").notNull(),
    runKey: text("run_key").notNull(),
    assetKey: text("asset_key").notNull(),
    aircraftDcsType: text("aircraft_dcs_type"),
    coalition: text("coalition"),
    catalogue: text("catalogue").notNull(),
    catalogueVersion: integer("catalogue_version").notNull(),
    unitCostCents: bigint("unit_cost_cents", { mode: "number" }),
    sourceEventIds: jsonb("source_event_ids").$type<string[]>().notNull(),
    createdAt: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (table) => [
    primaryKey({
      columns: [table.producerId, table.runKey, table.assetKey],
    }),
    unique("asset_losses_fact_id_unique").on(table.factId),
    foreignKey({
      columns: [table.producerId, table.runKey],
      foreignColumns: [missionRuns.producerId, missionRuns.runKey],
      name: "asset_losses_mission_run_fk",
    }).onDelete("cascade"),
    foreignKey({
      columns: [table.catalogue, table.catalogueVersion],
      foreignColumns: [
        valuationCatalogues.catalogue,
        valuationCatalogues.version,
      ],
      name: "asset_losses_catalogue_version_fk",
    }).onDelete("restrict"),
    check(
      "asset_losses_unit_cost_positive",
      sql`${table.unitCostCents} IS NULL OR ${table.unitCostCents} > 0`,
    ),
    check(
      "asset_losses_source_events_nonempty",
      sql`jsonb_array_length(${table.sourceEventIds}) > 0`,
    ),
    index("asset_losses_run_idx").on(table.producerId, table.runKey),
    index("asset_losses_run_aircraft_idx").on(
      table.producerId,
      table.runKey,
      table.aircraftDcsType,
      table.coalition,
    ),
  ],
);

export const killAttributions = pgTable(
  "kill_attributions",
  {
    factId: text("fact_id").notNull(),
    producerId: text("producer_id").notNull(),
    runKey: text("run_key").notNull(),
    targetAssetKey: text("target_asset_key").notNull(),
    targetDcsName: text("target_dcs_name"),
    targetDcsType: text("target_dcs_type"),
    targetCoalition: text("target_coalition"),
    killerAssetKey: text("killer_asset_key"),
    killerDcsName: text("killer_dcs_name"),
    killerDcsType: text("killer_dcs_type"),
    killerCoalition: text("killer_coalition"),
    killingBlowSimTime: doublePrecision("killing_blow_sim_time").notNull(),
    killingBlowEventId: text("killing_blow_event_id").notNull(),
    weaponDcsType: text("weapon_dcs_type"),
    weaponCategory: text("weapon_category"),
    sourceEventIds: jsonb("source_event_ids").$type<string[]>().notNull(),
    createdAt: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (table) => [
    primaryKey({
      columns: [table.producerId, table.runKey, table.targetAssetKey],
    }),
    unique("kill_attributions_fact_id_unique").on(table.factId),
    foreignKey({
      columns: [table.producerId, table.runKey],
      foreignColumns: [missionRuns.producerId, missionRuns.runKey],
      name: "kill_attributions_mission_run_fk",
    }).onDelete("cascade"),
    check(
      "kill_attributions_source_events_nonempty",
      sql`jsonb_array_length(${table.sourceEventIds}) > 0`,
    ),
    index("kill_attributions_run_idx").on(table.producerId, table.runKey),
    index("kill_attributions_run_killer_idx").on(
      table.producerId,
      table.runKey,
      table.killerAssetKey,
    ),
  ],
);

export const assistAttributions = pgTable(
  "assist_attributions",
  {
    factId: text("fact_id").notNull(),
    producerId: text("producer_id").notNull(),
    runKey: text("run_key").notNull(),
    targetAssetKey: text("target_asset_key").notNull(),
    attackerAssetKey: text("attacker_asset_key").notNull(),
    attackerDcsName: text("attacker_dcs_name"),
    attackerDcsType: text("attacker_dcs_type"),
    attackerCoalition: text("attacker_coalition"),
    targetDcsName: text("target_dcs_name"),
    targetDcsType: text("target_dcs_type"),
    targetCoalition: text("target_coalition"),
    representativeHitSimTime: doublePrecision(
      "representative_hit_sim_time",
    ).notNull(),
    representativeHitEventId: text("representative_hit_event_id").notNull(),
    sourceEventIds: jsonb("source_event_ids").$type<string[]>().notNull(),
    createdAt: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (table) => [
    primaryKey({
      columns: [
        table.producerId,
        table.runKey,
        table.targetAssetKey,
        table.attackerAssetKey,
      ],
    }),
    unique("assist_attributions_fact_id_unique").on(table.factId),
    foreignKey({
      columns: [table.producerId, table.runKey],
      foreignColumns: [missionRuns.producerId, missionRuns.runKey],
      name: "assist_attributions_mission_run_fk",
    }).onDelete("cascade"),
    check(
      "assist_attributions_source_events_nonempty",
      sql`jsonb_array_length(${table.sourceEventIds}) > 0`,
    ),
    index("assist_attributions_run_idx").on(table.producerId, table.runKey),
    index("assist_attributions_run_attacker_idx").on(
      table.producerId,
      table.runKey,
      table.attackerAssetKey,
    ),
  ],
);

export type TelemetryEventRow = typeof telemetryEvents.$inferSelect;
export type MissionRunRow = typeof missionRuns.$inferSelect;
export type ValuationCatalogueRow = typeof valuationCatalogues.$inferSelect;
export type NewValuationCatalogueRow = typeof valuationCatalogues.$inferInsert;
export type ValuationItemRow = typeof valuationItems.$inferSelect;
export type NewValuationItemRow = typeof valuationItems.$inferInsert;
export type RunParticipantRow = typeof runParticipants.$inferSelect;
export type OrdnanceExpenditureRow = typeof ordnanceExpenditures.$inferSelect;
export type AssetLossRow = typeof assetLosses.$inferSelect;
export type KillAttributionRow = typeof killAttributions.$inferSelect;
export type AssistAttributionRow = typeof assistAttributions.$inferSelect;
