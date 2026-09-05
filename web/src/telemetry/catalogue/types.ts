export const CATALOGUE_CATEGORIES = [
  "missile",
  "bomb",
  "rocket",
  "aircraft",
] as const;
export type CatalogueCategory = (typeof CATALOGUE_CATEGORIES)[number];

export const CATALOGUE_FACTIONS = ["blue", "red"] as const;
export type CatalogueFaction = (typeof CATALOGUE_FACTIONS)[number];

export const VALUE_BASES = ["sourced", "estimate"] as const;
export type ValueBasis = (typeof VALUE_BASES)[number];

export const MATRIX_STATUSES = ["verified", "source-only"] as const;
export type MatrixStatus = (typeof MATRIX_STATUSES)[number];

export interface OrdinanceCatalogueItem {
  readonly dcs_type: string;
  readonly display_name: string;
  readonly faction: CatalogueFaction;
  readonly category: CatalogueCategory;
  readonly usd_value: number;
  readonly value_basis: ValueBasis;
  readonly source: string;
  readonly matrix_status: MatrixStatus;
  readonly matrix_evidence: string;
  readonly notes: string;
}

export interface CatalogueDeviation {
  readonly airframe: string;
  readonly cell: string;
  readonly loadout_key: string;
  readonly expected_dcs_type: string;
  readonly observed_dcs_type: string;
  readonly explanation: string;
}

export interface CatalogueExclusion {
  readonly key: string;
  readonly reason: string;
}

/**
 * The misspelled public name is retained for compatibility with the first
 * Slice 11 implementation.
 */
export interface OrdinanceCatalogue {
  readonly catalogue: string;
  readonly version: number;
  readonly effective_date: string;
  readonly currency: string;
  readonly pricing_convention: string;
  readonly type_key_source: string;
  readonly items: readonly OrdinanceCatalogueItem[];
  readonly deviations: readonly CatalogueDeviation[];
  readonly out_of_scope: readonly CatalogueExclusion[];
}
