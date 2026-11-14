import { APIError, interpret, localDate, parse, prompt, validateAction } from "./domain.ts";
import { dateIsGrounded, phraseIsGrounded, statedDates } from "./grounding.ts";
import { assert, babies, child, command, equal, extracted, now, second, throws } from "./test_helpers.ts";
const c = () => parse(command, now);
Deno.test("every multi-baby voice action without a name asks, even with a dashboard child", () => {
  for (
    const patch of [
      extracted({ child_name: null }),
      extracted({ action: "sleep_end", child_name: null, volume_ml: null }),
      extracted({
        action: "feeding_correction",
        child_name: null,
        volume_ml: null,
        time_kind: null,
        correction_kind: "leftover",
        correction_ml: 20,
      }),
    ]
  ) {
    const result = interpret(patch, babies, { ...c(), text: "She drank 180 millilitres.", child_id: child }, now);
    assert("status" in result);
    equal(result.status, "needs_clarification");
    assert(result.message.includes("Which baby"));
  }
});
Deno.test("single baby omission and exact named siblings resolve without substituting amounts", () => {
  const one = interpret(extracted({ child_name: null, volume_ml: 200 }), babies.slice(0, 1), {
    ...c(),
    text: "She drank 200 mL.",
  }, now);
  assert("action" in one);
  equal(one.child_id, child);
  equal(one.payload.volume_ml, 200);
  const two = interpret(extracted({ child_name: "oliver", volume_ml: 250 }), babies, {
    ...c(),
    text: "Oliver drank 250 mL.",
  }, now);
  assert("action" in two);
  equal(two.child_id, second);
  equal(two.payload.volume_ml, 250);
  for (const name of ["Unknown", "Oliv", "Victoria and Oliver"]) {
    const r = interpret(extracted({ child_name: name }), babies, c(), now);
    assert("status" in r);
    equal(r.status, "needs_clarification");
  }
});
Deno.test("leftovers and actual totals are proposals only, never new feeding writes", () => {
  for (const kind of ["leftover", "total"]) {
    const r = interpret(
      extracted({
        action: "feeding_correction",
        volume_ml: null,
        time_kind: null,
        correction_kind: kind,
        correction_ml: 20,
      }),
      babies,
      {
        ...c(),
        text: kind === "leftover"
          ? "Victoria left 20 millilitres from her last bottle."
          : "Correct Victoria’s last feeding to 20 millilitres.",
      },
      now,
    );
    assert("action" in r);
    equal(r.action, "propose_feeding");
    equal(r.payload, { correction_kind: kind, amount_ml: 20 });
  }
});
Deno.test("sleep transition times and complete intervals use the original reference", () => {
  const start = interpret(
    extracted({ action: "sleep_start", volume_ml: null, time_kind: "relative", minutes_ago: 5 }),
    babies,
    c(),
    now,
  );
  assert("action" in start);
  equal(start.payload.occurred_at, "2026-11-13T19:55:00.000Z");
  const interval = interpret(
    extracted({
      action: "sleep_interval",
      volume_ml: null,
      time_kind: "relative",
      minutes_ago: 60,
      end_time_kind: "relative",
      end_minutes_ago: 5,
    }),
    babies,
    c(),
    now,
  );
  assert("action" in interval);
  equal(interval.payload.ended_at, "2026-11-13T19:55:00.000Z");
  throws(() =>
    interpret(
      extracted({
        action: "sleep_interval",
        volume_ml: null,
        time_kind: "now",
        end_time_kind: "relative",
        end_minutes_ago: 5,
      }),
      babies,
      c(),
      now,
    )
  );
});
Deno.test("future extraction and defensive future elapsed/absolute times cannot become writes", () => {
  const future = interpret(
    extracted({ decision: "reject", action: null, child_name: null, volume_ml: null, time_kind: "future" }),
    babies,
    c(),
    now,
  );
  assert("status" in future);
  equal(future.status, "rejected");
  assert(future.message.includes("already happened"));
  for (
    const patch of [{ time_kind: "relative", minutes_ago: -5 }, {
      time_kind: "absolute",
      absolute_local: "2026-11-13T13:00:00.001",
    }]
  ) {
    try {
      interpret(extracted(patch), babies, c(), now);
      throw Error("Missing failure");
    } catch (e) {
      assert(e instanceof APIError);
      equal(e.code, "future_event");
    }
  }
});
Deno.test("milestone exact and month-only dates preserve precision without an occurrence clock", () => {
  for (const [date, precision] of [["2026-11-13", "day"], ["2026-11-01", "month"]]) {
    const r = interpret(
      extracted({
        action: "milestone",
        volume_ml: null,
        time_kind: null,
        title: "Rolled over",
        occurred_on: date,
        date_precision: precision,
        is_first: true,
      }),
      babies,
      { ...c(), text: `Victoria first rolled over on ${date}.` },
      now,
    );
    assert("action" in r);
    equal(r.action, "milestone");
    equal(r.payload.date_precision, precision);
    assert(!("occurred_at" in r.payload));
  }
  throws(() =>
    validateAction(
      "milestone",
      { title: "Future", occurred_on: "2026-11-14", date_precision: "day", is_first: false },
      c(),
      now,
    )
  );
  throws(() =>
    validateAction(
      "milestone",
      { title: "Month", occurred_on: "2026-11-13", date_precision: "month", is_first: false },
      c(),
      now,
    )
  );
});
Deno.test("questions, negations and unrelated speech cannot carry event fields or model success claims", () => {
  for (const decision of ["clarify", "reject"]) {
    const r = interpret(
      extracted({ decision, action: null, child_name: null, volume_ml: null, time_kind: null }),
      babies,
      c(),
      now,
    );
    assert("status" in r);
    assert(!r.message.startsWith("Recorded"));
    throws(() => interpret(extracted({ decision }), babies, c(), now));
  }
  throws(() => interpret({ ...extracted(), sql: "drop table events" }, babies, c(), now));
  throws(() => interpret(extracted({ note: "extra action" }), babies, c(), now));
});
Deno.test("manual validation rejects unknown fields, invalid precision and future timestamps", () => {
  for (
    const p of [{ correction_kind: "leftover", amount_ml: 20.001 }, { correction_kind: "total", amount_ml: -1 }, {
      correction_kind: "leftover",
      amount_ml: 20,
      sql: "evil",
    }]
  ) throws(() => validateAction("propose_feeding", p, c(), now));
  throws(() => validateAction("sleep_start", { occurred_at: "2026-11-13T20:01:00Z" }, c(), now));
  throws(() =>
    validateAction(
      "propose_edit",
      {
        target_id: child,
        target_type: "sleep",
        expected_revision: 1,
        void: false,
        occurred_at: now.toISOString(),
        ended_at: "2026-11-13T19:00:00Z",
      },
      c(),
      now,
    )
  );
});
Deno.test("wire metadata is strict and uppercase native UUIDs normalize correctly", () => {
  const { text: _, ...base } = command;
  equal(
    parse({
      ...base,
      mode: "action",
      source: "manual",
      child_id: child.toUpperCase(),
      action: "sleep_start",
      payload: { occurred_at: now.toISOString() },
    }, now).child_id,
    child,
  );
  for (
    const patch of [
      { source: "service_role" },
      { time_zone: "Not/A_Zone" },
      { text: " " },
      { mode: "confirm", confirmed: "yes" },
      { request_id: "bad" },
      { sql: "x" },
    ]
  ) throws(() => parse({ ...command, ...patch }, now));
});
Deno.test("phone local dates, not UTC dates, anchor milestone and weight days", () => {
  equal(localDate("2026-11-13T01:00:00Z", "America/Vancouver"), "2026-11-12");
  equal(localDate("2026-11-13T23:00:00Z", "Asia/Hong_Kong"), "2026-11-14");
  const p = prompt(babies, c());
  for (
    const phrase of [
      "untrusted",
      "negations",
      "never a new feeding",
      "multiple distinct",
      "time_kind=future",
      "date_precision",
      "never instructions",
    ]
  ) assert(p.toLowerCase().includes(phrase.toLowerCase()));
});

