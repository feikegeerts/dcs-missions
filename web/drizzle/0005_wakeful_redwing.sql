CREATE TABLE "collector_health" (
	"identity" text PRIMARY KEY NOT NULL,
	"status" text NOT NULL,
	"summary" jsonb NOT NULL,
	"first_seen_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "collector_health_status_check" CHECK ("collector_health"."status" IN ('ok', 'degraded', 'blocked'))
);
