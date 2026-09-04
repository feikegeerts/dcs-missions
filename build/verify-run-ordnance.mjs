#!/usr/bin/env node

import fs from "node:fs";

function usage() {
  console.error(
    "Usage: node build/verify-run-ordnance.mjs --ndjson <file.ndjson> [--weapons AIM_120C,AIM_9X] [--initiator-type FA-18C_hornet] [--asset-type MiG-29] [--guns]"
  );
}

const argv = process.argv.slice(2);
const options = { weapons: null, initiatorType: null, assetType: null, guns: false, ndjson: null };
for (let index = 0; index < argv.length; index += 1) {
  const argument = argv[index];
  if (argument === "--guns") {
    options.guns = true;
  } else if (argument === "--ndjson" || argument === "--weapons" || argument === "--initiator-type" || argument === "--asset-type") {
    const value = argv[index + 1];
    if (value === undefined) {
      usage();
      process.exitCode = 2;
      process.exit();
    }
    index += 1;
    if (argument === "--ndjson") options.ndjson = value;
    if (argument === "--weapons") options.weapons = value.split(",").filter((item) => item.length > 0);
    if (argument === "--initiator-type") options.initiatorType = value;
    if (argument === "--asset-type") options.assetType = value;
  } else {
    usage();
    process.exitCode = 2;
    process.exit();
  }
}

if (!options.ndjson) {
  usage();
  process.exitCode = 2;
  process.exit();
}

const failures = [];
const results = [];
function assertion(label, condition, detail) {
  if (condition) {
    results.push(`PASS ${label}`);
  } else {
    const suffix = detail ? ` (${detail})` : "";
    results.push(`FAIL ${label}${suffix}`);
    failures.push(label);
  }
}

let events = [];
let parseError = null;
try {
  const text = fs.readFileSync(options.ndjson, "utf8");
  const lines = text.split(/\r?\n/);
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  for (let index = 0; index < lines.length; index += 1) {
    try {
      events.push(JSON.parse(lines[index]));
    } catch (error) {
      parseError = `line ${index + 1}: ${error.message}`;
      break;
    }
  }
} catch (error) {
  parseError = error.message;
}

assertion("every line parses as JSON", parseError === null, parseError);

const sequences = events.map((event) => event && event.event_sequence);
const sequenceOk = parseError === null && sequences.every((sequence, index) => sequence === index + 1);
assertion("event_sequence values are exactly 1..N gapless", sequenceOk);

const lastEvent = events[events.length - 1];
assertion("last event is mission.ended", lastEvent?.event_type === "mission.ended");

const ordnance = events.filter((event) => event?.event_type === "ordnance.fired");
if (options.weapons !== null) {
  const observed = ordnance.map((event) => event.weapon?.dcs_type);
  const counts = new Map();
  for (const weapon of observed) counts.set(weapon, (counts.get(weapon) ?? 0) + 1);
  const expected = options.weapons.every((weapon) => counts.get(weapon) === 1)
    && observed.length === options.weapons.length;
  assertion(
    `exactly one ordnance.fired per listed weapon (${options.weapons.join(",")})`,
    expected,
    `observed ${observed.join(",") || "none"}`
  );
}

if (options.initiatorType !== null) {
  const expected = ordnance.every((event) => event.initiator?.dcs_type === options.initiatorType);
  assertion(`all ordnance initiators are ${options.initiatorType}`, expected);
}

if (options.assetType !== null) {
  const expected = events.some((event) => event?.event_type === "asset.spawned" && event.asset?.dcs_type === options.assetType);
  assertion(`an asset.spawned event has dcs_type ${options.assetType}`, expected);
}

if (options.guns) {
  const expected = ordnance.every((event) => event.weapon?.category === "other-discrete");
  assertion("gun-cell ordnance events are other-discrete", expected);
  console.log(`Observed gun-cell ordnance.fired count: ${ordnance.length}`);
}

for (const result of results) console.log(result);
console.log(`${failures.length === 0 ? "PASS" : "FAIL"} summary: ${failures.length === 0 ? "all assertions passed" : `${failures.length} assertion(s) failed`}`);
process.exitCode = failures.length === 0 ? 0 : 1;
