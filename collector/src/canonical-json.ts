function normalize(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(normalize);
  }

  if (value !== null && typeof value === "object") {
    const input = value as Record<string, unknown>;
    const output: Record<string, unknown> = {};
    for (const key of Object.keys(input).sort()) {
      output[key] = normalize(input[key]);
    }
    return output;
  }

  return value;
}

export function canonicalJson(value: unknown): string {
  return JSON.stringify(normalize(value));
}
