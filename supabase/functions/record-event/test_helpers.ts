export function assert(value: unknown, message = "Assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
export function equal(actual: unknown, expected: unknown) {
  assert(
    JSON.stringify(actual) === JSON.stringify(expected),
    `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
  );
}
export function throws(fn: () => unknown) {
  let failed = false;
  try {
    fn();
  } catch {
    failed = true;
  }
  assert(failed, "Expected rejection");
}
export const now = new Date("2026-11-12T20:00:00Z");
export const command = {
  request_id: "11111111-1111-4111-8111-111111111111",
  child_id: "22222222-2222-4222-8222-222222222222",
  reference_at: now.toISOString(),
  source: "siri",
  locale: "en",
  mode: "text",
  text: "Log 160 millilitres for Victoria.",
};
export function extraction(overrides: Record<string, unknown> = {}) {
  return {
    decision: "record",
    clarification: null,
    child_name: "Victoria",
    event_type: "feeding",
    volume_ml: 160,
    diaper_kind: null,
    weight_kg: null,
    time_kind: "now",
    minutes_ago: null,
    absolute_utc: null,
    ...overrides,
  };
}
