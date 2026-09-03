import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

import schema from "./telemetry-event-v1.schema.json";
import type { TelemetryEvent } from "./types";

export type ValidationFailure = {
  ok: false;
  httpStatus: 400;
  code:
    | "batch-too-large"
    | "invalid-json"
    | "invalid-batch-envelope"
    | "batch-preflight"
    | "batch-mixed-run"
    | "batch-sequence-gap";
  message: string;
};

export type BatchEventResult = {
  event: TelemetryEvent;
  valid: boolean;
  rejectReason?: "schema-invalid" | "inconsistent-event-id";
};

export type ValidationSuccess = {
  ok: true;
  producerId: string;
  runKey: string;
  events: BatchEventResult[];
};

export type BatchValidation = ValidationFailure | ValidationSuccess;

type PreflightEvent = Record<string, unknown> & {
  producer_id: string;
  run_key: string;
  event_id: string;
  event_sequence: number;
};

const ajv = new Ajv2020({ allErrors: true, strict: true });
addFormats(ajv);
ajv.addSchema(schema);

const validateEvent = ajv.getSchema<TelemetryEvent>(
  "urn:dcs-missions:telemetry-event-v1",
);

if (!validateEvent) {
  throw new Error("telemetry event schema did not register its validator");
}
const eventValidator = validateEvent;

export function expectedEventId(event: TelemetryEvent): string {
  return `${event.producer_id}:${event.run_key}:${event.event_sequence}`;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return false;
  }

  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function isPreflightEvent(value: unknown): value is PreflightEvent {
  if (!isPlainObject(value)) {
    return false;
  }

  return (
    typeof value.producer_id === "string" &&
    value.producer_id.length > 0 &&
    typeof value.run_key === "string" &&
    value.run_key.length > 0 &&
    typeof value.event_id === "string" &&
    value.event_id.length > 0 &&
    typeof value.event_sequence === "number" &&
    Number.isInteger(value.event_sequence) &&
    value.event_sequence >= 1
  );
}

function failure(
  code: ValidationFailure["code"],
  message: string,
): ValidationFailure {
  return { ok: false, httpStatus: 400, code, message };
}

export function validateBatch(rawBodyText: string): BatchValidation {
  if (Buffer.byteLength(rawBodyText, "utf8") > 1_048_576) {
    return failure("batch-too-large", "request body exceeds 1 MiB");
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(rawBodyText) as unknown;
  } catch {
    return failure("invalid-json", "request body is not valid JSON");
  }

  if (!isPlainObject(parsed)) {
    return failure("invalid-batch-envelope", "batch envelope is invalid");
  }

  const envelopeKeys = Object.keys(parsed).sort();
  if (
    envelopeKeys.length !== 2 ||
    envelopeKeys[0] !== "batch_schema_version" ||
    envelopeKeys[1] !== "events" ||
    parsed.batch_schema_version !== 1 ||
    !Array.isArray(parsed.events) ||
    parsed.events.length < 1 ||
    parsed.events.length > 100
  ) {
    return failure("invalid-batch-envelope", "batch envelope is invalid");
  }

  const events = parsed.events;
  for (const event of events) {
    if (!isPreflightEvent(event)) {
      return failure(
        "batch-preflight",
        "every event must have producer_id, run_key, event_id, and a positive integer event_sequence",
      );
    }
  }

  const preflightEvents = events as PreflightEvent[];
  const firstEvent = preflightEvents[0];
  const producerId = firstEvent.producer_id;
  const runKey = firstEvent.run_key;
  let previousSequence: number | undefined;

  for (const candidate of preflightEvents) {
    const sequence = candidate.event_sequence;
    if (candidate.producer_id !== producerId || candidate.run_key !== runKey) {
      return failure(
        "batch-mixed-run",
        "all events in a batch must share producer_id and run_key",
      );
    }
    if (previousSequence !== undefined && sequence !== previousSequence + 1) {
      return failure(
        "batch-sequence-gap",
        "event sequences must be strictly increasing and contiguous",
      );
    }
    previousSequence = sequence;
  }

  return {
    ok: true,
    producerId,
    runKey,
    events: preflightEvents.map((event) => {
      const telemetryEvent = event as unknown as TelemetryEvent;
      if (!eventValidator(telemetryEvent)) {
        return {
          event: telemetryEvent,
          valid: false,
          rejectReason: "schema-invalid",
        };
      }
      if (telemetryEvent.event_id !== expectedEventId(telemetryEvent)) {
        return {
          event: telemetryEvent,
          valid: false,
          rejectReason: "inconsistent-event-id",
        };
      }
      return { event: telemetryEvent, valid: true };
    }),
  };
}
