import { createHash } from "node:crypto";

/**
 * Friendly labels for AI asset instances. These are display labels, not
 * identities: the asset key remains the authoritative technical identity.
 */
export const AI_CALLSIGNS = [
  "Rook",
  "Viper",
  "Banshee",
  "Wraith",
  "Specter",
  "Reaper",
  "Talon",
  "Raven",
  "Falcon",
  "Kestrel",
  "Hawk",
  "Osprey",
  "Condor",
  "Harrier",
  "Saber",
  "Lance",
  "Arrow",
  "Dagger",
  "Hammer",
  "Anvil",
  "Mace",
  "Ghost",
  "Phantom",
  "Shade",
  "Scorpion",
  "Cobra",
  "Mako",
  "Kraken",
  "Wolf",
  "Fox",
  "Lynx",
  "Jackal",
  "Coyote",
  "Badger",
  "Kodiak",
  "Mustang",
  "Comet",
  "Nova",
  "Orion",
  "Atlas",
  "Titan",
  "Echo",
  "Fury",
  "Blaze",
  "Tempest",
  "Warlock",
  "Nomad",
  "Havoc",
  "Striker",
  "Vandal",
] as const;

export type AiCallsignMap = ReadonlyMap<string, string>;

function startIndex(runKey: string, assetKey: string): number {
  const digest = createHash("sha256")
    .update(`dcs-ai-callsign:${runKey}|${assetKey}`)
    .digest("hex");
  return Number.parseInt(digest.slice(0, 8), 16) % AI_CALLSIGNS.length;
}

/**
 * Assign stable, collision-free display names for one run.
 *
 * Asset keys must be supplied in stable first-observed order. In practice that
 * is the order of asset.spawned events, which means a later-spawned asset can
 * never rename an earlier asset. The run key prevents the same asset key in a
 * later mission run from implying the same AI identity.
 */
export function buildAiCallsigns(
  runKey: string,
  assetKeys: readonly string[],
): Map<string, string> {
  const labels = new Map<string, string>();
  const assigned = new Set<string>();

  for (const assetKey of assetKeys) {
    if (assetKey === "" || labels.has(assetKey)) {
      continue;
    }

    const start = startIndex(runKey, assetKey);
    let probe = 0;
    let label: string;
    do {
      const index = (start + probe) % AI_CALLSIGNS.length;
      const cycle = Math.floor(probe / AI_CALLSIGNS.length);
      const base = AI_CALLSIGNS[index];
      label = cycle === 0 ? base : `${base} ${cycle + 1}`;
      probe += 1;
    } while (assigned.has(label));

    labels.set(assetKey, label);
    assigned.add(label);
  }

  return labels;
}
