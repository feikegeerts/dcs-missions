import { describe, expect, it } from "vitest";

import {
  CATALOGUE_CATEGORIES,
  ordnanceCatalogueV1,
  ordnanceCatalogueV2,
  resolveValuation,
  validateCatalogue,
  type OrdinanceCatalogue,
} from "../src/telemetry/catalogue";

type Mutable<T> = T extends readonly (infer Item)[]
  ? Mutable<Item>[]
  : T extends object
    ? { -readonly [Key in keyof T]: Mutable<T[Key]> }
    : T;

function mutated(
  mutate: (catalogue: Mutable<OrdinanceCatalogue>) => void,
): OrdinanceCatalogue {
  const clone = JSON.parse(
    JSON.stringify(ordnanceCatalogueV1),
  ) as Mutable<OrdinanceCatalogue>;
  mutate(clone);
  return clone;
}

describe("ordnanceCatalogueV1", () => {
  it("passes structural validation", () => {
    expect(validateCatalogue(ordnanceCatalogueV1)).toEqual([]);
  });

  it("carries exactly the 24 reviewed v1 items (16 missiles, 8 aircraft)", () => {
    expect(ordnanceCatalogueV1.items).toHaveLength(24);
    expect(
      ordnanceCatalogueV1.items.filter((item) => item.category === "missile"),
    ).toHaveLength(16);
    expect(
      ordnanceCatalogueV1.items.filter((item) => item.category === "aircraft"),
    ).toHaveLength(8);
    expect(
      ordnanceCatalogueV1.items.map((item) => item.dcs_type).sort(),
    ).toEqual(
      [
        "AIM-7MH",
        "AIM-7F",
        "AIM-7P",
        "AIM-9L",
        "AIM-9P",
        "AIM-9P5",
        "AIM_120",
        "AIM_120C",
        "AIM_7",
        "AIM_9",
        "AIM_9X",
        "A-10C_2",
        "FA-18C_hornet",
        "F-15ESE",
        "F-16C_50",
        "F-5E-3",
        "GAR-8",
        "MiG-21Bis",
        "MiG-29 Fulcrum",
        "P_73",
        "P_77",
        "R-3S",
        "R-60",
        "Su-34",
      ].sort(),
    );
  });

  it("records version 1 with a calendar effective date and USD", () => {
    expect(ordnanceCatalogueV1.catalogue).toBe("ordnance");
    expect(ordnanceCatalogueV1.version).toBe(1);
    expect(ordnanceCatalogueV1.effective_date).toBe("2026-09-04");
    expect(ordnanceCatalogueV1.currency).toBe("USD");
  });

  it("keeps the reviewed missile scale exact and has one sourced value", () => {
    const byKey = new Map(
      ordnanceCatalogueV1.items.map((item) => [item.dcs_type, item]),
    );
    expect(
      Object.fromEntries(
        ordnanceCatalogueV1.items
          .filter((item) => item.category === "missile")
          .map((item) => [item.dcs_type, item.usd_value]),
      ),
    ).toEqual({
      "GAR-8": 75000,
      "R-3S": 50000,
      "R-60": 100000,
      "AIM-9P": 125000,
      "AIM-9L": 175000,
      "AIM-9P5": 200000,
      AIM_9: 225000,
      P_73: 300000,
      AIM_9X: 447093,
      "AIM-7F": 250000,
      AIM_7: 300000,
      "AIM-7MH": 300000,
      "AIM-7P": 350000,
      AIM_120: 900000,
      AIM_120C: 1050000,
      P_77: 1100000,
    });

    expect(byKey.get("AIM_9X")?.usd_value).toBe(447093);
    expect(byKey.get("AIM_9X")?.value_basis).toBe("sourced");
    expect(byKey.get("AIM_9X")?.source).toContain(
      "FY 2026 recurring All Up Round",
    );
    expect(
      ordnanceCatalogueV1.items
        .filter((item) => item.value_basis === "sourced")
        .map((item) => item.dcs_type),
    ).toEqual(["AIM_9X"]);
    expect(byKey.get("AIM_7")?.value_basis).toBe("estimate");
    expect(byKey.get("AIM-7MH")?.value_basis).toBe("estimate");
  });

  it("classifies every item by its mission-side faction", () => {
    expect(
      ordnanceCatalogueV1.items.filter((item) => item.faction === "blue"),
    ).toHaveLength(17);
    expect(
      ordnanceCatalogueV1.items.filter((item) => item.faction === "red"),
    ).toHaveLength(7);
  });

  it("keeps guns and the five catalogue-only Russian weapons out of scope", () => {
    const keys = new Set<string>(
      ordnanceCatalogueV1.items.map((i) => i.dcs_type),
    );
    for (const deferred of ["R-27ER", "R-27ET", "R-24R", "R-24T", "R-33"]) {
      expect(keys.has(deferred)).toBe(false);
    }
    const scopeKeys = ordnanceCatalogueV1.out_of_scope.map(
      (entry) => entry.key,
    );
    expect(scopeKeys[0]).toBe("guns");
  });

  it("records the four Slice 11 deviations against live catalogue items", () => {
    expect(ordnanceCatalogueV1.deviations).toHaveLength(4);
    const keys = new Set(ordnanceCatalogueV1.items.map((i) => i.dcs_type));
    for (const deviation of ordnanceCatalogueV1.deviations) {
      expect(keys.has(deviation.observed_dcs_type)).toBe(true);
      expect(deviation.observed_dcs_type).not.toBe(deviation.expected_dcs_type);
    }
  });
});