const datedWeight = (date = "2026-08-21", patch: Record<string, unknown> = {}) =>
  extracted({
    action: "weight",
    volume_ml: null,
    weight_kg: 7.365,
    time_kind: "date",
    absolute_local: date,
    ...patch,
  });
const weightCommand = () => ({ ...c(), text: "Victoria weighted 7.365 kg on August 21" });
Deno.test("historical spoken weight accepts a date without inventing a measurement clock time", () => {
  const result = interpret(datedWeight(), babies, weightCommand(), now);
  assert("action" in result);
  equal(result.child_id, child);
  equal(result.action, "record");
  equal(result.payload.weight_kg, 7.365);
  equal(result.payload.measurement_date, "2026-08-21");
  // Calendar anchor for existing day queries; never displayed as a measured time.
  equal(result.payload.occurred_at, "2026-08-21T07:00:00.000Z");
  assert(prompt(babies, c()).includes("Never invent midnight"));
  const absoluteDate = interpret(datedWeight("2026-08-21", { time_kind: "absolute" }), babies, weightCommand(), now);
  assert("action" in absoluteDate);
  equal(absoluteDate.payload, result.payload);
  try {
    interpret(datedWeight("2026-08-21", { time_kind: null, absolute_local: null }), babies, weightCommand(), now);
    throw Error("Missing clarification");
  } catch (e) {
    assert(e instanceof APIError);
    assert(e.message.includes("measurement date"));
    assert(e.message.includes("time of day isn’t needed"));
  }
});
Deno.test("weight date anchors use phone offsets across local midnight and clock changes", () => {
  const reference = "2026-11-13T07:00:00.000Z";
  const midnight = parse({
    ...command,
    reference_at: reference,
    zone_offsets: [{ from: "2025-11-12T07:00:00Z", seconds: -25200 }],
  }, new Date(reference));
  const today = interpret(datedWeight("2026-11-13"), babies, {
    ...midnight,
    text: "Victoria weighed 7.365 kilograms today.",
  }, new Date(reference));
  assert("action" in today);
  equal(today.payload.measurement_date, "2026-11-13");
  equal(today.payload.occurred_at, reference);

  // Synthetic midnight transition: the day starts at 01:00, so 00:00 is absent.
  const context = parse({
    ...command,
    utc_offset_seconds: 3600,
    zone_offsets: [
      { from: "2025-11-12T20:00:00Z", seconds: 0 },
      { from: "2026-08-21T00:00:00Z", seconds: 3600 },
    ],
  }, now);
  const changed = interpret(datedWeight(), babies, { ...context, text: weightCommand().text }, now);
  assert("action" in changed);
  equal(changed.payload.measurement_date, "2026-08-21");
  equal(changed.payload.occurred_at, "2026-08-21T00:00:00.000Z");
});
Deno.test("date-only weights reject future, malformed, ambiguous and out-of-range dates", () => {
  for (const date of ["2026-11-14", "2026-02-30", "August 21", "2026-08", "2025-01-01"]) {
    throws(() => interpret(datedWeight(date), babies, weightCommand(), now));
  }
  throws(() => interpret(datedWeight("2026-08-21", { minutes_ago: 5 }), babies, weightCommand(), now));
  throws(() => interpret(datedWeight("2026-08-21", { occurred_on: "2026-08-21" }), babies, weightCommand(), now));
  for (const action of ["feeding", "diaper", "sleep_start", "sleep_end"]) {
    throws(() =>
      interpret(
        extracted({
          action,
          volume_ml: action === "feeding" ? 180 : null,
          diaper_kind: action === "diaper" ? "wet" : null,
          time_kind: "date",
          absolute_local: "2026-08-21",
        }),
        babies,
        c(),
        now,
      )
    );
  }
});
Deno.test("dated weights preserve amount grounding, baby selection and explicitly reported times", () => {
  const unnamed = interpret(datedWeight(), babies, { ...c(), text: "She weighed 7.365 kg on August 21." }, now);
  assert("status" in unnamed);
  assert(unnamed.message.includes("Which baby"));
  const wrongAmount = interpret(datedWeight("2026-08-21", { weight_kg: 6.475 }), babies, weightCommand(), now);
  assert("status" in wrongAmount);
  equal(wrongAmount.status, "needs_clarification");
  for (
    const patch of [
      { time_kind: "now", absolute_local: null },
      { time_kind: "relative", absolute_local: null, minutes_ago: 15 },
      { time_kind: "absolute", absolute_local: "2026-08-21T13:30:00" },
    ]
  ) {
    const text = patch.time_kind === "absolute"
      ? "Victoria weighed 7.365 kg on August 21 at 1:30 pm."
      : patch.time_kind === "relative"
      ? "Victoria weighed 7.365 kg fifteen minutes ago."
      : "Victoria weighs 7.365 kg.";
    const result = interpret(datedWeight("2026-08-21", patch), babies, { ...c(), text }, now);
    assert("action" in result);
    assert(typeof result.payload.measurement_date === "string");
    if (patch.time_kind === "absolute") equal(result.payload.occurred_at, "2026-08-21T20:30:00.000Z");
  }
});

