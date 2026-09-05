import { describe, expect, it } from "vitest";

import {
  matchesClassification,
  parseClassificationFilter,
  parsePageNumber,
} from "../src/telemetry/run-filters";

describe("classification filter", () => {
  it("accepts test, historical, and defaults everything else to all", () => {
    expect(parseClassificationFilter("test")).toBe("test");
    expect(parseClassificationFilter("historical")).toBe("historical");
    expect(parseClassificationFilter("all")).toBe("all");
    expect(parseClassificationFilter(null)).toBe("all");
    expect(parseClassificationFilter(undefined)).toBe("all");
    expect(parseClassificationFilter("real")).toBe("all");
    expect(parseClassificationFilter("TEST")).toBe("all");
  });

  it("matches stored classifications without inventing history", () => {
    expect(matchesClassification("test", "test")).toBe(true);
    expect(matchesClassification("test", "historical")).toBe(false);
    expect(matchesClassification("historical", "historical")).toBe(true);
    expect(matchesClassification("test", "all")).toBe(true);
    expect(matchesClassification("historical", "all")).toBe(true);
    // Pre-classification rows match only the unfiltered view.
    expect(matchesClassification(null, "test")).toBe(false);
    expect(matchesClassification(null, "historical")).toBe(false);
    expect(matchesClassification(null, "all")).toBe(true);
    expect(matchesClassification("", "test")).toBe(false);
  });
});

describe("page numbers", () => {
  it("parses 1-based pages and repairs garbage to page 1", () => {
    expect(parsePageNumber("1")).toBe(1);
    expect(parsePageNumber("3")).toBe(3);
    expect(parsePageNumber(null)).toBe(1);
    expect(parsePageNumber(undefined)).toBe(1);
    expect(parsePageNumber("0")).toBe(1);
    expect(parsePageNumber("-2")).toBe(1);
    expect(parsePageNumber("1.5")).toBe(1);
    expect(parsePageNumber("next")).toBe(1);
  });
});
