CREATE TABLE "mission_runs" (
	"producer_id" text NOT NULL,
	"run_key" text NOT NULL,
	"mission_name" text,
	"mission_version" text,
	"map_name" text,
	"run_classification" text,
	"first_sequence" bigint DEFAULT 1 NOT NULL,
	"last_sequence" bigint DEFAULT 0 NOT NULL,
	"event_count" integer DEFAULT 0 NOT NULL,
	"started_at" timestamp with time zone,
	"ended_at" timestamp with time zone,
	"status" text DEFAULT 'active' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "mission_runs_producer_id_run_key_pk" PRIMARY KEY("producer_id","run_key")
);
--> statement-breakpoint
CREATE TABLE "telemetry_events" (
	"event_id" text PRIMARY KEY NOT NULL,
	"producer_id" text NOT NULL,
	"run_key" text NOT NULL,
	"event_sequence" bigint NOT NULL,
	"event_type" text NOT NULL,
	"sim_time" double precision NOT NULL,
	"wall_time" timestamp with time zone,
	"source" text NOT NULL,
	"source_version" text NOT NULL,
	"schema_version" smallint NOT NULL,
	"coalition" text,
	"location_status" text,
	"location_x" double precision,
	"location_y" double precision,
	"location_z" double precision,
	"weapon_status" text,
	"weapon_dcs_type" text,
	"weapon_category" text,
	"initiator_status" text,
	"initiator_kind" text,
	"initiator_participant_id" text,
	"initiator_dcs_name" text,
	"target_status" text,
	"target_kind" text,
	"target_dcs_name" text,
	"asset_status" text,
	"asset_key" text,
	"asset_dcs_name" text,
	"payload" jsonb NOT NULL,
	"event_json" jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "telemetry_events_producer_run_sequence_unique" UNIQUE("producer_id","run_key","event_sequence")
);
--> statement-breakpoint
CREATE INDEX "mission_runs_run_key_idx" ON "mission_runs" USING btree ("run_key");--> statement-breakpoint
CREATE INDEX "telemetry_events_run_sequence_idx" ON "telemetry_events" USING btree ("run_key","event_sequence");--> statement-breakpoint
CREATE INDEX "telemetry_events_event_type_idx" ON "telemetry_events" USING btree ("event_type");--> statement-breakpoint
CREATE INDEX "telemetry_events_sim_time_idx" ON "telemetry_events" USING btree ("sim_time");--> statement-breakpoint
CREATE INDEX "telemetry_events_coalition_idx" ON "telemetry_events" USING btree ("coalition");--> statement-breakpoint
CREATE INDEX "telemetry_events_weapon_dcs_type_idx" ON "telemetry_events" USING btree ("weapon_dcs_type");