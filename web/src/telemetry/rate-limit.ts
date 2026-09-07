export const DEFAULT_MAX_BATCHES_PER_WINDOW = 300;
export const DEFAULT_WINDOW_MS = 60_000;
export const DEFAULT_MAX_TRACKED_PRODUCERS = 4096;

type FixedWindowRateLimiterOptions = {
  maxBatchesPerWindow?: number;
  windowMs?: number;
  maxTrackedProducers?: number;
  now?: () => number;
};

export class FixedWindowRateLimiter {
  private readonly maxBatchesPerWindow: number;
  private readonly windowMs: number;
  private readonly maxTrackedProducers: number;
  private readonly now: () => number;
  private readonly producers = new Map<
    string,
    { window: number; count: number }
  >();

  constructor(options: FixedWindowRateLimiterOptions = {}) {
    this.maxBatchesPerWindow =
      options.maxBatchesPerWindow ?? DEFAULT_MAX_BATCHES_PER_WINDOW;
    this.windowMs = options.windowMs ?? DEFAULT_WINDOW_MS;
    this.maxTrackedProducers =
      options.maxTrackedProducers ?? DEFAULT_MAX_TRACKED_PRODUCERS;
    this.now = options.now ?? Date.now;
  }

  tryAcquire(producerId: string): boolean {
    const currentWindow = Math.floor(this.now() / this.windowMs);
    const entry = this.producers.get(producerId);
    const count = entry?.window === currentWindow ? entry.count + 1 : 1;

    if (
      entry === undefined &&
      this.producers.size >= this.maxTrackedProducers
    ) {
      this.producers.clear();
    }
    this.producers.set(producerId, { window: currentWindow, count });

    return count <= this.maxBatchesPerWindow;
  }
}

export const defaultRateLimiter = new FixedWindowRateLimiter();
