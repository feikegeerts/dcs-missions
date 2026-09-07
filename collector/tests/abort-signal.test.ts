import type { execFileSync } from "node:child_process";

import { describe, expect, it } from "vitest";

import {
  classifyProcessRecord,
  decideAbortSignal,
  defaultProcessObservationProvider,
  runObservations,
  stopObservations,
  type ProcessBinding,
} from "../src/abort-signal.js";

const binding: ProcessBinding = {
  pid: 4242,
  creationTime: "2026-09-07T10:00:00.000Z",
  runKey: "run-bound",
  hookGeneration: 12,
  expectedImage: "DCS_server.exe",
  commandLineScope: "DCS.dcs_serverrelease",
  profilePath: String.raw`C:\Users\operator\Saved Games\DCS.dcs_serverrelease`,
  inputPath: String.raw`C:\Users\operator\Saved Games\DCS.dcs_serverrelease\Logs\telemetry`,
};

describe("abort signal decision", () => {
  it.each([
    [true, "known-running", undefined, null],
    [true, "known-not-running", 9, null],
    [false, "known-running", 9, "simulation-stop-observed"],
    [false, "known-not-running", 9, "simulation-stop-observed"],
    [false, "known-not-running", undefined, "dcs-process-not-running"],
    [false, "known-running", undefined, null],
    [false, "unknown", undefined, null],
  ] as const)(
    "ended=%s process=%s stopGeneration=%s gives %s",
    (hasMissionEnded, processState, stopGeneration, reason) => {
      expect(
        decideAbortSignal({
          producerId: "producer-a",
          runKey: "run-a",
          hasMissionEnded,
          processState,
          ...(stopGeneration === undefined ? {} : { stopGeneration }),
        }),
      ).toMatchObject({ producerId: "producer-a", runKey: "run-a", reason });
    },
  );

  it("does not treat remote heartbeat absence as process death", () => {
    expect(
      decideAbortSignal({
        producerId: "producer-a",
        runKey: "run-a",
        hasMissionEnded: false,
        processState: "known-running",
        remoteHeartbeatState: "absent",
      }).reason,
    ).toBeNull();
  });
});

describe("process-generation observation", () => {
  it("reports known-running only for matching PID, creation time, image, and scope", () => {
    expect(
      classifyProcessRecord(binding, {
        pid: 4242,
        creationTime: "2026-09-07T10:00:00.0000000Z",
        image: "DCS_server.exe",
        commandLine: String.raw`D:\DCS\bin\DCS_server.exe -w DCS.dcs_serverrelease`,
      }),
    ).toMatchObject({ state: "known-running", pid: 4242 });
  });

  it("reports known-not-running when the bound PID is absent or reused", () => {
    expect(classifyProcessRecord(binding, null).state).toBe(
      "known-not-running",
    );
    expect(
      classifyProcessRecord(binding, {
        pid: 4242,
        creationTime: "2026-09-07T11:00:00.000Z",
        image: "DCS_server.exe",
        commandLine: "DCS.dcs_serverrelease",
      }).state,
    ).toBe("known-not-running");
  });

  it("keeps mismatched or unavailable scope evidence unknown", () => {
    expect(
      classifyProcessRecord(binding, {
        pid: 4242,
        creationTime: binding.creationTime,
        image: "DCS_server.exe",
        commandLine: "different-profile",
      }).state,
    ).toBe("unknown");
    expect(defaultProcessObservationProvider(undefined)).toEqual({
      state: "unknown",
    });
  });

  it("keeps process query failures and non-Windows detection unknown", () => {
    const failingExecute = (() => {
      throw new Error("CIM unavailable");
    }) as typeof execFileSync;

    expect(
      defaultProcessObservationProvider(binding, "win32", failingExecute),
    ).toEqual({ state: "unknown" });
    expect(defaultProcessObservationProvider(binding, "linux")).toEqual({
      state: "unknown",
    });
  });
});

describe("STOP line parsing", () => {
  it("captures the producer, run, and hook generation handshake", () => {
    expect(
      runObservations(
        "TELEMETRY_BRIDGE_HOOK handshake-ok generation=8 run=run-bound producer=dcs-server-alpha",
      ),
    ).toEqual([
      {
        generation: 8,
        runKey: "run-bound",
        producerId: "dcs-server-alpha",
      },
    ]);
  });

  it("captures generation and run key from matching STOP lines", () => {
    const text = [
      "unrelated log noise",
      "2026 INFO TELEMETRY_BRIDGE_HOOK STOP generation=8 spooled=4 spool=C:/Saved Games/DCS.dcs_serverrelease/Logs/telemetry/run-20260907T000000Z-89abcdef.ndjson failures=0 stuck=nil unspooled=0",
      "2026 INFO OTHER STOP generation=8 spooled=4 spool=C:/tmp/wrong.ndjson failures=0 stuck=nil unspooled=0",
    ].join("\n");

    expect(stopObservations(text)).toEqual([
      { generation: 8, runKey: "run-20260907T000000Z-89abcdef" },
    ]);
  });

  it("handles backslash spool paths", () => {
    const text = String.raw`TELEMETRY_BRIDGE_HOOK STOP generation=3 spooled=2 spool=C:\Saved Games\DCS\Logs\telemetry\run-backslash.ndjson failures=0 stuck=nil unspooled=0`;

    expect(stopObservations(text)).toEqual([
      { generation: 3, runKey: "run-backslash" },
    ]);
  });

  it("returns no observations for empty text", () => {
    expect(stopObservations("")).toEqual([]);
  });
});
