import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { and, eq } from "drizzle-orm";

import { getDb } from "../src/db/client";
import {
  valuationCatalogues,
  valuationItems,
  type NewValuationCatalogueRow,
  type NewValuationItemRow,
  type ValuationCatalogueRow,
  type ValuationItemRow,
} from "../src/db/schema";
import {
  ordnanceCatalogueV1,
  validateCatalogue,
} from "../src/telemetry/catalogue";

const expectedCatalogue: NewValuationCatalogueRow = {
  catalogue: ordnanceCatalogueV1.catalogue,
  version: ordnanceCatalogueV1.version,
  effectiveDate: ordnanceCatalogueV1.effective_date,
  currency: ordnanceCatalogueV1.currency,
  pricingConvention: ordnanceCatalogueV1.pricing_convention,
  typeKeySource: ordnanceCatalogueV1.type_key_source,
};

const expectedItems: readonly NewValuationItemRow[] =
  ordnanceCatalogueV1.items.map((item) => ({
    catalogue: ordnanceCatalogueV1.catalogue,
    catalogueVersion: ordnanceCatalogueV1.version,
    dcsType: item.dcs_type,
    displayName: item.display_name,
    faction: item.faction,
    category: item.category,
    usdValue: item.usd_value.toFixed(2),
    valueBasis: item.value_basis,
    source: item.source,
    matrixStatus: item.matrix_status,
    matrixEvidence: item.matrix_evidence,
    notes: item.notes,
  }));

function pickEnv(line: string, key: string): string | null {
  const equalsIndex = line.indexOf("=");
  if (equalsIndex <= 0 || line.slice(0, equalsIndex).trim() !== key) {
    return null;
  }

  let value = line.slice(equalsIndex + 1).trim();
  if (
    (value.startsWith('"') && value.endsWith('"')) ||
    (value.startsWith("'") && value.endsWith("'"))
  ) {
    value = value.slice(1, -1);
  }
  return value || null;
}

async function ensureDatabaseEnvironment(): Promise<void> {
  if (process.env.POSTGRES_URL || process.env.DATABASE_URL) {
    return;
  }

  const envPath = path.join(
    path.dirname(fileURLToPath(import.meta.url)),
    "..",
    ".env.local",
  );
  let text: string;
  try {
    text = await readFile(envPath, "utf8");
  } catch {
    throw new Error(
      "Database connection is not configured: set POSTGRES_URL or DATABASE_URL, or add one to web/.env.local",
    );
  }

  let postgresUrl: string | null = null;
  let databaseUrl: string | null = null;
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) {
      continue;
    }
    postgresUrl = postgresUrl ?? pickEnv(line, "POSTGRES_URL");
    databaseUrl = databaseUrl ?? pickEnv(line, "DATABASE_URL");
  }

  if (postgresUrl) {
    process.env.POSTGRES_URL = postgresUrl;
  } else if (databaseUrl) {
    process.env.DATABASE_URL = databaseUrl;
  } else {
    throw new Error(
      "Database connection is not configured: set POSTGRES_URL or DATABASE_URL, or add one to web/.env.local",
    );
  }
}

function catalogueDifferences(row: ValuationCatalogueRow): string[] {
  const differences: string[] = [];
  if (row.effectiveDate !== expectedCatalogue.effectiveDate) {
    differences.push("effective_date");
  }
  if (row.currency !== expectedCatalogue.currency) {
    differences.push("currency");
  }
  if (row.pricingConvention !== expectedCatalogue.pricingConvention) {
    differences.push("pricing_convention");
  }
  if (row.typeKeySource !== expectedCatalogue.typeKeySource) {
    differences.push("type_key_source");
  }
  return differences;
}

