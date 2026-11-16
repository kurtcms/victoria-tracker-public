import { formatDuration, formatMilk, formatQuery, formatTemporal, formatWeight } from "./query_format.ts";
import type { FormatContext, QueryFacts, QuerySpec } from "./query_types.ts";
import type { RequestCommand } from "./domain.ts";
import { assert, command, equal } from "./test_helpers.ts";
const context: FormatContext = {
  command: {
    ...command,
    reference_at: "2026-11-15T20:00:00Z",
    utc_offset_seconds: -28800,
    zone_offsets: [{ from: "2025-11-15T00:00:00Z", seconds: -28800 }],
  } as RequestCommand,
  language: "en",
  presentation: { milk: "ml", weight: "kg", surface: "spoken" },
};
const query: QuerySpec = {
  domain: "feeding",
  operation: "total",
  subtype: "all",
  quantity: "consumed",
  day: "2026-11-15",
  period: "day",
  minutes: null,
  detailed: false,
  exact: false,
};
function facts(patch: Partial<QueryFacts> = {}): QueryFacts {
  return {
    version: 2,
    query,
    child_id: "baby",
    child_name: "Ava",
    evidence: "positive",
    issues: [],
    records: [],
    count: 0,
    completed_minutes: 0,
    open_minutes: 0,
    wet_count: 0,
    dirty_count: 0,
    diaper_count: 0,
    feeding_count: 0,
    feeding_ml: 150.5,
    sleep_state: "unknown",
    ...patch,
  };
}
Deno.test("human durations cover hour boundaries and pluralization in both languages", () => {
  const en = [
    "0 minutes",
    "1 minute",
    "59 minutes",
    "1 hour",
    "1 hour and 1 minute",
    "2 hours",
    "3 hours and 20 minutes",
  ];
  const yue = ["0分鐘", "1分鐘", "59分鐘", "1個鐘", "1個鐘零1分鐘", "2個鐘", "3個鐘零20分鐘"];
  [0, 1, 59, 60, 61, 120, 200].forEach((n, i) => {
    equal(formatDuration(n), en[i]);
    equal(formatDuration(n, "yue"), yue[i]);
  });
  equal(formatDuration(200, "en", "visual"), "3h 20m");
});
Deno.test("units preserve exact metric milk and distinguish approximate US conversion", () => {
  equal(formatMilk(150.5, "en", context.presentation), "150.5 millilitres");
  equal(formatMilk(1, "en", context.presentation), "1 millilitre");
  equal(formatMilk(150, "yue", context.presentation), "150毫升");
  assert(formatMilk(150, "en", { ...context.presentation, milk: "oz" }).includes("approximately 5.07 US fluid ounces"));
  equal(formatWeight(7.125, "en", context.presentation), "7 kilograms and 125 grams");
  equal(formatWeight(7.125, "yue", context.presentation), "7公斤125克");
  equal(formatWeight(7.125, "en", { ...context.presentation, surface: "visual" }), "7.125 kg");
  assert(formatWeight(7.125, "en", { ...context.presentation, weight: "lb" }).includes("pounds"));
});
Deno.test("temporal labels use captured offsets, recency and explicit precision", () => {
  equal(formatTemporal({ id: "r", at: "2026-11-15T18:30:00Z" }, context, query), "10:30 AM");
  equal(formatTemporal({ id: "r", at: "2026-11-15 10:30" }, context, query), "10:30 AM");
  equal(formatTemporal({ id: "r", at: "2026-11-15T07:30:00Z" }, context, query), "yesterday at 11:30 PM");
  equal(formatTemporal({ id: "r", at: "2026-11-13T18:30:00Z" }, context, query), "Friday at 10:30 AM");
  equal(
    formatTemporal({ id: "r", at: "2026-11-15T18:30:00Z" }, context, { ...query, exact: true }),
    "November 15, 2026 at 10:30:00 AM (UTC-08:00)",
  );
  equal(
    formatTemporal({ id: "r", date: "2026-07-01", precision: "month" }, context, { ...query, exact: true }),
    "July 2026",
  );
  equal(formatTemporal({ id: "r", date: "2026-11-14", at: "2026-11-15T00:00:00Z" }, context, query), "yesterday");
  const travel = {
    ...context,
    command: {
      ...context.command,
      zone_offsets: [{ from: "2025-11-15T00:00:00Z", seconds: 28800 }, {
        from: "2026-11-15T12:00:00Z",
        seconds: -28800,
      }],
    },
  };
  assert(formatTemporal({ id: "r", at: "2026-11-15T01:00:00Z" }, travel, query).includes("9:00 AM"));
});
Deno.test("milk answers exclude unrelated metrics and qualify missing quantities", () => {
  const answer = formatQuery(facts({ value: 150.5 }), context);
  assert(answer.includes("150.5 millilitres"));
  assert(!/sleep|diaper/i.test(answer));
  const missing = formatQuery(
    facts({ evidence: "incomplete", issues: ["unknown_offered"], query: { ...query, quantity: "offered" } }),
    context,
  );
  assert(/unknown|not recorded|couldn.t confirm/i.test(missing));
  assert(!missing.includes("150.5"));
});
Deno.test("absence and uncertain evidence never establish real-world inactivity", () => {
  for (const language of ["en", "yue"] as const) {
    const answer = formatQuery(
      facts({ evidence: "negative", query: { ...query, domain: "diaper", operation: "exists", subtype: "dirty" } }),
      { ...context, language },
    );
    assert(answer.includes(language === "en" ? "record" : "記錄"));
    assert(!/has not pooped|hasn.t pooped|冇大便/.test(answer));
    const unknown = formatQuery(facts({ evidence: "unknown" }), { ...context, language });
    assert(unknown.includes(language === "en" ? "records" : "記錄"));
  }
});
Deno.test("sleep totals separate completed duration from open estimates and stale recorded state", () => {
  const sleep = facts({
    query: { ...query, domain: "sleep" },
    completed_minutes: 200,
    open_minutes: 61,
    issues: ["open_sleep"],
  });
  const answer = formatQuery(sleep, context);
  assert(answer.includes("3 hours and 20 minutes"));
  assert(answer.includes("1 hour and 1 minute"));
  assert(/unconfirmed/i.test(answer));
  assert(!answer.includes("4 hours and 21 minutes"));
  const state = formatQuery(
    facts({
      ...sleep,
      query: { ...sleep.query, operation: "state" },
      evidence: "stale",
      sleep_state: "asleep",
      last_sleep: { id: "s", at: "2026-11-14T18:00:00Z" },
    }),
    context,
  );
  assert(/record|recorded/.test(state));
  assert(/stale|out of date/.test(state));
  assert(/confirm/.test(state));
});
Deno.test("reports include totals, latest feeding, recorded sleep state and detailed records", () => {
  const report = facts({
    query: { ...query, domain: "care", operation: "report" },
    wet_count: 1,
    dirty_count: 2,
    completed_minutes: 60,
    last_feeding: { id: "f", value: 80, at: "2026-11-15T18:00:00Z" },
    sleep_state: "awake",
    last_sleep: { id: "s", at: "2026-11-15T15:00:00Z", end: "2026-11-15T16:00:00Z" },
    records: [{ id: "f", value: 80, at: "2026-11-15T18:00:00Z" }],
  });
  for (const language of ["en", "yue"] as const) {
    const brief = formatQuery(report, { ...context, language });
    for (
      const part of ["150.5", "80", language === "en" ? "1 wet diaper" : "濕尿片1次", language === "en" ? "wake" : "醒"]
    ) assert(brief.includes(part), brief);
    const detailed = formatQuery({ ...report, query: { ...report.query, detailed: true } }, { ...context, language });
    assert(detailed.length > brief.length);
  }
});
Deno.test("nap definition and month precision are disclosed without invented clock times", () => {
  const nap = formatQuery(
    facts({
      query: { ...query, domain: "sleep", operation: "count", subtype: "nap" },
      count: 1,
      issues: ["nap_definition"],
    }),
    context,
  );
  assert(nap.includes("06:00") && nap.includes("18:00"));
  const milestone = formatQuery(
    facts({
      query: { ...query, domain: "milestone", operation: "latest", exact: true },
      count: 1,
      records: [{ id: "m", date: "2026-07-01", precision: "month", title: "Sat up" }],
      issues: ["month_precision"],
    }),
    context,
  );
  assert(milestone.includes("July 2026"));
  assert(!milestone.includes("July 1"));
});
Deno.test("diaper totals use record counts with singular grammar and mixed-count qualification", () => {
  const answer = formatQuery(facts({ query: { ...query, domain: "diaper", subtype: "wet" }, count: 1 }), context);
  assert(answer.includes("1 wet diaper record"), answer);
  assert(/mixed/i.test(answer), answer);
});
Deno.test("stale elapsed and incomplete sleep warn without presenting confirmed current status", () => {
  const answer = formatQuery(
    facts({
      query: { ...query, domain: "sleep", operation: "elapsed" },
      value: 500,
      evidence: "stale",
      issues: ["stale_sleep", "open_sleep"],
    }),
    context,
  );
  assert(answer.includes("stale"), answer);
  assert(answer.includes("unconfirmed"), answer);
});
Deno.test("domain reports stay relevant and detailed feeding reports include amounts and times", () => {
  const f = facts({
    query: { ...query, operation: "report", detailed: true },
    count: 2,
    feeding_count: 2,
    feeding_ml: 170,
    value: 170,
    records: [{ id: "a", value: 80, at: "2026-11-15T18:00Z" }, { id: "b", value: 90, at: "2026-11-15T19:00Z" }],
  });
  const answer = formatQuery(f, context);
  for (const word of ["170", "2", "80", "90", "AM"]) assert(answer.includes(word), answer);
  for (const word of ["diaper", "sleep", "weight"]) assert(!answer.includes(word), answer);
});
Deno.test("stale state identifies last start without claiming ongoing sleep", () => {
  const answer = formatQuery(
    facts({
      query: { ...query, domain: "sleep", operation: "state", day: null, period: "all" },
      evidence: "stale",
      sleep_state: "unknown",
      last_sleep: { id: "s", at: "2026-11-15T10:00Z", end: null },
      issues: ["stale_sleep", "open_sleep"],
    }),
    context,
  );
  assert(answer.includes("2:00 AM"), answer);
  assert(answer.includes("wake-up"), answer);
  assert(!answer.includes("is sleeping"), answer);
});
Deno.test("older instants retain a year and explicit timestamps retain seconds and offset", () => {
  const old = formatTemporal({ id: "o", at: "2024-08-09T18:30:15Z" }, context, query);
  assert(old.includes("2024"), old);
  assert(old.includes("AM"), old);
  const exact = formatTemporal({ id: "e", at: "2026-11-15T18:30:15Z" }, context, { ...query, exact: true });
  assert(exact.includes(":15"), exact);
  assert(exact.includes("UTC-08:00"), exact);
  const yue = formatTemporal({ id: "y", date: "2025-08-09", precision: "day" }, { ...context, language: "yue" }, query);
  assert(yue.includes("2025"), yue);
});
Deno.test("subtype diaper reports do not expose unrelated category totals", () => {
  for (const subtype of ["wet", "dirty"] as const) {
    const answer = formatQuery(
      facts({
        query: { ...query, domain: "diaper", operation: "report", subtype },
        count: 1,
        diaper_count: 2,
        wet_count: 1,
        dirty_count: 1,
        records: [{ id: "d", diaper: subtype, at: "2026-11-15T18:00Z" }],
      }),
      context,
    );
    assert(answer.includes("1 " + subtype + " diaper"), answer);
    assert(!answer.includes("2 diaper changes"), answer);
    assert(!answer.includes(subtype === "wet" ? "dirty diapers" : "wet diapers"), answer);
  }
});
