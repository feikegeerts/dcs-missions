CREATE TABLE "assist_attributions" (
	"fact_id" text NOT NULL,
	"producer_id" text NOT NULL,
	"run_key" text NOT NULL,
	"target_asset_key" text NOT NULL,
	"attacker_asset_key" text NOT NULL,
	"attacker_dcs_name" text,
	"attacker_dcs_type" text,
	"attacker_coalition" text,
	"target_dcs_name" text,
	"target_dcs_type" text,
	"target_coalition" text,
	"representative_hit_sim_time" double precision NOT NULL,
	"representative_hit_event_id" text NOT NULL,
	"source_event_ids" jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "assist_attributions_producer_id_run_key_target_asset_key_attacker_asset_key_pk" PRIMARY KEY("producer_id","run_key","target_asset_key","attacker_asset_key"),
	CONSTRAINT "assist_attributions_fact_id_unique" UNIQUE("fact_id"),
	CONSTRAINT "assist_attributions_source_events_nonempty" CHECK (jsonb_array_length("assist_attributions"."source_event_ids") > 0)
);
--> statement-breakpoint
CREATE TABLE "kill_attributions" (
	"fact_id" text NOT NULL,
	"producer_id" text NOT NULL,
	"run_key" text NOT NULL,
	"target_asset_key" text NOT NULL,
	"target_dcs_name" text,
	"target_dcs_type" text,
	"target_coalition" text,
	"killer_asset_key" text,
	"killer_dcs_name" text,
	"killer_dcs_type" text,
	"killer_coalition" text,
	"killing_blow_sim_time" double precision NOT NULL,
	"killing_blow_event_id" text NOT NULL,
	"weapon_dcs_type" text,
	"weapon_category" text,
	"source_event_ids" jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "kill_attributions_producer_id_run_key_target_asset_key_pk" PRIMARY KEY("producer_id","run_key","target_asset_key"),
	CONSTRAINT "kill_attributions_fact_id_unique" UNIQUE("fact_id"),
	CONSTRAINT "kill_attributions_source_events_nonempty" CHECK (jsonb_array_length("kill_attributions"."source_event_ids") > 0)
);
--> statement-breakpoint
ALTER TABLE "assist_attributions" ADD CONSTRAINT "assist_attributions_mission_run_fk" FOREIGN KEY ("producer_id","run_key") REFERENCES "public"."mission_runs"("producer_id","run_key") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "kill_attributions" ADD CONSTRAINT "kill_attributions_mission_run_fk" FOREIGN KEY ("producer_id","run_key") REFERENCES "public"."mission_runs"("producer_id","run_key") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "assist_attributions_run_idx" ON "assist_attributions" USING btree ("producer_id","run_key");--> statement-breakpoint
CREATE INDEX "assist_attributions_run_attacker_idx" ON "assist_attributions" USING btree ("producer_id","run_key","attacker_asset_key");--> statement-breakpoint
CREATE INDEX "kill_attributions_run_idx" ON "kill_attributions" USING btree ("producer_id","run_key");--> statement-breakpoint
CREATE INDEX "kill_attributions_run_killer_idx" ON "kill_attributions" USING btree ("producer_id","run_key","killer_asset_key");