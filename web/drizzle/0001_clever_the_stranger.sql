CREATE TABLE "valuation_catalogues" (
	"catalogue" text NOT NULL,
	"version" integer NOT NULL,
	"effective_date" date NOT NULL,
	"currency" text NOT NULL,
	"pricing_convention" text NOT NULL,
	"type_key_source" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "valuation_catalogues_catalogue_version_pk" PRIMARY KEY("catalogue","version"),
	CONSTRAINT "valuation_catalogues_version_positive" CHECK ("valuation_catalogues"."version" > 0)
);
--> statement-breakpoint
CREATE TABLE "valuation_items" (
	"catalogue" text NOT NULL,
	"catalogue_version" integer NOT NULL,
	"dcs_type" text NOT NULL,
	"display_name" text NOT NULL,
	"faction" text NOT NULL,
	"category" text NOT NULL,
	"usd_value" numeric(14, 2) NOT NULL,
	"value_basis" text NOT NULL,
	"source" text NOT NULL,
	"matrix_status" text NOT NULL,
	"matrix_evidence" text NOT NULL,
	"notes" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "valuation_items_catalogue_catalogue_version_dcs_type_pk" PRIMARY KEY("catalogue","catalogue_version","dcs_type"),
	CONSTRAINT "valuation_items_usd_value_positive" CHECK ("valuation_items"."usd_value" > 0)
);
--> statement-breakpoint
ALTER TABLE "valuation_items" ADD CONSTRAINT "valuation_items_catalogue_version_fk" FOREIGN KEY ("catalogue","catalogue_version") REFERENCES "public"."valuation_catalogues"("catalogue","version") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "valuation_catalogues_effective_date_idx" ON "valuation_catalogues" USING btree ("effective_date");--> statement-breakpoint
CREATE INDEX "valuation_items_dcs_type_idx" ON "valuation_items" USING btree ("dcs_type");--> statement-breakpoint
CREATE INDEX "valuation_items_faction_category_idx" ON "valuation_items" USING btree ("faction","category");