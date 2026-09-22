-- Lifecycle-only server boots are operational telemetry, not dashboard runs.
-- Keep the raw event store consistent with the same participant.entered
-- eligibility boundary used by the collector and dashboard queries.
CREATE TEMP TABLE telemetry_empty_mission_runs AS
SELECT mission_runs.producer_id, mission_runs.run_key
FROM mission_runs
WHERE NOT EXISTS (
  SELECT 1
  FROM telemetry_events
  WHERE telemetry_events.producer_id = mission_runs.producer_id
    AND telemetry_events.run_key = mission_runs.run_key
    AND telemetry_events.event_type = 'participant.entered'
);
--> statement-breakpoint
DELETE FROM mission_runs
USING telemetry_empty_mission_runs
WHERE mission_runs.producer_id = telemetry_empty_mission_runs.producer_id
  AND mission_runs.run_key = telemetry_empty_mission_runs.run_key;
--> statement-breakpoint
DELETE FROM telemetry_events
USING telemetry_empty_mission_runs
WHERE telemetry_events.producer_id = telemetry_empty_mission_runs.producer_id
  AND telemetry_events.run_key = telemetry_empty_mission_runs.run_key;
--> statement-breakpoint
DROP TABLE telemetry_empty_mission_runs;