describe("ordnanceCatalogueV2", () => {
  it("passes structural validation", () => {
    expect(validateCatalogue(ordnanceCatalogueV2)).toEqual([]);
  });

  it("records version 2 with the 2026-09-13 effective date", () => {
    expect(ordnanceCatalogueV2.catalogue).toBe("ordnance");
    expect(ordnanceCatalogueV2.version).toBe(2);
    expect(ordnanceCatalogueV2.effective_date).toBe("2026-09-13");
    expect(ordnanceCatalogueV2.currency).toBe("USD");
  });

  it("carries every v1 item forward unchanged", () => {
    const v2ByKey = new Map(
      ordnanceCatalogueV2.items.map((item) => [item.dcs_type, item]),
    );
    expect(ordnanceCatalogueV2.items).toHaveLength(29);
    for (const v1Item of ordnanceCatalogueV1.items) {
      expect(v2ByKey.get(v1Item.dcs_type)).toEqual(v1Item);
    }
  });

  it("adds exactly the five 2026-09-13 mission keys", () => {
    const v1Keys = new Set<string>(
      ordnanceCatalogueV1.items.map((i) => i.dcs_type),
    );
    expect(
      ordnanceCatalogueV2.items
        .filter((item) => !v1Keys.has(item.dcs_type))
        .map((item) => item.dcs_type)
        .sort(),
    ).toEqual(["MiG-29S", "P_27PE", "P_27TE", "R-3R", "Su-33"]);
  });

  it("prices the new keys on the reviewed v2 scale", () => {
    expect(
      Object.fromEntries(
        ordnanceCatalogueV2.items
          .filter((item) =>
            ["P_27PE", "P_27TE", "R-3R", "MiG-29S", "Su-33"].includes(
              item.dcs_type,
            ),
          )
          .map((item) => [item.dcs_type, item.usd_value]),
      ),
    ).toEqual({
      P_27PE: 800000,
      P_27TE: 500000,
      "R-3R": 75000,
      "MiG-29S": 11000000,
      "Su-33": 25000000,
    });
  });

  it("marks the live keys verified and R-3R source-only", () => {
    const byKey = new Map(
      ordnanceCatalogueV2.items.map((item) => [item.dcs_type, item]),
    );
    expect(byKey.get("P_27PE")?.matrix_status).toBe("verified");
    expect(byKey.get("P_27TE")?.matrix_status).toBe("verified");
    expect(byKey.get("MiG-29S")?.matrix_status).toBe("verified");
    expect(byKey.get("Su-33")?.matrix_status).toBe("verified");
    expect(byKey.get("R-3R")?.matrix_status).toBe("source-only");
    expect(byKey.get("P_27PE")?.value_basis).toBe("estimate");
    expect(byKey.get("R-3R")?.value_basis).toBe("estimate");
  });

  it("records the two live naming deviations against v2 items", () => {
    expect(ordnanceCatalogueV2.deviations).toHaveLength(6);
    const keys = new Set(ordnanceCatalogueV2.items.map((i) => i.dcs_type));
    for (const deviation of ordnanceCatalogueV2.deviations) {
      expect(keys.has(deviation.observed_dcs_type)).toBe(true);
      expect(deviation.observed_dcs_type).not.toBe(deviation.expected_dcs_type);
    }
    const observed = ordnanceCatalogueV2.deviations.map(
      (deviation) => deviation.observed_dcs_type,
    );
    expect(observed).toContain("P_27PE");
    expect(observed).toContain("P_27TE");
  });

  it("resolves every v2 key and keeps the R-24/R-33 deferral intact", () => {
    for (const item of ordnanceCatalogueV2.items) {
      expect(resolveValuation(ordnanceCatalogueV2, item.dcs_type)).toEqual({
        priced: true,
        usdValue: item.usd_value,
      });
    }
    const scopeKeys = ordnanceCatalogueV2.out_of_scope.map(
      (entry) => entry.key,
    );
    expect(scopeKeys).toContain("R-24R, R-24T, R-33");
    expect(scopeKeys).not.toContain("R-27ER, R-27ET, R-24R, R-24T, R-33");
    // The display names are not runtime keys: the raw identifiers remain the
    // only priced identity, mirroring the v1 R-73/R-77 rule.
    expect(resolveValuation(ordnanceCatalogueV2, "R-27ER")).toEqual({
      priced: false,
    });
    expect(resolveValuation(ordnanceCatalogueV2, "R-27ET")).toEqual({
      priced: false,
    });
  });
});

