import { calculateQuery, type Snapshot } from "./query_execute.ts";
import { interpretReadQuery } from "./query_interpret.ts";
import { assert, child, command, equal } from "./test_helpers.ts";
import { parse } from "./domain.ts";
const c = parse(command, new Date(command.reference_at));
const base: Snapshot = { complete: true, events: [], sleep: [], milestones: [] };
function run(text: string, snapshot: Snapshot = base) {
  const q = interpretReadQuery(text, c);
  assert(q, text);
  return calculateQuery(q, snapshot, c, { id: child, name: "Victoria" });
}
Deno.test("missing records remain unknown; mixed diapers count in both categories and once as changes", () => {
  equal(run("Has she peed today?").evidence, "unknown");
  const s = {
    ...base,
    events: [{ id: "1", event_type: "diaper", diaper_kind: "mixed", occurred_at: "2026-11-13T18:00Z" }, {
      id: "2",
      event_type: "diaper",
      diaper_kind: "dirty",
      occurred_at: "2026-11-13T19:00Z",
    }],
  };
  for (
    const [text, n] of [["How many wet diapers today?", 1], ["How many dirty diapers today?", 2], [
      "How many diaper changes today?",
      2,
    ]] as const
  ) equal(run(text, s).count, n);
  equal(run("When was her last wet diaper?", s).records[0].id, "1");
});
Deno.test("consumed volume never uses bottle basis; unknown offered and remaining stay unknown", () => {
  const s = {
    ...base,
    events: [
      { id: "1", event_type: "feeding", volume_ml: 80, feeding_basis_ml: 120, occurred_at: "2026-11-13T18:00Z" },
      { id: "2", event_type: "feeding", volume_ml: 60, feeding_basis_ml: null, occurred_at: "2026-11-13T19:00Z" },
    ],
  };
  equal(run("How much milk today?", s).value, 140);
  equal(run("How much milk was offered today?", s).evidence, "incomplete");
  equal(run("How much milk was remaining today?", s).evidence, "incomplete");
});
Deno.test("completed sleep clips midnight; open sessions do not count as completed and stale state is explicit", () => {
  const s = {
    ...base,
    sleep: [{ id: "1", started_at: "2026-11-13T06:00Z", ended_at: "2026-11-13T08:15Z" }, {
      id: "2",
      started_at: "2026-11-13T10:00Z",
      ended_at: null,
    }],
  };
  const f = run("How long has she slept today?", s);
  equal(f.completed_minutes, 75);
  equal(f.open_minutes, 600);
  equal(f.evidence, "incomplete");
  equal(run("Is she sleeping?", s).evidence, "stale");
  equal(run("Is she sleeping?", s).sleep_state, "unknown");
  const fresh = { ...base, sleep: [{ id: "3", started_at: "2026-11-13T19:00Z", ended_at: null }] };
  equal(run("Is she sleeping?", fresh).sleep_state, "asleep");
  equal(run("Has she napped?", fresh).evidence, "positive");
});
Deno.test("event clocks, date-only observations and exact follow-up target govern retrieval", () => {
  const s = {
    ...base,
    events: [{
      id: "1",
      event_type: "feeding",
      volume_ml: 90,
      occurred_at: "2026-11-12T18:00Z",
      created_at: "2026-11-13T19:00Z",
    }, {
      id: "2",
      event_type: "weight",
      weight_kg: 6.125,
      measurement_date: "2026-11-01",
      occurred_at: "2026-11-01T07:00Z",
    }],
    milestones: [{ id: "3", title: "waved hello", occurred_on: "2026-10-01", date_precision: "month" }],
  };
  equal(run("How much milk today?", s).value, 0);
  equal(run("What was her last weight?", s).records[0].at, undefined);
  equal(run("What was her last milestone?", s).records[0].precision, "month");
  const q = interpretReadQuery("How much milk today?", c)!;
  const f = calculateQuery({ ...q, operation: "latest", target_id: "missing" }, s, c, { id: child, name: "Victoria" });
  equal(f.evidence, "unknown");
});
Deno.test("relative windows and inconsistent histories never invent intervals", () => {
  const s = {
    ...base,
    sleep: [{ id: "1", started_at: "2026-11-13T18:00Z", ended_at: "2026-11-13T19:00Z" }, {
      id: "2",
      started_at: "2026-11-13T18:30Z",
      ended_at: "2026-11-13T19:30Z",
    }],
  };
  const f = run("How long has she slept today?", s);
  equal(f.evidence, "incomplete");
  assert(f.issues.includes("inconsistent_sleep"));
  equal(f.completed_minutes, 0);
  equal(run("How many wet diapers since her last feeding?").evidence, "incomplete");
});
Deno.test("specific milestones never use unrelated titles and preserve first recorded precision", () => {
  const s = {
    ...base,
    milestones: [{ id: "unrelated", title: "Rolled over", occurred_on: "2026-11-13", date_precision: "day" }, {
      id: "wave",
      title: "Waved hello",
      occurred_on: "2026-10-01",
      date_precision: "month",
    }, { id: "han", title: "第一次揮手", occurred_on: "2026-09-12", date_precision: "day" }],
  };
  equal(run("Did she smile today?", s).evidence, "unknown");
  equal(run("When did she first wave hello?", s).records[0].id, "wave");
  equal(run("When did she first wave hello?", s).records[0].precision, "month");
  equal(run("佢第一次揮手係幾時？", s).records[0].id, "han");
  const near = {
    ...base,
    milestones: [{ id: "near", title: "Smiley toy", occurred_on: "2026-11-13", date_precision: "day" }],
  };
  equal(run("Did she smile today?", near).evidence, "unknown");
});
Deno.test("nap relative windows exclude overnight sleep and retain unique daytime anchor", () => {
  const feed = { id: "f", event_type: "feeding", volume_ml: 80, occurred_at: "2026-11-13T19:00Z" };
  const overnight = { id: "night", started_at: "2026-11-13T08:00Z", ended_at: "2026-11-13T09:00Z" };
  const nap = { id: "nap", started_at: "2026-11-13T17:00Z", ended_at: "2026-11-13T18:00Z" };
  equal(run("How much milk after her nap?", { ...base, events: [feed], sleep: [overnight] }).evidence, "incomplete");
  const f = run("How much milk after her nap?", { ...base, events: [feed], sleep: [overnight, nap] });
  equal(f.value, 80);
  assert(!f.issues.includes("ambiguous_anchor"));
});
Deno.test("historical care reports expose typed detail and latest facts only through their window end", () => {
  const s = {
    ...base,
    events: [{ id: "y-feed", event_type: "feeding", volume_ml: 60, occurred_at: "2026-11-12T18:00Z" }, {
      id: "new-feed",
      event_type: "feeding",
      volume_ml: 90,
      occurred_at: "2026-11-13T18:00Z",
    }, {
      id: "weight",
      event_type: "weight",
      weight_kg: 6,
      measurement_date: "2026-11-12",
      occurred_at: "2026-11-12T08:00Z",
    }],
    sleep: [{ id: "sleep", started_at: "2026-11-13T06:00Z", ended_at: "2026-11-13T08:00Z" }],
    milestones: [{ id: "m", title: "A memory", occurred_on: "2026-11-12", date_precision: "day" }],
  };
  const f = run("Detailed care report yesterday?", s);
  equal(f.last_feeding?.id, "y-feed");
  equal(f.last_sleep?.id, "sleep");
  equal(f.last_sleep?.end, null);
  assert(f.records.some((r) => r.domain === "feeding"));
  assert(f.records.some((r) => r.domain === "sleep"));
  assert(f.records.some((r) => r.domain === "weight"));
  assert(f.records.some((r) => r.domain === "milestone"));
  equal(f.completed_minutes, 0);
  equal(f.open_minutes, 60);
});
Deno.test("feeding totals and care reports sum exact stored hundredths", () => {
  const s = {
    ...base,
    events: [{ id: "a", event_type: "feeding", volume_ml: 0.1, occurred_at: "2026-11-13T18:00Z" }, {
      id: "b",
      event_type: "feeding",
      volume_ml: 0.2,
      occurred_at: "2026-11-13T19:00Z",
    }],
  };
  equal(run("How much milk today?", s).value, 0.3);
  equal(run("Care report today?", s).feeding_ml, 0.3);
});
Deno.test("historical day report excludes the following midnight from latest facts", () => {
  const s = {
    ...base,
    events: [{ id: "old", event_type: "feeding", volume_ml: 60, occurred_at: "2026-11-12T18:00Z" }, {
      id: "midnight",
      event_type: "feeding",
      volume_ml: 90,
      occurred_at: "2026-11-13T07:00Z",
    }],
  };
  const f = run("Care report yesterday?", s);
  equal(f.last_feeding?.id, "old");
  equal(f.feeding_ml, 60);
});
Deno.test("milestone action modifiers do not collapse goodbye into hello", () => {
  const s = {
    ...base,
    milestones: [{ id: "hello", title: "Waved hello", occurred_on: "2026-11-13", date_precision: "day" }],
  };
  equal(run("When did she first wave goodbye?", s).evidence, "unknown");
});
Deno.test("date-only weights tied on the latest day retain candidates without an invented order", () => {
  const s = {
    ...base,
    events: [{
      id: "a",
      event_type: "weight",
      weight_kg: 6.1,
      measurement_date: "2026-11-12",
      occurred_at: "2026-11-12T18:00Z",
    }, {
      id: "b",
      event_type: "weight",
      weight_kg: 6.2,
      measurement_date: "2026-11-12",
      occurred_at: "2026-11-12T19:00Z",
    }, {
      id: "older",
      event_type: "weight",
      weight_kg: 6,
      measurement_date: "2026-11-11",
      occurred_at: "2026-11-11T18:00Z",
    }],
  };
  const f = run("What was her last weight?", s);
  equal(f.records.map((r) => r.id).sort(), ["a", "b"]);
  equal(f.count, 3);
  equal(f.evidence, "incomplete");
  assert(f.issues.includes("ambiguous_order"));
  equal(f.value, undefined);
  const q = interpretReadQuery("What was her last weight?", c)!;
  const exact = calculateQuery({ ...q, target_id: "b" }, s, c, { id: child, name: "Victoria" });
  equal(exact.records.length, 1);
  equal(exact.value, 6.2);
  assert(!exact.issues.includes("ambiguous_order"));
});
Deno.test("month-only and day milestone intervals preserve every possible first or latest candidate", () => {
  const s = {
    ...base,
    milestones: [{ id: "month", title: "Waved hello", occurred_on: "2026-07-01", date_precision: "month" }, {
      id: "day",
      title: "Waved hello",
      occurred_on: "2026-07-15",
      date_precision: "day",
    }],
  };
  for (const text of ["When did she first wave hello?", "When did she last wave hello?"]) {
    const f = run(text, s);
    equal(f.records.map((r) => r.id).sort(), ["day", "month"]);
    equal(f.evidence, "incomplete");
    assert(f.issues.includes("ambiguous_order"));
  }
  const separated = {
    ...s,
    milestones: [s.milestones[0], {
      id: "next",
      title: "Waved hello",
      occurred_on: "2026-08-01",
      date_precision: "day",
    }],
  };
  equal(run("When did she first wave hello?", separated).records.map((r) => r.id), ["month"]);
  equal(run("When did she last wave hello?", separated).records.map((r) => r.id), ["next"]);
});
Deno.test("same-instant feed ties cannot expose an arbitrary individual amount or elapsed target", () => {
  const s = {
    ...base,
    events: [{ id: "a", event_type: "feeding", volume_ml: 60, occurred_at: "2026-11-13T18:00:00Z" }, {
      id: "b",
      event_type: "feeding",
      volume_ml: 90,
      occurred_at: "2026-11-13T18:00:00Z",
    }],
  };
  for (const text of ["When was her last feeding?", "How long since she last ate?"]) {
    const f = run(text, s);
    equal(f.records.length, 2);
    equal(f.evidence, "incomplete");
    equal(f.value, undefined);
    assert(f.issues.includes("ambiguous_order"));
  }
});
Deno.test("reports suppress tied latest feeding and sleep helpers while retaining detail candidates", () => {
  const s = {
    ...base,
    events: [{ id: "a", event_type: "feeding", volume_ml: 60, occurred_at: "2026-11-13T18:00:00Z" }, {
      id: "b",
      event_type: "feeding",
      volume_ml: 90,
      occurred_at: "2026-11-13T18:00:00Z",
    }],
    sleep: [{ id: "s1", started_at: "2026-11-13T17:00:00Z", ended_at: "2026-11-13T18:00:00Z" }, {
      id: "s2",
      started_at: "2026-11-13T17:00:00Z",
      ended_at: "2026-11-13T19:00:00Z",
    }],
  };
  const f = run("Care report today?", s);
  equal(f.last_feeding, undefined);
  equal(f.last_sleep, undefined);
  equal(f.sleep_state, "unknown");
  equal(f.evidence, "incomplete");
  assert(f.issues.includes("ambiguous_order"));
  equal(f.records.filter((r) => r.domain === "feeding").length, 2);
  equal(f.records.filter((r) => r.domain === "sleep").length, 2);
  equal(f.feeding_ml, 150);
});
Deno.test("captured spring and fall transitions produce 23-hour and 25-hour sleep days", () => {
  for (
    const [day, start, end, transition, before, after, minutes] of [
      ["2026-03-08", "2026-03-08T08:00Z", "2026-03-09T07:00Z", "2026-03-08T10:00Z", -28800, -25200, 1380],
      ["2026-11-01", "2026-11-01T07:00Z", "2026-11-02T08:00Z", "2026-11-01T09:00Z", -25200, -28800, 1500],
    ] as const
  ) {
    const local = {
      ...c,
      reference_at: end,
      utc_offset_seconds: after,
      zone_offsets: [{ from: "2025-03-01T00:00Z", seconds: before }, { from: transition, seconds: after }],
    };
    const q = { ...interpretReadQuery("How long has she slept today?", c)!, day };
    const f = calculateQuery(q, { ...base, sleep: [{ id: "s", started_at: start, ended_at: end }] }, local, {
      id: child,
      name: "Victoria",
    });
    equal(f.completed_minutes, minutes);
  }
});
Deno.test("explicit first selector applies to amounts as well as timestamps", () => {
  const snapshot = {
    ...base,
    events: [{ id: "first", event_type: "feeding", volume_ml: 30, occurred_at: "2026-11-13T17:00Z" }, {
      id: "last",
      event_type: "feeding",
      volume_ml: 60,
      occurred_at: "2026-11-13T19:00Z",
    }],
  };
  for (const text of ["How much was her first feed today?", "When was her first feed today?"]) {
    const f = run(text, snapshot);
    equal(f.query.operation, "first");
    equal(f.records[0].id, "first");
    equal(f.value, 30);
  }
});
