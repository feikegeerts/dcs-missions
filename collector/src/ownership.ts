import { mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { createConnection, createServer } from "node:net";
import type { Server } from "node:net";
import { join, resolve } from "node:path";

const LOCK_PORT_BASE = 20_000;
const LOCK_PORT_COUNT = 20_000;

export interface OwnershipPaths {
  canonicalInput: string;
  canonicalState: string;
  canonicalSchema: string;
}

export interface OwnerRecord {
  port: number;
  pid: number;
  created_at: string;
  canonical_input: string;
  canonical_state: string;
  canonical_schema: string;
}

export interface OwnershipLock extends OwnershipPaths {
  port: number;
  owner: OwnerRecord;
  server: Server;
}

export class OwnershipConflictError extends Error {
  readonly exitCode = 3;
}

export function canonicalizeOwnershipPaths(options: {
  input: string;
  state: string;
  schema: string;
}): OwnershipPaths {
  mkdirSync(resolve(options.state), { recursive: true });
  return {
    canonicalInput: canonicalPath(options.input),
    canonicalState: canonicalPath(options.state),
    canonicalSchema: canonicalPath(options.schema),
  };
}

function canonicalPath(path: string): string {
  const canonical = realpathSync.native(resolve(path));
  return process.platform === "win32" ? canonical.toLowerCase() : canonical;
}

/** FNV-1a over the canonical input's UTF-8 bytes, mapped to ports 20000-39999. */
export function defaultLockPort(canonicalInput: string): number {
  let hash = 0x811c9dc5;
  for (const byte of Buffer.from(canonicalInput, "utf8")) {
    hash ^= byte;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return LOCK_PORT_BASE + (hash % LOCK_PORT_COUNT);
}

export async function acquireOwnership(options: {
  input: string;
  state: string;
  schema: string;
  port?: number;
  now?: () => Date;
}): Promise<OwnershipLock> {
  const paths = canonicalizeOwnershipPaths(options);
  const port = options.port ?? defaultLockPort(paths.canonicalInput);
  assertPort(port);
  const server = createServer();

  try {
    await new Promise<void>((resolvePromise, reject) => {
      const onError = (error: Error): void => reject(error);
      server.once("error", onError);
      server.listen({ port, host: "127.0.0.1", exclusive: true }, () => {
        server.off("error", onError);
        resolvePromise();
      });
    });
  } catch {
    server.close();
    throw ownershipConflict(paths, port);
  }

  const owner: OwnerRecord = {
    port,
    pid: process.pid,
    created_at: (options.now ?? (() => new Date()))().toISOString(),
    canonical_input: paths.canonicalInput,
    canonical_state: paths.canonicalState,
    canonical_schema: paths.canonicalSchema,
  };
  try {
    writeFileSync(
      join(paths.canonicalState, "owner.json"),
      JSON.stringify(owner),
    );
  } catch {
    // The kernel-held lock remains authoritative; owner.json is diagnostic only.
  }
  return { ...paths, port, owner, server };
}

export async function releaseOwnership(lock: OwnershipLock): Promise<void> {
  if (!lock.server.listening) {
    return;
  }
  await new Promise<void>((resolvePromise, reject) => {
    lock.server.close((error) =>
      error === undefined ? resolvePromise() : reject(error),
    );
  });
}

export function readOwner(state: string): OwnerRecord | null {
  try {
    const value = JSON.parse(
      readFileSync(join(state, "owner.json"), "utf8"),
    ) as unknown;
    return isOwnerRecord(value) ? value : null;
  } catch {
    return null;
  }
}

export async function isLockHeld(port: number): Promise<boolean> {
  assertPort(port);
  return await new Promise<boolean>((resolvePromise) => {
    const socket = createConnection({ port, host: "127.0.0.1" });
    socket.once("connect", () => {
      socket.destroy();
      resolvePromise(true);
    });
    socket.once("error", () => {
      socket.destroy();
      resolvePromise(false);
    });
  });
}

function ownershipConflict(
  paths: OwnershipPaths,
  port: number,
): OwnershipConflictError {
  const owner = readOwner(paths.canonicalState);
  if (owner === null) {
    return new OwnershipConflictError(
      `ownership conflict: port ${port} is in use by an unknown process`,
    );
  }
  if (
    owner.canonical_input !== paths.canonicalInput ||
    owner.canonical_state !== paths.canonicalState
  ) {
    return new OwnershipConflictError(
      "ownership conflict: input already owned with a different state directory",
    );
  }
  return new OwnershipConflictError(
    `ownership conflict: input already owned by pid ${owner.pid} on port ${owner.port} (state ${owner.canonical_state}, since ${owner.created_at})`,
  );
}

function assertPort(port: number): void {
  if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) {
    throw new Error("lock port must be an integer from 1 through 65535");
  }
}

function isOwnerRecord(value: unknown): value is OwnerRecord {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return false;
  }
  const record = value as Record<string, unknown>;
  return (
    typeof record.port === "number" &&
    typeof record.pid === "number" &&
    typeof record.created_at === "string" &&
    typeof record.canonical_input === "string" &&
    typeof record.canonical_state === "string" &&
    typeof record.canonical_schema === "string"
  );
}
