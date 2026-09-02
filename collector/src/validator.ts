import { readFileSync } from "node:fs";
import { createRequire } from "node:module";

import type { Options, ValidateFunction } from "ajv";

import type { EventValidationResult, TelemetryEvent } from "./types.js";

export interface EventValidator {
  validate(value: unknown): EventValidationResult;
}

const require = createRequire(import.meta.url);
interface AjvInstance {
  addSchema(schema: unknown): void;
  getSchema<T>(key: string): ValidateFunction<T> | undefined;
}

const Ajv2020 = require("ajv/dist/2020.js") as new (
  options?: Options,
) => AjvInstance;
const addFormats = require("ajv-formats") as (ajv: AjvInstance) => unknown;

export function expectedEventId(event: TelemetryEvent): string {
  return `${event.producer_id}:${event.run_key}:${event.event_sequence}`;
}

export function createEventValidator(schemaPath: string): EventValidator {
  const schema: unknown = JSON.parse(readFileSync(schemaPath, "utf8"));
  const ajv = new Ajv2020({ allErrors: true, strict: true });
  addFormats(ajv);
  ajv.addSchema(schema);

  const validate = ajv.getSchema<TelemetryEvent>(
    "urn:dcs-missions:telemetry-event-v1",
  );
  if (validate === undefined) {
    throw new Error(
      "telemetry event schema did not register its event validator",
    );
  }

  return {
    validate(value: unknown): EventValidationResult {
      if (!validate(value)) {
        return {
          ok: false,
          code: "schema-invalid",
          message: "event does not satisfy telemetry-event-v1 JSON Schema",
          details: validate.errors ?? [],
        };
      }

      const event = value as TelemetryEvent;
      if (event.event_id !== expectedEventId(event)) {
        return {
          ok: false,
          code: "semantic-invalid",
          message: "event ID does not agree with producer, run, and sequence",
          details: {
            actual_event_id: event.event_id,
            expected_event_id: expectedEventId(event),
          },
        };
      }

      return { ok: true, event };
    },
  };
}
