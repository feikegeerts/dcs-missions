import type { OrdinanceCatalogue } from "./types";

/**
 * Ordnance valuation catalogue, version 1.
 *
 * Human-reviewed v1 values (effective 2026-09-04). One nominal USD score value
 * is assigned to each of 24 in-scope dcs_type keys. This is intentionally not
 * a global DCS type catalogue: it covers the Slice 11 mission matrix and four
 * source-only keys proven reachable from that matrix's airframes. Unknown keys
 * stay unpriced. Historical version 1 values must never be rewritten.
 */
export const ordnanceCatalogueV1 = {
  catalogue: "ordnance",
  version: 1,
  effective_date: "2026-09-04",
  currency: "USD",
  pricing_convention:
    "Current or replacement-equivalent nominal USD score valuations as of the effective date, not a claim about historical acquisition cost. AIM-9X uses the cited FY 2026 Navy recurring All Up Round unit cost rounded to the nearest dollar. Every other missile value is a human-reviewed relative-capability estimate; Soviet/Russian values are order-of-magnitude estimates. Aircraft values are score-scale estimates and are not comparable procurement costs. Package announcements and support-inclusive sale totals are not divided into unit prices.",
  type_key_source:
    "Slice 11 live dcs_type matrix results and the matching installed DCS weapon definitions, aircraft UnitPayloads, and pylon definitions. The public cross-checks and limits are recorded in docs/telemetry/ordnance-catalogue-v1-research.md. This is coverage for the configured matrix, not all DCS aircraft or weapons.",
  items: [
    {
      dcs_type: "AIM-9L",
      display_name: "AIM-9L Sidewinder",
      faction: "blue",
      category: "missile",
      usd_value: 175000,
      value_basis: "estimate",
      source:
        "Human-reviewed replacement-equivalent score estimate below the FY 2026 AIM-9X Block II AUR anchor; no dependable public AIM-9L recurring unit-cost source was found.",
      matrix_status: "verified",
      matrix_evidence: "b01",
      notes: "",
    },
    {
      dcs_type: "AIM_9",
      display_name: "AIM-9M Sidewinder (DCS name AIM_9)",
      faction: "blue",
      category: "missile",
      usd_value: 225000,
      value_basis: "estimate",
      source:
        "Human-reviewed replacement-equivalent score estimate below the FY 2026 AIM-9X Block II AUR anchor; no dependable public AIM-9M recurring unit-cost source was found.",
      matrix_status: "verified",
      matrix_evidence: "b02, b09, b15",
      notes: `DCS name "AIM_9" is the AIM-9M (aim9_family.lua name="AIM_9", username="AIM-9M").`,
    },
    {
      dcs_type: "AIM-9P",
      display_name: "AIM-9P Sidewinder",
      faction: "blue",
      category: "missile",
      usd_value: 125000,
      value_basis: "estimate",
      source:
        "Human-reviewed replacement-equivalent score estimate below the AIM-9L/M and FY 2026 AIM-9X Block II valuations; no dependable public variant unit-cost source was found.",
      matrix_status: "verified",
      matrix_evidence: "b03, b13",
      notes: "",
    },
    {
      dcs_type: "AIM-9P5",
      display_name: "AIM-9P5 Sidewinder",
      faction: "blue",
      category: "missile",
      usd_value: 200000,
      value_basis: "estimate",
      source:
        "Human-reviewed replacement-equivalent score estimate above AIM-9P and below the FY 2026 AIM-9X Block II AUR anchor; no dependable public variant unit-cost source was found.",
      matrix_status: "verified",
      matrix_evidence: "b14",
      notes: "",
    },
    {
      dcs_type: "AIM_9X",
      display_name: "AIM-9X Block II Sidewinder",
      faction: "blue",
      category: "missile",
      usd_value: 447093,
      value_basis: "sourced",
      source:
        "Department of Defense FY 2026 Budget Estimates, Navy, Weapons Procurement justification book (June 2025), LI 2209 Sidewinder, Exhibit P-5, Navy page 3 of 20, cost element 1.1.1: FY 2026 recurring All Up Round - Block II unit cost $447,092.74; rounded to $447,093. Archived source: https://web.archive.org/web/20250702015950id_/https://www.secnav.navy.mil/fmc/fmb/Documents/26pres/WPN_Book.pdf",
      matrix_status: "verified",
      matrix_evidence: "b04, b06",
      notes: "",
    },
    {
      dcs_type: "AIM_120",
      display_name: "AIM-120B AMRAAM (DCS name AIM_120)",
      faction: "blue",
      category: "missile",
      usd_value: 900000,
      value_basis: "estimate",
      source:
        "Human-reviewed replacement-equivalent score estimate below AIM-120C; no dependable public AIM-120B recurring unit-cost source was found.",
      matrix_status: "verified",
      matrix_evidence: "b07",
      notes: `DCS name "AIM_120" is the AIM-120B (aim120_family.lua name="AIM_120", username="AIM-120B").`,
    },
    {
      dcs_type: "AIM_120C",
      display_name: "AIM-120C AMRAAM",
      faction: "blue",
      category: "missile",
      usd_value: 1050000,
      value_basis: "estimate",
      source:
        "Human-reviewed replacement-equivalent score estimate above AIM-120B; no dependable public AIM-120C recurring unit-cost source was found.",
      matrix_status: "verified",
      matrix_evidence: "b05, b08, b10 (deviation)",
      notes: "",
    },
    {
      dcs_type: "AIM_7",
      display_name: "AIM-7M Sparrow (DCS name AIM_7)",
      faction: "blue",
      category: "missile",
      usd_value: 300000,
      value_basis: "estimate",
      source:
        "Human-reviewed replacement-equivalent score estimate. The often-repeated public $125,000 figure lacks dependable year and variant attribution, so it is not treated as a sourced AIM-7M unit cost.",
      matrix_status: "source-only",
      matrix_evidence:
        'none (FA-18C_hornet UnitPayloads "AIM-7M*2" loadouts, CLSID {LAU-115 - AIM-7M}; not covered by the Slice 11 matrix)',
      notes:
        'Emittable from the FA-18C_hornet player ME. The F-15ESE "AIM-7M" loadouts resolve to AIM-7MH instead (its pylon CLSID is {AIM-7H}; cell b11).',
    },
    {
      dcs_type: "AIM-7F",
      display_name: "AIM-7F Sparrow",
      faction: "blue",
      category: "missile",
      usd_value: 250000,
      value_basis: "estimate",
      source:
        "Human-reviewed replacement-equivalent score estimate below the AIM-7M/H valuation; no dependable public AIM-7F recurring unit-cost source was found.",
      matrix_status: "source-only",
      matrix_evidence:
        "none (FA-18C_hornet pylon CLSIDs {AIM-7F}/{LAU-115 - AIM-7F}; not covered by the Slice 11 matrix)",
      notes:
        "Reachable via manual FA-18C_hornet loadout placement (no preset loadout uses the F model).",
    },
    {
      dcs_type: "AIM-7MH",
      display_name: "AIM-7M/H Sparrow (DCS name AIM-7MH)",
      faction: "blue",
      category: "missile",
      usd_value: 300000,
      value_basis: "estimate",
      source:
        "Human-reviewed replacement-equivalent score estimate. The often-repeated public $125,000 figure lacks dependable year and variant attribution, so it is not treated as a sourced AIM-7M/H unit cost.",
      matrix_status: "verified",
      matrix_evidence: "b11 (deviation)",
      notes: `DCS name "AIM-7MH" is the AIM-7M/H family; the F-15ESE AIM-7 pylon CLSID {AIM-7H} resolves to the H model (Slice 11 b11). Also emittable from the FA-18C_hornet {AIM-7H}/{LAU-115 - AIM-7H} pylon entries.`,
    },
    {
      dcs_type: "AIM-7P",
      display_name: "AIM-7P Sparrow",
      faction: "blue",
      category: "missile",
      usd_value: 350000,
      value_basis: "estimate",
      source:
        "Human-reviewed replacement-equivalent score estimate above the AIM-7M/H valuation; no dependable public AIM-7P recurring unit-cost source was found.",
      matrix_status: "source-only",
      matrix_evidence:
        "none (FA-18C_hornet pylon CLSIDs {AIM-7P}/{LAU-115 - AIM-7P}; not covered by the Slice 11 matrix)",
      notes:
        "Reachable via manual FA-18C_hornet loadout placement (no preset loadout uses the P model).",
    },
    {
      dcs_type: "GAR-8",
      display_name: "AIM-9B Sidewinder (DCS name GAR-8)",
      faction: "blue",
      category: "missile",
      usd_value: 75000,
      value_basis: "estimate",
      source:
        "Human-reviewed replacement-equivalent score estimate at the bottom of the in-scope Sidewinder family; no dependable public variant unit-cost source was found.",
      matrix_status: "verified",
      matrix_evidence: "b12",
      notes: `DCS name "GAR-8" is the AIM-9B (aim9_family.lua name="GAR-8"), observed on F-5E-3 (Slice 11 b12). The F-5E/F-5E-3 "AIM-9*2" loadouts use the same {AIM-9B} pylon.`,
    },
    {
      dcs_type: "R-3S",
      display_name: "R-3S (Soviet infrared AAM)",
      faction: "red",
      category: "missile",
      usd_value: 50000,
      value_basis: "estimate",
      source:
        "Human-reviewed replacement-equivalent order-of-magnitude score estimate; no dependable public recurring unit-cost source was found.",
      matrix_status: "verified",
      matrix_evidence: "r01",
      notes: "",
    },
    {
      dcs_type: "R-60",
      display_name: "R-60 (Soviet infrared AAM)",
      faction: "red",
      category: "missile",
      usd_value: 100000,
      value_basis: "estimate",
      source:
        "Human-reviewed replacement-equivalent order-of-magnitude score estimate above R-3S; no dependable public recurring unit-cost source was found.",
      matrix_status: "source-only",
      matrix_evidence: "none (no-shot cells r02, r03)",
      notes:
        'No ordnance event observed in Slice 11; dcs_type is the DCS weapon pack name (R_60.lua name="R-60") and the MiG-21Bis/MiG-29 Fulcrum airframes are proven via asset.spawned.',
    },
    {
      dcs_type: "P_73",
      display_name: "R-73 (DCS identifier P_73)",
      faction: "red",
      category: "missile",
      usd_value: 300000,
      value_basis: "estimate",
      source:
        "Human-reviewed replacement-equivalent order-of-magnitude score estimate below the FY 2026 AIM-9X Block II AUR anchor; no dependable public recurring unit-cost source was found.",
      matrix_status: "verified",
      matrix_evidence: "r05 (deviation)",
      notes:
        "DCS internal identifier P_73 (Russian export designation of the R-73; no R-73 Lua weapon pack in this install). Observed on Su-34 (Slice 11 r05); the MiG-29 R-73 cell (r04) was no-shot.",
    },
    {
      dcs_type: "P_77",
      display_name: "R-77 (DCS identifier P_77)",
      faction: "red",
      category: "missile",
      usd_value: 1100000,
      value_basis: "estimate",
      source:
        "Human-reviewed replacement-equivalent order-of-magnitude score estimate in the in-scope active-radar BVR class; no dependable public recurring unit-cost source was found.",
      matrix_status: "verified",
      matrix_evidence: "r06 (deviation)",
      notes:
        "DCS internal identifier P_77 (the FA-18C DTC threat database groups R-77 threats under wstype P_77_); no R-77 Lua weapon pack in this install. Observed on Su-34 (Slice 11 r06).",
    },
    {
      dcs_type: "FA-18C_hornet",
      display_name: "F/A-18C Hornet",
      faction: "blue",
      category: "aircraft",
      usd_value: 29000000,
      value_basis: "estimate",
      source:
        "Human-reviewed aircraft score-scale estimate; not asserted as a historical or current procurement unit cost.",
      matrix_status: "verified",
      matrix_evidence:
        "b01-b05 (initiator); also bandit b09-b11, blue r02-r04, g01",
      notes: "",
    },
    {
      dcs_type: "F-16C_50",
      display_name: "F-16C Block 50 Fighting Falcon",
      faction: "blue",
      category: "aircraft",
      usd_value: 33000000,
      value_basis: "estimate",
      source:
        "Human-reviewed aircraft score-scale estimate; not asserted as a historical or current procurement unit cost.",
      matrix_status: "verified",
      matrix_evidence: "b06-b08",
      notes: "",
    },
    {
      dcs_type: "F-15ESE",
      display_name: "F-15ESE Strike Eagle",
      faction: "blue",
      category: "aircraft",
      usd_value: 41000000,
      value_basis: "estimate",
      source:
        "Human-reviewed aircraft score-scale estimate; not asserted as a historical or current procurement unit cost.",
      matrix_status: "verified",
      matrix_evidence: "b09-b11",
      notes: "",
    },
    {
      dcs_type: "F-5E-3",
      display_name: "F-5E-3 Tiger II",
      faction: "blue",
      category: "aircraft",
      usd_value: 4000000,
      value_basis: "estimate",
      source:
        "Human-reviewed aircraft score-scale estimate; not asserted as a historical or current procurement unit cost.",
      matrix_status: "verified",
      matrix_evidence: "b12-b14",
      notes: "",
    },
    {
      dcs_type: "A-10C_2",
      display_name: "A-10C II Thunderbolt II",
      faction: "blue",
      category: "aircraft",
      usd_value: 13000000,
      value_basis: "estimate",
      source:
        "Human-reviewed aircraft score-scale estimate; not asserted as a historical or current procurement unit cost.",
      matrix_status: "verified",
      matrix_evidence: "b15",
      notes:
        "Weakest estimate in v1 (few public unit-cost figures); order of magnitude.",
    },
    {
      dcs_type: "MiG-21Bis",
      display_name: "MiG-21Bis Fishbed",
      faction: "red",
      category: "aircraft",
      usd_value: 500000,
      value_basis: "estimate",
      source:
        "Human-reviewed aircraft score-scale estimate; not asserted as a historical or current procurement unit cost.",
      matrix_status: "verified",
      matrix_evidence: "r01, r02 (asset.spawned)",
      notes: `Wikipedia: the MiG-21 was very cheap (MiG-21MF cheaper than a BMP-1; https://en.wikipedia.org/wiki/Mikoyan-Gurevich_MiG-21); 1990s used-bis export sales were around US$200,000 each.`,
    },
    {
      dcs_type: "MiG-29 Fulcrum",
      display_name: "MiG-29 Fulcrum",
      faction: "red",
      category: "aircraft",
      usd_value: 11000000,
      value_basis: "estimate",
      source:
        "Human-reviewed aircraft score-scale estimate; not asserted as a historical or current procurement unit cost.",
      matrix_status: "verified",
      matrix_evidence: "r03, r04 (asset.spawned)",
      notes: "",
    },
    {
      dcs_type: "Su-34",
      display_name: "Su-34 Fullback",
      faction: "red",
      category: "aircraft",
      usd_value: 30000000,
      value_basis: "estimate",
      source:
        "Human-reviewed aircraft score-scale estimate; not asserted as a historical or current procurement unit cost.",
      matrix_status: "verified",
      matrix_evidence: "r05, r06",
      notes: "",
    },
  ],
  deviations: [
    {
      airframe: "F-15ESE",
      cell: "b10",
      loadout_key: "AIM-120B",
      expected_dcs_type: "AIM_120",
      observed_dcs_type: "AIM_120C",
      explanation:
        'The F-15ESE "AIM-120B" loadouts (F-15ESE.lua lines 297/333) use CLSID {40EF17B7-F508-45de-8566-6FFECC0C1AB8}, the same CLSID the file\'s AIM-120C loadouts use. The F-15E module has no separate AIM-120B weapon model, so the loadout resolves to the AIM-120C model and DCS emits AIM_120C. Contrast F-16C_50 (b07, PASS): its AIM-120B pylon uses the distinct CLSID {C8E06185-7CD6-4C90-959F-044679E90751} and emits AIM_120.',
    },
    {
      airframe: "F-15ESE",
      cell: "b11",
      loadout_key: "AIM-7M",
      expected_dcs_type: "AIM_7",
      observed_dcs_type: "AIM-7MH",
      explanation:
        "The F-15ESE AIM-7 pylon entries (F-15ESE.lua lines 736/740) use CLSID {AIM-7H}, whose runtime type is AIM-7MH — not the base AIM_7 pack name from aim7_family.lua.",
    },
    {
      airframe: "Su-34",
      cell: "r05",
      loadout_key: "R-73",
      expected_dcs_type: "R-73",
      observed_dcs_type: "P_73",
      explanation:
        "This install has no R-73 Lua weapon-pack table; DCS emits the internal identifier P_73 (the Russian export designation of the R-73; MiG-29-Fulcrum.lua line 1328 declares the R-73 with the P_73 identifier).",
    },
    {
      airframe: "Su-34",
      cell: "r06",
      loadout_key: "R-77",
      expected_dcs_type: "R-77",
      observed_dcs_type: "P_77",
      explanation:
        "This install has no R-77 Lua weapon-pack table; DCS emits the internal identifier P_77 (the FA-18C DTC threat database groups R-77 threats under wstype P_77_ in FA-18C\\DTC\\threat_base.lua).",
    },
  ],
  out_of_scope: [
    {
      key: "guns",
      reason:
        "Guns are unpriced in v1. The gun cell (g01) emitted zero ordnance events, so no gun dcs_type key was observed to price; gun pricing is deferred to a later catalogue version.",
    },
    {
      key: "R-27ER, R-27ET, R-24R, R-24T, R-33",
      reason:
        "Catalogue-only weapons (Slice 11): no installed airframe in the matrix set carries a verified runnable cell for them, so their dcs_type is unverified. Deferred to a future catalogue version.",
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
  ],
} as const satisfies OrdinanceCatalogue;