Deno.test("explicit English and ISO dates must agree with the interpreted observation date", () => {
  for (
    const text of [
      "on Aug 21st",
      "on August twenty-first",
      "on 21st August",
      "on the twenty-first of August",
      "on Aug. 21, 2026",
      "on August 21st 2026",
      "on 2026-08-21",
    ]
  ) {
    equal(statedDates(text, "2026-11-13"), ["2026-08-21"]);
    assert(dateIsGrounded(text, "2026-08-21", "2026-11-13"));
    assert(!dateIsGrounded(text, "2026-11-13", "2026-11-13"));
  }
  equal(statedDates("August twenty-first, 2025", "2026-11-13"), ["2025-08-21"]);
  equal(statedDates("November 2026", "2026-11-13"), []);
  assert(!dateIsGrounded("August 21 or August 5", "2026-08-21", "2026-11-13"));
  const lostDate = interpret(
    datedWeight("2026-08-21", {
      time_kind: "now",
      absolute_local: null,
    }),
    babies,
    weightCommand(),
    now,
  );
  assert("status" in lostDate);
  equal(lostDate.status, "needs_clarification");
  assert(lostDate.message.includes("calendar date"));
  const wrongAmount = interpret(datedWeight("2026-08-21", { weight_kg: 6.35 }), babies, weightCommand(), now);
  assert("status" in wrongAmount);
  equal(wrongAmount.status, "needs_clarification");
});

