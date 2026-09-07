import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import { processIngest } from "../src/telemetry/ingest";
import {
  DEFAULT_MAX_BATCHES_PER_WINDOW,
  DEFAULT_MAX_TRACKED_PRODUCERS,
  DEFAULT_WINDOW_MS,
  defaultRateLimiter,
  FixedWindowRateLimiter,
} from "../src/telemetry/rate-limit";
import type { TelemetryStore } from "../src/telemetry/store";
import type { TelemetryEvent } from "../src/telemetry/types";

const validEvent = JSON.parse(
  readFileSync(
    resolve(
      process.cwd(),
      "..",
      "contracts/fixtures/valid/01-mission-started.json",
    ),
    "utf8",
  ),
) as TelemetryEvent;

function batchBody(): string {
  return JSON.stringify({ batch_schema_version: 1, events: [validEvent] });
}

function limiter(options: {
  maxBatchesPerWindow?: number;
  windowMs?: number;
  maxTrackedProducers?: number;
  now: () => number;
}): FixedWindowRateLimiter {
  return new FixedWindowRateLimiter(options);
}

class FakeStore implements TelemetryStore {
  callCount = 0;

  async insertEvent(): Promise<"accepted"> {
    this.callCount += 1;
    return "accepted";
  }

  async abortSupersededRuns(): Promise<number> {
    this.callCount += 1;
    return 0;
  }

  async markRunAborted(): Promise<number> {
    this.callCount += 1;
    return 0;
  }

  async upsertRun(): Promise<void> {
    this.callCount += 1;
  }

  async insertExpenditure(): Promise<"inserted"> {
    this.callCount += 1;
    return "inserted";
  }

  async upsertAssetLoss(): Promise<void> {
    this.callCount += 1;
  }

  async upsertKillAttribution(): Promise<void> {
    this.callCount += 1;
  }

  async upsertAssistAttribution(): Promise<void> {
    this.callCount += 1;
  }

  async upsertRunParticipant(): Promise<void> {
    this.callCount += 1;
  }

  async listRuns(): Promise<never[]> {
    this.callCount += 1;
    return [];
  }

  async getRunByRunKey(): Promise<null> {
    this.callCount += 1;
    return null;
  }

  async listEvents(): Promise<never[]> {
    this.callCount += 1;
    return [];
  }

  async listRunEvents(): Promise<TelemetryEvent[]> {
    this.callCount += 1;
    return [];
  }

  async listExpenditures(): Promise<never[]> {
    this.callCount += 1;
    return [];
  }

  async listAssetLosses(): Promise<never[]> {
    this.callCount += 1;
    return [];
  }

  async listKillAttributions(): Promise<never[]> {
    this.callCount += 1;
    return [];
  }

  async listAssistAttributions(): Promise<never[]> {
    this.callCount += 1;
    return [];
  }

  async listRunParticipants(): Promise<never[]> {
    this.callCount += 1;
    return [];
  }
}

describe("FixedWindowRateLimiter", () => {
  it("allows calls up to the limit and denies the next call", () => {
    const rateLimiter = limiter({ maxBatchesPerWindow: 3, now: () => 0 });

    expect(rateLimiter.tryAcquire("producer-a")).toBe(true);
    expect(rateLimiter.tryAcquire("producer-a")).toBe(true);
    expect(rateLimiter.tryAcquire("producer-a")).toBe(true);
    expect(rateLimiter.tryAcquire("producer-a")).toBe(false);
  });

  it("allows a producer again after the window rolls over", () => {
    let now = 0;
    const rateLimiter = limiter({
      maxBatchesPerWindow: 1,
      windowMs: 60_000,
      now: () => now,
    });
    expect(rateLimiter.tryAcquire("producer-a")).toBe(true);
    expect(rateLimiter.tryAcquire("producer-a")).toBe(false);

    now += 60_000;

    expect(rateLimiter.tryAcquire("producer-a")).toBe(true);
  });

  it("isolates each producer's quota", () => {
    const rateLimiter = limiter({ maxBatchesPerWindow: 3, now: () => 0 });
    expect(rateLimiter.tryAcquire("producer-a")).toBe(true);
    expect(rateLimiter.tryAcquire("producer-a")).toBe(true);
    expect(rateLimiter.tryAcquire("producer-a")).toBe(true);
    expect(rateLimiter.tryAcquire("producer-a")).toBe(false);

    expect(rateLimiter.tryAcquire("producer-b")).toBe(true);
  });

  it("starts at count one rather than carrying counts into a new window", () => {
    let now = 59_999;
    const rateLimiter = limiter({
      maxBatchesPerWindow: 3,
      windowMs: 60_000,
      now: () => now,
    });
    expect(rateLimiter.tryAcquire("producer-a")).toBe(true);
    expect(rateLimiter.tryAcquire("producer-a")).toBe(true);

    now = 60_000;

    expect(rateLimiter.tryAcquire("producer-a")).toBe(true);
    expect(rateLimiter.tryAcquire("producer-a")).toBe(true);
    expect(rateLimiter.tryAcquire("producer-a")).toBe(true);
    expect(rateLimiter.tryAcquire("producer-a")).toBe(false);
  });

  it("clears tracked producers before adding one beyond the memory cap", () => {
    const rateLimiter = limiter({
      maxBatchesPerWindow: 1,
      maxTrackedProducers: 2,
      now: () => 0,
    });
    expect(rateLimiter.tryAcquire("producer-a")).toBe(true);
    expect(rateLimiter.tryAcquire("producer-b")).toBe(true);

    expect(rateLimiter.tryAcquire("producer-c")).toBe(true);
    expect(rateLimiter.tryAcquire("producer-a")).toBe(true);
  });
});

describe("processIngest rate limiting", () => {
  it("preserves ingest and store interactions below the limit", async () => {
    const store = new FakeStore();
    const rateLimiter = limiter({ maxBatchesPerWindow: 2, now: () => 0 });

    const result = await processIngest(batchBody(), store, rateLimiter);

    expect(result.httpStatus).toBe(200);
    expect(store.callCount).toBeGreaterThan(0);
  });

  it("returns the exact 429 body without partial store interaction", async () => {
    const store = new FakeStore();
    const rateLimiter = limiter({ maxBatchesPerWindow: 1, now: () => 0 });
    expect(
      (await processIngest(batchBody(), store, rateLimiter)).httpStatus,
    ).toBe(200);
    store.callCount = 0;

    const result = await processIngest(batchBody(), store, rateLimiter);

    expect(result).toEqual({
      httpStatus: 429,
      body: { error: "rate-limited" },
    });
    expect(store.callCount).toBe(0);
  });

  it("does not consume quota for a 400 validation failure", async () => {
    const store = new FakeStore();
    const rateLimiter = limiter({ maxBatchesPerWindow: 1, now: () => 0 });

    const invalid = await processIngest("not-json", store, rateLimiter);
    const valid = await processIngest(batchBody(), store, rateLimiter);

    expect(invalid.httpStatus).toBe(400);
    expect(valid.httpStatus).toBe(200);
  });

  it("pins the production defaults and singleton type", () => {
    expect(DEFAULT_MAX_BATCHES_PER_WINDOW).toBe(300);
    expect(DEFAULT_WINDOW_MS).toBe(60_000);
    expect(DEFAULT_MAX_TRACKED_PRODUCERS).toBe(4096);
    expect(defaultRateLimiter).toBeInstanceOf(FixedWindowRateLimiter);
  });
});
