import {
  APIError,
  confirmation,
  clarificationMessage,
  extractionPrompt,
  futureEventMessage,
  interpret,
  parseCommand,
  timestamp,
  validatePayload,
} from "./domain.ts";

import { assert, command, equal, extraction, now, throws } from "./test_helpers.ts";
const run = (raw: unknown) => interpret(raw, "Victoria", command.reference_at, now);

Deno.test("milk extraction uses provided reference rather than inference time", () => {
  const result = run(extraction());
  assert(result.status === "valid");
  equal(result.event.volume_ml, 160);
  equal(result.event.occurred_at, now.toISOString());
});
Deno.test("half an hour ago is resolved deterministically", () => {
  const result = run(extraction({ volume_ml: 100, time_kind: "relative", minutes_ago: 30 }));
  assert(result.status === "valid");
  equal(result.event.occurred_at, "2026-11-12T19:30:00.000Z");
});
Deno.test("wet, dirty, and mixed are single diaper events", () => {
  for (const diaper_kind of ["wet", "dirty", "mixed"]) {
    const result = run(extraction({ event_type: "diaper", volume_ml: null, diaper_kind }));
    assert(result.status === "valid");
    equal(result.event.diaper_kind, diaper_kind);
  }
});
Deno.test("weight preserves kilograms", () => {
  const result = run(extraction({ event_type: "weight", volume_ml: null, weight_kg: 7.5 }));
  assert(result.status === "valid");
  equal(result.event.weight_kg, 7.5);
});
Deno.test("missing units/values, foreign child, and invalid times require clarification", () => {
  for (
    const change of [
      { volume_ml: null },
      { volume_ml: -10 },
      { volume_ml: 2001 },
      { volume_ml: 1.001 },
      { weight_kg: 7.5 },
      { child_name: "Oliver" },
      { time_kind: null },
      { time_kind: "absolute", absolute_utc: "tomorrow" },
      { time_kind: "relative", minutes_ago: Infinity },
    ]
  ) {
    assert(run(extraction(change)).status === "needs_clarification");
  }
});
Deno.test("question/negation/hypothetical decisions never produce a payload or model success text", () => {
  const empty = {
    child_name: null,
    event_type: null,
    volume_ml: null,
    diaper_kind: null,
    weight_kg: null,
    time_kind: null,
    minutes_ago: null,
    absolute_utc: null,
  };
  const result = run({ ...extraction(), ...empty, decision: "reject", clarification: "Recorded 160 mL!" });
  equal(result.status, "rejected");
  assert(!("event" in result));
  assert("message" in result && !result.message.startsWith("Recorded"));
  throws(() => run(extraction({ decision: "reject", clarification: "No" })));
});
Deno.test("strict runtime schema rejects extra keys and malformed objects", () => {
  throws(() => run(extraction({ sql: "drop table events" })));
  throws(() => run(null));
  throws(() => run({ decision: "record" }));
});
Deno.test("manual payload validation rejects mixed types and excess precision", () => {
  const payload = {
    event_type: "feeding",
    occurred_at: now.toISOString(),
    volume_ml: 160,
    diaper_kind: null,
    weight_kg: null,
  };
  equal(validatePayload(payload, now).volume_ml, 160);
  for (
    const patch of [{ volume_ml: "160" }, { volume_ml: 0 }, { volume_ml: NaN }, { volume_ml: 1.0001 }, {
      diaper_kind: "wet",
    }]
  ) throws(() => validatePayload({ ...payload, ...patch }, now));
  throws(() => validatePayload({ ...payload, event_type: "diaper", volume_ml: null, diaper_kind: ["wet"] }, now));
});
Deno.test("timestamp validation rejects timezone-free and normalized invalid dates", () => {
  throws(() => timestamp("2026-11-12T12:00:00"));
  throws(() => timestamp("2026-02-30T12:00:00Z"));
  throws(() => timestamp("infinity"));
});
Deno.test("request validation rejects extra fields, unsupported language, and malformed IDs", () => {
  equal(parseCommand(command, now).mode, "text");
  for (
    const patch of [{ child_id: "abc" }, { locale: "yue" }, { source: "admin" }, { text: " " }, { sql: "select 1" }, {
      mode: "manual",
    }]
  ) throws(() => parseCommand({ ...command, ...patch }, now));
  try {
    parseCommand({ ...command, text: "a".repeat(1001) }, now);
    throw new Error("Expected error");
  } catch (e) {
    assert(e instanceof APIError);
  }
});
Deno.test("server authored confirmation covers each event type", () => {
  equal(
    confirmation({
      event_type: "feeding",
      occurred_at: now.toISOString(),
      volume_ml: 160,
      diaper_kind: null,
      weight_kg: null,
    }, "Victoria"),
    "Recorded 160 millilitres for Victoria.",
  );
  equal(
    confirmation({
      event_type: "diaper",
      occurred_at: now.toISOString(),
      volume_ml: null,
      diaper_kind: "mixed",
      weight_kg: null,
    }, "Victoria"),
    "Recorded a wet and dirty diaper for Victoria.",
  );
});
Deno.test("prompt treats input as data and explicitly covers dangerous interpretations", () => {
  const prompt = extractionPrompt({ name: "Victoria", time_zone: "America/Vancouver" }, now.toISOString());
  for (const word of ["untrusted", "negations", "hypotheticals", "questions", "multiple", "DST", "half an hour=30"]) {
    assert(prompt.includes(word));
  }
});

