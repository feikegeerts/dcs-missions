import type {
  CatalogueDeviation,
  CatalogueExclusion,
  OrdinanceCatalogue,
  OrdinanceCatalogueItem,
} from "./types";
import { ordnanceCatalogueV1 } from "./ordnance-v1";

/**
 * Ordnance valuation catalogue, version 2.
 *
 * Human-reviewed v2 values (effective 2026-09-13). Version 2 carries every
 * version 1 item forward unchanged (imported, never re-stated) and adds five
 * keys established by the final duel-dynamic mission and the unattended
 * AI-vs-AI runs of 2026-09-13: the two R-27-family missiles promoted by live
 * ordnance.fired evidence (`P_27PE`, `P_27TE`), the `R-3R` source-only key
 * proven by the final mission's MiG-21Bis pylon inventory, and the two bandit
 * donor airframes observed live (`MiG-29S`, `Su-33`). Historical version 1
 * values remain untouched and must never be rewritten.
 */

const RUN_1 = "run-20260913T085237Z-71b1d0b4";
const RUN_2 = "run-20260913T101940Z-5803a5a9";
const LIVE_EVIDENCE = `unattended AI-vs-AI runs ${RUN_1} and ${RUN_2}`;

const v2NewItems: readonly OrdinanceCatalogueItem[] = [
  {
    dcs_type: "P_27PE",
    display_name: "R-27ER (DCS identifier P_27PE)",
    faction: "red",
    category: "missile",
    usd_value: 800000,
    value_basis: "estimate",
    source:
      "Human-reviewed replacement-equivalent order-of-magnitude score estimate: previous-generation semi-active radar BVR, anchored below the R-77 (P_77, $1,100,000) active-radar value and above the R-73 (P_73, $300,000) infrared value; no dependable public recurring unit-cost source was found.",
    matrix_status: "verified",
    matrix_evidence: `live ordnance.fired events, weapon dcs_type P_27PE, initiators dcs_type MiG-29S and Su-33 (${LIVE_EVIDENCE})`,
    notes:
      "DCS internal identifier P_27PE; installed r27_family.lua display name 'R-27ER (AA-10 Alamo C)'. Pylon CLSID {E8069896-8435-4B90-95C0-01A03AE6E400} on the MiG-29S and Su-33 units of the final duel-dynamic .miz; Su-34.lua declares the same CLSID as AKU_R27ER.",
  },
  {
    dcs_type: "P_27TE",
    display_name: "R-27ET (DCS identifier P_27TE)",
    faction: "red",
    category: "missile",
    usd_value: 500000,
    value_basis: "estimate",
    source:
      "Human-reviewed replacement-equivalent order-of-magnitude score estimate: infrared BVR, anchored above the R-73 (P_73, $300,000) infrared dogfight value and below the R-27ER (P_27PE, $800,000) BVR value; no dependable public recurring unit-cost source was found.",
    matrix_status: "verified",
    matrix_evidence: `live ordnance.fired events, weapon dcs_type P_27TE, initiator dcs_type Su-33 (${LIVE_EVIDENCE})`,
    notes:
      "DCS internal identifier P_27TE; installed r27_family.lua display name 'R-27ET (AA-10 Alamo D)'. Pylon CLSID {B79C379A-9E87-4E50-A1EE-7F7E29C2E87A} on the Su-33 units of the final duel-dynamic .miz (Su-33-only pylon).",
  },
  {
    dcs_type: "R-3R",
    display_name: "R-3R (Soviet semi-active radar AAM)",
    faction: "red",
    category: "missile",
    usd_value: 75000,
    value_basis: "estimate",
    source:
      "Human-reviewed replacement-equivalent order-of-magnitude score estimate: same R-3 family as R-3S ($50,000) with a semi-active radar seeker, anchored below the R-60 ($100,000) infrared value; no dependable public recurring unit-cost source was found.",
    matrix_status: "source-only",
    matrix_evidence:
      "none (the 2026-09-13 unattended runs never drew the MiG-21Bis donor; no live ordnance.fired observation)",
    notes:
      "The final duel-dynamic .miz MiG-21Bis unit (Bandit-10) carries the {R-3R} pylon, matching the installed MiG-21bis UnitPayloads. The v1 research backlog listed R-3R for a live MiG-21 probe; until such a probe passes it is held at source-only status, mirroring the v1 R-60 treatment.",
  },
  {
    dcs_type: "MiG-29S",
    display_name: "MiG-29S Fulcrum",
    faction: "red",
    category: "aircraft",
    usd_value: 11000000,
    value_basis: "estimate",
    source:
      "Human-reviewed aircraft score-scale estimate anchored to the v1 MiG-29 Fulcrum ($11,000,000) of the same airframe family; not asserted as a historical or current procurement unit cost.",
    matrix_status: "verified",
    matrix_evidence: `asset.spawned and ordnance.fired initiator dcs_type MiG-29S (${LIVE_EVIDENCE})`,
    notes:
      "DCS type MiG-29S (single-seat Fulcrum), a distinct key from the v1 'MiG-29 Fulcrum' airframe.",
  },
  {
    dcs_type: "Su-33",
    display_name: "Su-33 Flanker-S",
    faction: "red",
    category: "aircraft",
    usd_value: 25000000,
    value_basis: "estimate",
    source:
      "Human-reviewed aircraft score-scale estimate: single-seat twin-engine Flanker, anchored below the v1 Su-34 Fullback ($30,000,000) twin-seat heavy and above the v1 MiG-29 Fulcrum ($11,000,000); not asserted as a historical or current procurement unit cost.",
    matrix_status: "verified",
    matrix_evidence: `asset.spawned and ordnance.fired initiator dcs_type Su-33 (${LIVE_EVIDENCE})`,
    notes: "DCS type Su-33 (naval Flanker-S).",
  },
];