describe("resolveValuation", () => {
  it("resolves every live dcs_type to exactly its reviewed value", () => {
    for (const item of ordnanceCatalogueV1.items) {
      expect(resolveValuation(ordnanceCatalogueV1, item.dcs_type)).toEqual({
        priced: true,
        usdValue: item.usd_value,
      });
    }
  });

  it("returns unpriced for unknown, researched-but-deviated, or empty keys", () => {
    for (const key of [
      "R-73",
      "R-77",
      "P-73",
      "AIM-120B",
      "gun",
      "Guns",
      "unknown-weapon",
      "",
    ]) {
      expect(resolveValuation(ordnanceCatalogueV1, key)).toEqual({
        priced: false,
      });
    }
    expect(resolveValuation(ordnanceCatalogueV1, null)).toEqual({
      priced: false,
    });
    expect(resolveValuation(ordnanceCatalogueV1, undefined)).toEqual({
      priced: false,
    });
  });
});

describe("validateCatalogue", () => {
  it("allows the planned missile, bomb, rocket, and aircraft categories", () => {
    expect(CATALOGUE_CATEGORIES).toEqual([
      "missile",
      "bomb",
      "rocket",
      "aircraft",
    ]);
  });

  it("reports duplicate dcs_type keys", () => {
    const violations = validateCatalogue(
      mutated((catalogue) => {
        catalogue.items.push({ ...catalogue.items[0] });
      }),
    );
    expect(
      violations.some((violation) =>
        violation.includes('duplicate dcs_type "AIM-9L"'),
      ),
    ).toBe(true);
  });

  it("reports non-positive values", () => {
    const violations = validateCatalogue(
      mutated((catalogue) => {
        catalogue.items[0].usd_value = -1;
      }),
    );
    expect(
      violations.some((violation) =>
        violation.includes("usd_value must be a positive finite number"),
      ),
    ).toBe(true);
  });

  it("reports values with more than two decimal places", () => {
    const violations = validateCatalogue(
      mutated((catalogue) => {
        catalogue.items[0].usd_value = 10.123;
      }),
    );
    expect(
      violations.some((violation) =>
        violation.includes("at most two decimal places"),
      ),
    ).toBe(true);
  });

  it("reports unknown categories", () => {
    const violations = validateCatalogue(
      mutated((catalogue) => {
        catalogue.items[0].category = "vehicle" as never;
      }),
    );
    expect(
      violations.some((violation) =>
        violation.includes('category "vehicle" is not one of'),
      ),
    ).toBe(true);
  });

  it("reports unknown factions", () => {
    const violations = validateCatalogue(
      mutated((catalogue) => {
        catalogue.items[0].faction = "neutral" as never;
      }),
    );
    expect(
      violations.some((violation) =>
        violation.includes('faction "neutral" is not one of'),
      ),
    ).toBe(true);
  });

  it("reports invalid value bases", () => {
    const violations = validateCatalogue(
      mutated((catalogue) => {
        catalogue.items[0].value_basis = "procurement" as never;
      }),
    );
    expect(
      violations.some((violation) =>
        violation.includes(
          'value_basis "procurement" must be "sourced" or "estimate"',
        ),
      ),
    ).toBe(true);
  });

  it("reports invalid matrix statuses", () => {
    const violations = validateCatalogue(
      mutated((catalogue) => {
        catalogue.items[0].matrix_status = "candidate" as never;
      }),
    );
    expect(
      violations.some((violation) =>
        violation.includes(
          'matrix_status "candidate" must be "verified" or "source-only"',
        ),
      ),
    ).toBe(true);
  });

  it("reports deviations that reference unknown items", () => {
    const violations = validateCatalogue(
      mutated((catalogue) => {
        catalogue.deviations[0].observed_dcs_type = "NOT_A_CATALOGUE_KEY";
      }),
    );
    expect(
      violations.some((violation) =>
        violation.includes(
          'observed_dcs_type "NOT_A_CATALOGUE_KEY" is not a catalogue item',
        ),
      ),
    ).toBe(true);
  });

  it("reports malformed effective dates", () => {
    const violations = validateCatalogue(
      mutated((catalogue) => {
        catalogue.effective_date = "2026-02-30";
      }),
    );
    expect(
      violations.some((violation) =>
        violation.includes("effective_date must be a valid ISO calendar date"),
      ),
    ).toBe(true);
  });
});