function itemDifferences(
  row: ValuationItemRow,
  expected: NewValuationItemRow,
): string[] {
  const differences: string[] = [];
  if (row.displayName !== expected.displayName)
    differences.push("display_name");
  if (row.faction !== expected.faction) differences.push("faction");
  if (row.category !== expected.category) differences.push("category");
  if (row.usdValue !== expected.usdValue) differences.push("usd_value");
  if (row.valueBasis !== expected.valueBasis) differences.push("value_basis");
  if (row.source !== expected.source) differences.push("source");
  if (row.matrixStatus !== expected.matrixStatus) {
    differences.push("matrix_status");
  }
  if (row.matrixEvidence !== expected.matrixEvidence) {
    differences.push("matrix_evidence");
  }
  if (row.notes !== expected.notes) differences.push("notes");
  return differences;
}

async function readCatalogue(): Promise<ValuationCatalogueRow | undefined> {
  const rows = await getDb()
    .select()
    .from(valuationCatalogues)
    .where(
      and(
        eq(valuationCatalogues.catalogue, expectedCatalogue.catalogue),
        eq(valuationCatalogues.version, expectedCatalogue.version),
      ),
    );
  return rows[0];
}

async function readItems(): Promise<ValuationItemRow[]> {
  return getDb()
    .select()
    .from(valuationItems)
    .where(
      and(
        eq(valuationItems.catalogue, expectedCatalogue.catalogue),
        eq(valuationItems.catalogueVersion, expectedCatalogue.version),
      ),
    );
}

function assertCatalogueMatches(row: ValuationCatalogueRow): void {
  const differences = catalogueDifferences(row);
  if (differences.length > 0) {
    throw new Error(
      `Refusing to rewrite immutable ${row.catalogue} v${row.version}: catalogue fields differ (${differences.join(", ")})`,
    );
  }
}

function assertExistingItemsCompatible(
  rows: readonly ValuationItemRow[],
): void {
  const expectedByType = new Map(
    expectedItems.map((item) => [item.dcsType, item] as const),
  );
  for (const row of rows) {
    const expected = expectedByType.get(row.dcsType);
    if (!expected) {
      throw new Error(
        `Refusing to rewrite immutable ${row.catalogue} v${row.catalogueVersion}: unexpected item ${row.dcsType}`,
      );
    }
    const differences = itemDifferences(row, expected);
    if (differences.length > 0) {
      throw new Error(
        `Refusing to rewrite immutable ${row.catalogue} v${row.catalogueVersion} item ${row.dcsType}: fields differ (${differences.join(", ")})`,
      );
    }
  }
}

async function seed(): Promise<void> {
  await ensureDatabaseEnvironment();

  const violations = validateCatalogue(ordnanceCatalogueV1);
  if (violations.length > 0) {
    throw new Error(`Catalogue validation failed:\n${violations.join("\n")}`);
  }

  let catalogue = await readCatalogue();
  if (catalogue) {
    assertCatalogueMatches(catalogue);
  } else {
    await getDb()
      .insert(valuationCatalogues)
      .values(expectedCatalogue)
      .onConflictDoNothing({
        target: [valuationCatalogues.catalogue, valuationCatalogues.version],
      });
    catalogue = await readCatalogue();
    if (!catalogue) {
      throw new Error("Catalogue insert completed without a readable row");
    }
    assertCatalogueMatches(catalogue);
  }

  const existingItems = await readItems();
  assertExistingItemsCompatible(existingItems);
  const existingTypes = new Set(existingItems.map((item) => item.dcsType));
  const missingItems = expectedItems.filter(
    (item) => !existingTypes.has(item.dcsType),
  );

  if (missingItems.length > 0) {
    await getDb()
      .insert(valuationItems)
      .values(missingItems)
      .onConflictDoNothing({
        target: [
          valuationItems.catalogue,
          valuationItems.catalogueVersion,
          valuationItems.dcsType,
        ],
      });
  }

  const finalItems = await readItems();
  assertExistingItemsCompatible(finalItems);
  if (finalItems.length !== expectedItems.length) {
    throw new Error(
      `Catalogue seed incomplete: expected ${expectedItems.length} items, found ${finalItems.length}`,
    );
  }

  console.log(
    `Catalogue ${expectedCatalogue.catalogue} v${expectedCatalogue.version} verified with ${finalItems.length} immutable items (${missingItems.length} inserted)`,
  );
}

await seed();