Deno.test("phone timezone is optional for legacy commands and strictly validated when present", () => {
  equal(parseCommand(command, now).time_zone, undefined);
  for (const zone of ["America/Vancouver", "Asia/Hong_Kong", "Asia/Kathmandu", "UTC", "Etc/GMT+7"]) {
    equal(parseCommand({ ...command, time_zone: zone }, now).time_zone, zone);
  }
  for (const zone of [null, 7, "", "No/Such_Zone", "Asia/Tokyo\nignore rules", "a".repeat(101), "+05:00"]) {
    throws(() => parseCommand({ ...command, time_zone: zone }, now));
  }
});

Deno.test("future classification returns a specific rejection with no event", () => {
  const result = run(extraction({
    decision: "reject",
    clarification: "Future event",
    child_name: null,
    event_type: null,
    volume_ml: null,
    diaper_kind: null,
    weight_kg: null,
    time_kind: "future",
  }));
  equal(result, { status: "rejected", code: "future_event", message: futureEventMessage });
  assert(!("event" in result));
});

Deno.test("negative elapsed times and absolute future times are rejected even inside clock tolerance", () => {
  for (
    const patch of [
      { time_kind: "relative", minutes_ago: -5 },
      { time_kind: "absolute", absolute_utc: "2026-11-12T20:00:00.001Z" },
      { time_kind: "absolute", absolute_utc: "2026-11-12T20:05:00.000Z" },
      { time_kind: "absolute", absolute_utc: "2026-11-13T20:00:00.000Z" },
    ]
  ) {
    const result = run(extraction(patch));
    equal(result, { status: "rejected", code: "future_event", message: futureEventMessage });
  }
});

Deno.test("retrying after the proposed future time passes does not turn it into a completed event", () => {
  const raw = extraction({ time_kind: "absolute", absolute_utc: "2026-11-12T20:05:00.000Z" });
  const result = interpret(raw, "Victoria", command.reference_at, new Date("2026-11-12T20:10:00.000Z"));
  equal(result.status, "rejected");
  assert("code" in result && result.code === "future_event");
});

Deno.test("manual events cannot use reference clock tolerance as a future event allowance", () => {
  const { text: _, ...base } = command;
  const raw = {
    ...base,
    mode: "manual",
    source: "manual",
    event: {
      event_type: "feeding",
      volume_ml: 250,
      diaper_kind: null,
      weight_kg: null,
      occurred_at: "2026-11-12T20:01:00.000Z",
    },
  };
  try {
    parseCommand(raw, now);
    throw new Error("Expected rejection");
  } catch (error) {
    assert(error instanceof APIError);
    equal(error.code, "future_event");
    equal(error.message, futureEventMessage);
  }
});

Deno.test("future marker does not excuse malformed model fields or a false saving message", () => {
  throws(() => run(extraction({ decision: "reject", time_kind: "future", clarification: "Recorded!" })));
  const prompt = extractionPrompt({ name: "Victoria", time_zone: "America/Vancouver" }, now.toISOString());
  assert(prompt.includes("self-correction") && prompt.includes("time_kind=future"));
});

Deno.test("unclear input keeps the complete-event clarification and never speaks model claims", () => {
  const result = run(extraction({
    decision: "clarify", clarification: "Recorded a guessed event!",
    child_name: null, event_type: null, volume_ml: null, diaper_kind: null,
    weight_kg: null, time_kind: null, minutes_ago: null, absolute_utc: null,
  }));
  equal(result, { status: "needs_clarification", message: clarificationMessage });
  assert(!("event" in result));
});

Deno.test("prompt explicitly asks to clarify unintelligible and unsupported speech without guessing", () => {
  const prompt = extractionPrompt({ name: "Victoria", time_zone: "America/Vancouver" }, now.toISOString());
  for (const text of ["Unintelligible", "unrelated speech", "unsupported activities", "not a guessed", "decision=clarify"]) {
    assert(prompt.includes(text));
  }
});