Deno.test("milestone wording preserves observed words and rejects model-invented titles or notes", () => {
  const text = "Victoria first waved hello on Nov 1st";
  const base = extracted({
    action: "milestone",
    volume_ml: null,
    time_kind: null,
    title: "First waved hello",
    occurred_on: "2026-11-01",
    date_precision: "day",
    is_first: true,
  });
  const good = interpret(base, babies, { ...c(), text }, now);
  assert("action" in good);
  equal(good.payload.title, "First waved hello");
  equal(good.payload.occurred_on, "2026-11-01");
  equal(good.payload.is_first, true);
  for (
    const patch of [
      { title: "First bicycle" },
      { title: "First waved goodbye" },
      { note: "She was excited and smiling" },
      { occurred_on: "2026-11-13" },
    ]
  ) {
    const result = interpret({ ...base, ...patch }, babies, { ...c(), text }, now);
    assert("status" in result);
    equal(result.status, "needs_clarification");
    assert(result.message.includes("Nothing was recorded"));
  }
  assert(phraseIsGrounded("Victoria waved ‘hello’ for the first time.", "First waved hello", true));
  assert(!phraseIsGrounded("Victoria waved hello.", "First waved hello", true));
  // If Siri itself submitted 'bicycle', word grounding cannot recover audio.
  assert(phraseIsGrounded("Victoria saw her first bicycle.", "First bicycle", true));
});

