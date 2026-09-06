CREATE TABLE "asset_losses" (
	"fact_id" text NOT NULL,
	"producer_id" text NOT NULL,
	"run_key" text NOT NULL,
	"asset_key" text NOT NULL,
	"aircraft_dcs_type" text,
	"coalition" text,
	"catalogue" text NOT NULL,
	"catalogue_version" integer NOT NULL,
	"unit_cost_cents" bigint,
	"source_event_ids" jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "asset_losses_producer_id_run_key_asset_key_pk" PRIMARY KEY("producer_id","run_key","asset_key"),
	CONSTRAINT "asset_losses_fact_id_unique" UNIQUE("fact_id"),
	CONSTRAINT "asset_losses_unit_cost_positive" CHECK ("asset_losses"."unit_cost_cents" IS NULL OR "asset_losses"."unit_cost_cents" > 0),
	CONSTRAINT "asset_losses_source_events_nonempty" CHECK (jsonb_array_length("asset_losses"."source_event_ids") > 0)
);
--> statement-breakpoint
ALTER TABLE "asset_losses" ADD CONSTRAINT "asset_losses_mission_run_fk" FOREIGN KEY ("producer_id","run_key") REFERENCES "public"."mission_runs"("producer_id","run_key") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "asset_losses" ADD CONSTRAINT "asset_losses_catalogue_version_fk" FOREIGN KEY ("catalogue","catalogue_version") REFERENCES "public"."valuation_catalogues"("catalogue","version") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "asset_losses_run_idx" ON "asset_losses" USING btree ("producer_id","run_key");--> statement-breakpoint
CREATE INDEX "asset_losses_run_aircraft_idx" ON "asset_losses" USING btree ("producer_id","run_key","aircraft_dcs_type","coalition");