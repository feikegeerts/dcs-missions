import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const contractRoot = resolve(webRoot, "..");

function readJson(path: string): unknown {
  return JSON.parse(readFileSync(path, "utf8")) as unknown;
}

describe("web telemetry schema copy", () => {
  it("matches the normative contract schema", () => {
    expect(
      readJson(
        resolve(webRoot, "src/telemetry/telemetry-event-v1.schema.json"),
      ),
    ).toEqual(
      readJson(
        resolve(contractRoot, "contracts/telemetry-event-v1.schema.json"),
      ),
    );
  });
});
