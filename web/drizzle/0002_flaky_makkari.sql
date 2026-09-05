CREATE TABLE "ordnance_expenditures" (
	"source_event_id" text PRIMARY KEY NOT NULL,
	"producer_id" text NOT NULL,
	"run_key" text NOT NULL,
	"event_sequence" bigint NOT NULL,
	"participant_id" text,
	"participant_display_name" text,
	"participant_callsign" text,
	"asset_key" text,
	"aircraft_dcs_type" text,
	"coalition" text,
	"weapon_dcs_type" text,
	"weapon_display_name" text,
	"catalogue" text NOT NULL,
	"catalogue_version" integer NOT NULL,
	"unit_cost_cents" bigint,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "ordnance_expenditures_unit_cost_positive" CHECK ("ordnance_expenditures"."unit_cost_cents" IS NULL OR "ordnance_expenditures"."unit_cost_cents" > 0)
);
--> statement-breakpoint
CREATE TABLE "run_participants" (
	"producer_id" text NOT NULL,
	"run_key" text NOT NULL,
	"participant_id" text NOT NULL,
	"display_name" text,
	"display_name_sequence" bigint,
	"callsign" text,
	"callsign_sequence" bigint,
	"coalition" text,
	"latest_event_sequence" bigint NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "run_participants_producer_id_run_key_participant_id_pk" PRIMARY KEY("producer_id","run_key","participant_id")
);
--> statement-breakpoint
ALTER TABLE "mission_runs" ADD COLUMN "valuation_catalogue" text;--> statement-breakpoint
ALTER TABLE "mission_runs" ADD COLUMN "valuation_catalogue_version" integer;--> statement-breakpoint
ALTER TABLE "ordnance_expenditures" ADD CONSTRAINT "ordnance_expenditures_source_event_fk" FOREIGN KEY ("source_event_id") REFERENCES "public"."telemetry_events"("event_id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ordnance_expenditures" ADD CONSTRAINT "ordnance_expenditures_mission_run_fk" FOREIGN KEY ("producer_id","run_key") REFERENCES "public"."mission_runs"("producer_id","run_key") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ordnance_expenditures" ADD CONSTRAINT "ordnance_expenditures_catalogue_version_fk" FOREIGN KEY ("catalogue","catalogue_version") REFERENCES "public"."valuation_catalogues"("catalogue","version") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "run_participants" ADD CONSTRAINT "run_participants_mission_run_fk" FOREIGN KEY ("producer_id","run_key") REFERENCES "public"."mission_runs"("producer_id","run_key") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "ordnance_expenditures_run_sequence_idx" ON "ordnance_expenditures" USING btree ("producer_id","run_key","event_sequence");--> statement-breakpoint
CREATE INDEX "ordnance_expenditures_group_idx" ON "ordnance_expenditures" USING btree ("producer_id","run_key","participant_id","asset_key","aircraft_dcs_type","coalition");--> statement-breakpoint
CREATE INDEX "ordnance_expenditures_weapon_dcs_type_idx" ON "ordnance_expenditures" USING btree ("weapon_dcs_type");--> statement-breakpoint
CREATE INDEX "run_participants_run_idx" ON "run_participants" USING btree ("producer_id","run_key");--> statement-breakpoint
ALTER TABLE "mission_runs" ADD CONSTRAINT "mission_runs_valuation_catalogue_version_fk" FOREIGN KEY ("valuation_catalogue","valuation_catalogue_version") REFERENCES "public"."valuation_catalogues"("catalogue","version") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "mission_runs" ADD CONSTRAINT "mission_runs_valuation_assignment_complete" CHECK (("mission_runs"."valuation_catalogue" IS NULL AND "mission_runs"."valuation_catalogue_version" IS NULL) OR ("mission_runs"."valuation_catalogue" IS NOT NULL AND "mission_runs"."valuation_catalogue_version" IS NOT NULL));