const v2NewDeviations: readonly CatalogueDeviation[] = [
  {
    airframe: "MiG-29S",
    cell: "live-ai-20260913",
    loadout_key: "R-27ER",
    expected_dcs_type: "R-27ER",
    observed_dcs_type: "P_27PE",
    explanation:
      "This install has no R-27ER Lua weapon-pack table; DCS emits the internal identifier P_27PE (r27_family.lua name='P_27PE', display 'R-27ER (AA-10 Alamo C)'). Observed live from the {E8069896-8435-4B90-95C0-01A03AE6E400} pylons of the final duel-dynamic .miz MiG-29S and Su-33 units.",
  },
  {
    airframe: "Su-33",
    cell: "live-ai-20260913",
    loadout_key: "R-27ET",
    expected_dcs_type: "R-27ET",
    observed_dcs_type: "P_27TE",
    explanation:
      "This install has no R-27ET Lua weapon-pack table; DCS emits the internal identifier P_27TE (r27_family.lua name='P_27TE', display 'R-27ET (AA-10 Alamo D)'). Observed live from the {B79C379A-9E87-4E50-A1EE-7F7E29C2E87A} pylons of the final duel-dynamic .miz Su-33 units.",
  },
];

const v2OutOfScope: readonly CatalogueExclusion[] = [
  {
    key: "guns",
    reason:
      "Guns are unpriced in v1. The gun cell (g01) emitted zero ordnance events, so no gun dcs_type key was observed to price; gun pricing is deferred to a later catalogue version.",
  },
  {
    key: "R-24R, R-24T, R-33",
    reason:
      "Catalogue-only weapons (Slice 11): no installed airframe in the mission set carries a verified runnable cell for them, so their dcs_type is unverified. Deferred to a future catalogue version. (R-27ER and R-27ET left this exclusion in version 2 after live ordnance.fired observations.)",
  },
  {
    key: "AIM-7E, AIM-7E-2, SeaSparrow (RIM-7M)",
    reason:
      "Defined in aim7_family.lua but no mission airframe carries these pylon CLSIDs (the FA-18C_hornet pylons are M/F/H/P; SeaSparrow is the ship-mounted RIM-7M SAM). Emits as unpriced by design; revisit if the mission airframe set changes.",
  },
  {
    key: "CATM-9M, CAIM-120",
    reason:
      "Training/inert missile variants in the F-15ESE UnitPayloads; they produce no live ordnance.fired events, so there is no live dcs_type to price.",
  },
];

export const ordnanceCatalogueV2: OrdinanceCatalogue = {
  catalogue: "ordnance",
  version: 2,
  effective_date: "2026-09-13",
  currency: "USD",
  pricing_convention: `${ordnanceCatalogueV1.pricing_convention} Version 2 carries every version 1 value forward unchanged and adds five keys grounded in the final duel-dynamic mission and the 2026-09-13 live evidence named in type_key_source; the new missile values follow the same human-reviewed order-of-magnitude convention, and the new aircraft values follow the v1 score scale.`,
  type_key_source: `${ordnanceCatalogueV1.type_key_source} Version 2 additions: live ordnance.fired events (${LIVE_EVIDENCE}) and the final duel-dynamic .miz pylon inventory, cross-checked against the installed DCS weapon definitions (CoreMods/aircraft/AircraftWeaponPack/r27_family.lua display names), aircraft UnitPayloads, and module pylon sources (Su-34.lua AKU_R27ER/AKU_R77 declarations).`,
  items: [...ordnanceCatalogueV1.items, ...v2NewItems],
  deviations: [...ordnanceCatalogueV1.deviations, ...v2NewDeviations],
  out_of_scope: v2OutOfScope,
};