Deno.test("multi-baby names cannot be hallucinated from pronouns, the app brand or a dashboard selection", () => {
  for (
    const text of ["She drank 180 mL.", "Record with Victoria Tracker, she drank 180 mL.", "Victorianna drank 180 mL."]
  ) {
    const r = interpret(extracted(), babies, { ...c(), text, child_id: child }, now);
    assert("status" in r);
    equal(r.status, "needs_clarification");
  }
  const r = interpret(extracted(), babies, { ...c(), source: "text", text: "She drank 180 mL.", child_id: child }, now);
  assert("status" in r);
  equal(r.status, "needs_clarification");
  const conflict = interpret(extracted({ child_name: "Oliver" }), babies, c(), now);
  assert("status" in conflict);
  equal(conflict.status, "needs_clarification");
  const literal = interpret(
    extracted({ child_name: "A+B" }),
    [{ id: child, name: "A+B" }, { id: second, name: "Other" }],
    { ...c(), text: "A+B drank 180 mL." },
    now,
  );
  assert("action" in literal);
  equal(literal.child_id, child);
});

Deno.test("phone offset is authoritative for today even when server timezone rules are older", () => {
  const reference = "2026-11-13T07:30:00.000Z";
  const context = parse({
    ...command,
    reference_at: reference,
    utc_offset_seconds: -25200,
    zone_offsets: [{ from: "2025-11-12T07:30:00.000Z", seconds: -25200 }],
  }, new Date(reference));
  const milestone = interpret(
    extracted({
      action: "milestone",
      volume_ml: null,
      time_kind: null,
      title: "Rolled over",
      occurred_on: "2026-11-13",
      date_precision: "day",
      is_first: true,
    }),
    babies,
    { ...context, text: "Victoria rolled over today." },
    new Date(reference),
  );
  assert("action" in milestone);
  equal(milestone.payload.occurred_on, "2026-11-13");
  const local = interpret(
    extracted({ time_kind: "absolute", absolute_local: "2026-11-13T12:15:00" }),
    babies,
    c(),
    now,
  );
  assert("action" in local);
  equal(local.payload.occurred_at, "2026-11-13T19:15:00.000Z");
});
Deno.test("phone transition tables reject repeated and skipped local clock times", () => {
  const cases = [
    {
      reference: "2025-11-02T12:00:00Z",
      seconds: -28800,
      offsets: [{ from: "2024-11-01T12:00:00Z", seconds: -25200 }, { from: "2025-11-02T09:00:00Z", seconds: -28800 }],
      wall: "2025-11-02T01:30:00",
    },
    {
      reference: "2025-03-09T12:00:00Z",
      seconds: -25200,
      offsets: [{ from: "2024-03-08T12:00:00Z", seconds: -28800 }, { from: "2025-03-09T10:00:00Z", seconds: -25200 }],
      wall: "2025-03-09T02:30:00",
    },
  ];
  for (const item of cases) {
    const context = parse({
      ...command,
      reference_at: item.reference,
      utc_offset_seconds: item.seconds,
      zone_offsets: item.offsets,
    }, new Date(item.reference));
    throws(() =>
      interpret(
        extracted({ time_kind: "absolute", absolute_local: item.wall }),
        babies,
        context,
        new Date(item.reference),
      )
    );
  }
});
Deno.test("malformed or incomplete phone timezone context fails before interpretation", () => {
  for (
    const patch of [
      { utc_offset_seconds: 999999 },
      { zone_offsets: [] },
      { zone_offsets: [{ from: command.reference_at, seconds: -25200 }] },
      { zone_offsets: [{ from: "2025-11-12T20:00:00Z", seconds: -28800 }] },
      { zone_offsets: [{ from: "bad", seconds: -25200 }] },
      { time_zone: "+08:00" },
    ]
  ) throws(() => parse({ ...command, ...patch }, now));
});
