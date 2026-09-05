/**
 * Pure validation and resolution for the versioned ordnance valuation
 * catalogue.
 *
 * No I/O: the catalogue value is a committed, human-reviewed constant
 * (`ordnance-v1.ts`). `validateCatalogue` reports structural violations
 * (an empty list means the catalogue is well-formed). `resolveValuation`
 * maps a canonical dcs_type to exactly one USD value and returns
 * "unpriced" for unknown or missing keys — it never throws and never
 * invents a value.
 *
 * Telemetry keeps passing `dcs_type` through unchanged; resolution happens
 * here on the web side.
 */

import {
  CATALOGUE_CATEGORIES,
  CATALOGUE_FACTIONS,
  MATRIX_STATUSES,
  VALUE_BASES,
  type OrdinanceCatalogue,
} from "./types";

export * from "./types";
export { ordnanceCatalogueV1 } from "./ordnance-v1";

export type Valuation = { priced: true; usdValue: number } | { priced: false };

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function hasAtMostTwoDecimals(value: number): boolean {
  return Math.abs(value * 100 - Math.round(value * 100)) < 1e-6;
}

function isCalendarDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    return false;
  }
  const date = new Date(`${value}T00:00:00Z`);
  if (Number.isNaN(date.getTime())) {
    return false;
  }
  return date.toISOString().slice(0, 10) === value;
}

export function validateCatalogue(catalogue: OrdinanceCatalogue): string[] {
  const violations: string[] = [];

  if (!isNonEmptyString(catalogue.catalogue)) {
    violations.push("catalogue: name must be a non-empty string");
  }
  if (!Number.isInteger(catalogue.version) || catalogue.version < 1) {
    violations.push("catalogue: version must be a positive integer");
  }
  if (
    !isNonEmptyString(catalogue.effective_date) ||
    !isCalendarDate(catalogue.effective_date)
  ) {
    violations.push(
      "catalogue: effective_date must be a valid ISO calendar date (YYYY-MM-DD)",
    );
  }
  if (!isNonEmptyString(catalogue.currency)) {
    violations.push("catalogue: currency must be a non-empty string");
  }
  if (!isNonEmptyString(catalogue.pricing_convention)) {
    violations.push("catalogue: pricing_convention must be a non-empty string");
  }
  if (!isNonEmptyString(catalogue.type_key_source)) {
    violations.push("catalogue: type_key_source must be a non-empty string");
  }
  if (catalogue.items.length === 0) {
    violations.push("catalogue: items must not be empty");
  }

  const seenKeys = new Set<string>();
  catalogue.items.forEach((item, index) => {
    const label = `items[${index}] (${item.dcs_type || "?"})`;
    if (!isNonEmptyString(item.dcs_type)) {
      violations.push(`${label}: dcs_type must be a non-empty string`);
    } else if (seenKeys.has(item.dcs_type)) {
      violations.push(`${label}: duplicate dcs_type "${item.dcs_type}"`);
    } else {
      seenKeys.add(item.dcs_type);
    }
    if (!isNonEmptyString(item.display_name)) {
      violations.push(`${label}: display_name must be a non-empty string`);
    }
    if (!(CATALOGUE_FACTIONS as readonly string[]).includes(item.faction)) {
      violations.push(
        `${label}: faction "${item.faction}" is not one of ${CATALOGUE_FACTIONS.join(", ")}`,
      );
    }
    if (!(CATALOGUE_CATEGORIES as readonly string[]).includes(item.category)) {
      violations.push(
        `${label}: category "${item.category}" is not one of ${CATALOGUE_CATEGORIES.join(", ")}`,
      );
    }
    if (
      typeof item.usd_value !== "number" ||
      !Number.isFinite(item.usd_value) ||
      item.usd_value <= 0
    ) {
      violations.push(`${label}: usd_value must be a positive finite number`);
    } else if (!hasAtMostTwoDecimals(item.usd_value)) {
      violations.push(
        `${label}: usd_value must have at most two decimal places`,
      );
    }
    if (!(VALUE_BASES as readonly string[]).includes(item.value_basis)) {
      violations.push(
        `${label}: value_basis "${item.value_basis}" must be "sourced" or "estimate"`,
      );
    }
    if (!isNonEmptyString(item.source)) {
      violations.push(`${label}: source must be a non-empty string`);
    }
    if (!(MATRIX_STATUSES as readonly string[]).includes(item.matrix_status)) {
      violations.push(
        `${label}: matrix_status "${item.matrix_status}" must be "verified" or "source-only"`,
      );
    }
    if (!isNonEmptyString(item.matrix_evidence)) {
      violations.push(`${label}: matrix_evidence must be a non-empty string`);
    }
    if (typeof item.notes !== "string") {
      violations.push(`${label}: notes must be a string`);
    }
  });

  catalogue.deviations.forEach((deviation, index) => {
    const label = `deviations[${index}] (${deviation.cell || "?"})`;
    if (!isNonEmptyString(deviation.airframe)) {
      violations.push(`${label}: airframe must be a non-empty string`);
    }
    if (!isNonEmptyString(deviation.cell)) {
      violations.push(`${label}: cell must be a non-empty string`);
    }
    if (!isNonEmptyString(deviation.loadout_key)) {
      violations.push(`${label}: loadout_key must be a non-empty string`);
    }
    if (!isNonEmptyString(deviation.expected_dcs_type)) {
      violations.push(`${label}: expected_dcs_type must be a non-empty string`);
    }
    if (!isNonEmptyString(deviation.observed_dcs_type)) {
      violations.push(`${label}: observed_dcs_type must be a non-empty string`);
    } else if (!seenKeys.has(deviation.observed_dcs_type)) {
      violations.push(
        `${label}: observed_dcs_type "${deviation.observed_dcs_type}" is not a catalogue item`,
      );
    }
    if (deviation.observed_dcs_type === deviation.expected_dcs_type) {
      violations.push(
        `${label}: observed_dcs_type must differ from expected_dcs_type`,
      );
    }
    if (!isNonEmptyString(deviation.explanation)) {
      violations.push(`${label}: explanation must be a non-empty string`);
    }
  });

  catalogue.out_of_scope.forEach((entry, index) => {
    const label = `out_of_scope[${index}]`;
    if (!isNonEmptyString(entry.key)) {
      violations.push(`${label}: key must be a non-empty string`);
    }
    if (!isNonEmptyString(entry.reason)) {
      violations.push(`${label}: reason must be a non-empty string`);
    }
  });

  return violations;
}

export function resolveValuation(
  catalogue: OrdinanceCatalogue,
  dcsType: string | null | undefined,
): Valuation {
  if (dcsType == null) {
    return { priced: false };
  }
  const item = catalogue.items.find(
    (candidate) => candidate.dcs_type === dcsType,
  );
  if (!item) {
    return { priced: false };
  }
  return { priced: true, usdValue: item.usd_value };
}
