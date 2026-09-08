import { execFileSync, spawn } from "node:child_process";
import {
  appendFileSync,
  mkdirSync,
  readFileSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

import { afterEach, beforeAll, describe, expect, it } from "vitest";

import {
  acquireOwnership,
  OwnershipConflictError,
  releaseOwnership,
} from "../src/ownership.js";
import { serviceStatus } from "../src/service.js";
import { DurableSpool } from "../src/spool.js";
import {
  createWorkspace,
  fixture,
  schemaPath,
  type TestWorkspace,
} from "./helpers.js";

const node = process.execPath;
const collectorRoot = join(import.meta.dirname, "..");
const serviceScript = join(collectorRoot, "dist", "src", "service.js");
const collectScript = join(collectorRoot, "dist", "src", "cli.js");
const deliveryScript = join(collectorRoot, "dist", "src", "delivery-cli.js");

describe("OS-held collector ownership", () => {
  let workspace: TestWorkspace | undefined;

  beforeAll(() => {
    execFileSync("npm", ["run", "build"], { cwd: collectorRoot, shell: true });
  });

  afterEach(() => workspace?.cleanup());

  it("rejects sequential, case-alias, and second-state acquisition", async () => {
    workspace = createWorkspace();
    const lock = await acquireOwnership({
      input: workspace.input,
      state: workspace.state,
      schema: schemaPath,
    });
    const ownerBefore = readFileSync(
      join(workspace.state, "owner.json"),
      "utf8",
    );
    try {
      await expect(
        acquireOwnership({
          input: workspace.input,
          state: workspace.state,
          schema: schemaPath,
        }),
      ).rejects.toThrow(/already owned by pid/);
      await expect(
        acquireOwnership({
          input: workspace.input.toUpperCase(),
          state: workspace.state.toUpperCase(),
          schema: schemaPath,
        }),
      ).rejects.toBeInstanceOf(OwnershipConflictError);

      const otherState = join(workspace.root, "other-state");
      mkdirSync(otherState);
      await expect(
        acquireOwnership({
          input: workspace.input,
          state: otherState,
          schema: schemaPath,
        }),
      ).rejects.toThrow(/ownership conflict/);
      expect(readFileSync(join(workspace.state, "owner.json"), "utf8")).toBe(
        ownerBefore,
      );
    } finally {
      await releaseOwnership(lock);
    }
  });

  it("allows independent inputs and states", async () => {
    workspace = createWorkspace();
    const inputB = join(workspace.root, "input-b");
    const stateB = join(workspace.root, "state-b");
    mkdirSync(inputB);
    mkdirSync(stateB);
    const first = await acquireOwnership({
      input: workspace.input,
      state: workspace.state,
      schema: schemaPath,
    });
    const second = await acquireOwnership({
      input: inputB,
      state: stateB,
      schema: schemaPath,
    });
    await releaseOwnership(second);
    await releaseOwnership(first);
  });

  it("reports status while held without acquiring the lock", async () => {
    workspace = createWorkspace();
    const lock = await acquireOwnership({
      input: workspace.input,
      state: workspace.state,
      schema: schemaPath,
    });
    try {
      const status = (await serviceStatus({
        input: workspace.input,
        state: workspace.state,
        schema: schemaPath,
        intervalMs: 5000,
        maxCycleBytes: 1024,
        url: "https://example.invalid",
        token: "",
      })) as { lock: { held: boolean; owner: { pid: number } | null } };
      expect(status.lock.held).toBe(true);
      expect(status.lock.owner?.pid).toBe(process.pid);
    } finally {
      await releaseOwnership(lock);
    }
  });

  it("releases the kernel lock after a child is hard-killed", async () => {
    workspace = createWorkspace();
    const child = startService(workspace);
    await waitForOwner(workspace.state);
    child.kill();
    await waitForExit(child);
    const deadline = Date.now() + 5000;
    let acquired = false;
    while (!acquired && Date.now() < deadline) {
      try {
        const lock = await acquireOwnership({
          input: workspace.input,
          state: workspace.state,
          schema: schemaPath,
        });
        acquired = true;
        await releaseOwnership(lock);
      } catch (error: unknown) {
        if (!(error instanceof OwnershipConflictError)) throw error;
        await delay(50);
      }
    }
    expect(acquired).toBe(true);
  });

  it("returns exit 3 for mutable CLI conflict but permits read-only commands", async () => {
    workspace = createWorkspace();
    const child = startService(workspace);
    await waitForOwner(workspace.state);
    try {
      const common = [
        "--input",
        workspace.input,
        "--state",
        workspace.state,
        "--schema",
        schemaPath,
      ];
      const conflict = spawnSyncResult(collectScript, common);
      expect(conflict.status).toBe(3);
      expect(conflict.stderr).toContain("ownership conflict");
      expect(
        spawnSyncResult(collectScript, [...common, "--dry-run"]).status,
      ).toBe(0);
      expect(
        spawnSyncResult(deliveryScript, ["status", "--state", workspace.state])
          .status,
      ).toBe(0);
      expect(
        spawnSyncResult(deliveryScript, [
          "prune",
          "--state",
          workspace.state,
          "--input",
          workspace.input,
          "--schema",
          schemaPath,
        ]).status,
      ).toBe(3);
      expect(
        spawnSyncResult(
          deliveryScript,
          [
            "--state",
            workspace.state,
            "--input",
            workspace.input,
            "--schema",
            schemaPath,
          ],
          { TELEMETRY_INGEST_TOKEN: "test-only-token" },
        ).status,
      ).toBe(3);
    } finally {
      child.kill();
      await waitForExit(child);
    }
  });

  it("resumes a partial source exactly once after a real process restart", async () => {
    workspace = createWorkspace();
    const started = fixture("01-mission-started.json");
    const fired = fixture("02-ordnance-fired.json");
    const repeated = fixture("03-ordnance-fired-repeat.json");
    const complete = `${JSON.stringify(started)}\n${JSON.stringify(fired)}\n`;
    const pending = JSON.stringify(repeated);
    const split = Math.floor(pending.length / 2);
    const source = join(workspace.input, "restart.ndjson");
    writeFileSync(source, complete + pending.slice(0, split));

    let child = startService(workspace);
    await waitForEventCount(workspace.state, 2);
    child.kill("SIGTERM");
    await waitForExit(child);
    let database = new DurableSpool(join(workspace.state, "collector.sqlite3"));
    expect(database.eventCount()).toBe(2);
    expect(database.getCursor(canonicalServicePath(source))?.offset).toBe(
      Buffer.byteLength(complete),
    );
    database.close();

    appendFileSync(source, `${pending.slice(split)}\n`);
    child = startService(workspace);
    await waitForEventCount(workspace.state, 3);
    child.kill("SIGTERM");
    await waitForExit(child);
    database = new DurableSpool(join(workspace.state, "collector.sqlite3"));
    expect(database.eventCount()).toBe(3);
    expect(database.getCursor(canonicalServicePath(source))?.offset).toBe(
      statSync(source).size,
    );
    database.close();
  });
});

function startService(workspace: TestWorkspace) {
  return spawn(
    node,
    [
      serviceScript,
      "--input",
      workspace.input,
      "--state",
      workspace.state,
      "--schema",
      schemaPath,
      "--interval-ms",
      "200",
    ],
    { stdio: "ignore" },
  );
}

function spawnSyncResult(
  script: string,
  arguments_: string[],
  environment: NodeJS.ProcessEnv = {},
) {
  try {
    const stdout = execFileSync(node, [script, ...arguments_], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, ...environment },
    });
    return { status: 0, stdout, stderr: "" };
  } catch (error: unknown) {
    const result = error as {
      status?: number;
      stdout?: string;
      stderr?: string;
    };
    return {
      status: result.status ?? -1,
      stdout: result.stdout ?? "",
      stderr: result.stderr ?? "",
    };
  }
}

async function waitForOwner(state: string): Promise<void> {
  const path = join(state, "owner.json");
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    try {
      JSON.parse(readFileSync(path, "utf8"));
      return;
    } catch {
      await delay(25);
    }
  }
  throw new Error("timed out waiting for child ownership");
}

async function waitForExit(child: ReturnType<typeof spawn>): Promise<void> {
  if (child.exitCode !== null) return;
  await new Promise<void>((resolvePromise) =>
    child.once("exit", () => resolvePromise()),
  );
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolvePromise) =>
    setTimeout(resolvePromise, milliseconds),
  );
}

async function waitForEventCount(
  state: string,
  expected: number,
): Promise<void> {
  const databasePath = join(state, "collector.sqlite3");
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    try {
      const database = new DurableSpool(databasePath, { readonly: true });
      const count = database.eventCount();
      database.close();
      if (count === expected) return;
    } catch {
      // The service may not have created/migrated the database yet.
    }
    await delay(25);
  }
  throw new Error(`timed out waiting for ${expected} spooled events`);
}

function canonicalServicePath(path: string): string {
  return process.platform === "win32" ? path.toLowerCase() : path;
}
