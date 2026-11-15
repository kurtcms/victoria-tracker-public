import { conversationSchema, interpretConversation, knownCareQuery } from "./conversation.ts";
import { assert, babies, child, command, equal, extracted, now, second, throws } from "./test_helpers.ts";
import { parse } from "./domain.ts";

const selector = (patch: Record<string, unknown> = {}) => ({
  kind: "feeding",
  diaper_kind: null,
  title: null,
  expected_volume_ml: null,
  ...patch,
});
const changes = (patch: Record<string, unknown> = {}) =>
  Object.fromEntries([
    "correction_kind",
    "amount_ml",
    "diaper_kind",
    "weight_kg",
    "measurement_date",
    "occurred_at",
    "ended_at",
    "title",
    "note",
    "occurred_on",
    "date_precision",
  ].map((key) => [key, patch[key] ?? null]));
export const envelope = (patch: Record<string, unknown> = {}) => ({
  decision: "execute",
  operation: "batch",
  child_name: "Victoria",
  language: "en",
  evidence: "Victoria drank 180 mil.",
  actions: [{ evidence: "Victoria drank 180 mil.", extraction: extracted() }],
  selector: null,
  changes: null,
  remove: null,
  query: null,
  ...patch,
});
const run = (raw: unknown, text: string, profiles = babies) =>
  interpretConversation(raw, profiles, parse({ ...command, text, child_id: second }, now), now);
const clarification = (raw: unknown, text: string) => {
  const result = run(raw, text);
  assert("status" in result);
  equal(result.status, "needs_clarification");
};
const correction = (text: string, patch: Record<string, unknown> = {}) =>
  envelope({
    operation: "correct",
    evidence: text,
    actions: null,
    selector: selector(),
    changes: changes({ correction_kind: "total", amount_ml: 80 }),
    remove: false,
    ...patch,
  });
const question = (text: string, kind = "last_feeding", day: string | null = null) =>
  envelope({
    operation: "query",
    evidence: text,
    actions: null,
    query: { kind, day },
  });

Deno.test("one utterance resolves one explicitly named baby and atomically preserves all event clauses", () => {
  const text = "Victoria drank 180 mil and had a wet diaper.";
  const raw = envelope({
    evidence: text,
    actions: [
      { evidence: "Victoria drank 180 mil", extraction: extracted() },
      {
        evidence: "had a wet diaper.",
        extraction: extracted({ action: "diaper", child_name: null, volume_ml: null, diaper_kind: "wet" }),
      },
    ],
  });
  const result = run(raw, text);
  assert("operation" in result);
  equal(result.child_id, child);
  equal(result.operation, "batch");
  equal(result.payload, {
    actions: [
      {
        action: "record",
        payload: {
          event_type: "feeding",
          occurred_at: "2026-11-13T20:00:00.000Z",
          volume_ml: 180,
          diaper_kind: null,
          weight_kg: null,
        },
      },
      {
        action: "record",
        payload: {
          event_type: "diaper",
          occurred_at: "2026-11-13T20:00:00.000Z",
          volume_ml: null,
          diaper_kind: "wet",
          weight_kg: null,
        },
      },
    ],
  });
  for (
    const badText of [
      "She drank 180 mil and had a wet diaper.",
      "Victoria Tracker: she drank 180 mil and had a wet diaper.",
      "Victoria and Oliver drank 180 mil and had a wet diaper.",
    ]
  ) {
    clarification({ ...raw, evidence: badText, actions: [{ evidence: badText, extraction: extracted() }] }, badText);
  }
});

Deno.test("batch evidence cannot invent, omit, duplicate, reorder or change quantities in the submitted words", () => {
  const text = "Victoria drank 180 mil and had a wet diaper.";
  clarification(envelope(), text);
  clarification(
    envelope({ evidence: text, actions: [{ evidence: "Victoria drank 180 mil", extraction: extracted() }] }),
    text,
  );
  clarification(envelope({ evidence: text, actions: [{ evidence: text, extraction: extracted() }] }), text);
  const pieces = [
    { evidence: "Victoria drank 180 mil", extraction: extracted() },
    {
      evidence: "had a wet diaper.",
      extraction: extracted({ action: "diaper", volume_ml: null, diaper_kind: "dirty" }),
    },
  ];
  clarification(envelope({ evidence: text, actions: pieces }), text);
  clarification(envelope({ evidence: text, actions: [pieces[0], pieces[0]] }), text);
  clarification(envelope({ evidence: text, actions: [...pieces].reverse() }), text);
  clarification(
    envelope({
      actions: Array.from({ length: 6 }, () => ({ evidence: "Victoria drank 180 mil.", extraction: extracted() })),
    }),
    "Victoria drank 180 mil.",
  );
  clarification(
    envelope({ actions: [{ evidence: "Victoria drank 180 mil.", extraction: extracted({ volume_ml: 200 }) }] }),
    "Victoria drank 180 mil.",
  );
});

Deno.test("English and Cantonese questions cannot become writes even when the model misclassifies them", () => {
  for (
    const text of [
      "Did Victoria drink 180 mil?",
      "Victoria did not drink 180 mil.",
      "If Victoria drinks 180 mil, log it.",
      "Victoria飲咗180毫升未？",
      "Victoria冇飲180毫升",
      "如果Victoria飲180毫升就記低",
      "Should Victoria drink 180 mil?",
      "Say 'Victoria drank 180 mil' as an example.",
      "Did Victoria drink 180 mil",
      "Has Victoria drunk 180 mil",
      "Victoria未飲180毫升",
      "Victoria will drink 180 mil.",
      "Victoria will drink 180 mil tomorrow.",
      "Victoria聽日飲180毫升",
    ]
  ) {
    const result = run(envelope({ evidence: text, actions: [{ evidence: text, extraction: extracted() }] }), text);
    assert("status" in result);
  }
});

Deno.test("reported clocks and calendar days cannot be replaced by now or hallucinated absolute times", () => {
  for (
    const text of ["Victoria drank 180 mil yesterday.", "Victoria drank 180 mil at 1:30 pm.", "Victoria琴日飲咗180毫升"]
  ) {
    clarification(envelope({ evidence: text, actions: [{ evidence: text, extraction: extracted() }] }), text);
  }
  clarification(
    envelope({
      actions: [{
        evidence: "Victoria drank 180 mil.",
        extraction: extracted({ time_kind: "absolute", absolute_local: "2026-11-13T12:30:00" }),
      }],
    }),
    "Victoria drank 180 mil.",
  );
  const text = "Victoria drank 180 mil today at 12:30 pm.";
  const result = run(
    envelope({
      evidence: text,
      actions: [{
        evidence: text,
        extraction: extracted({ time_kind: "absolute", absolute_local: "2026-11-13T12:30:00" }),
      }],
    }),
    text,
  );
  assert("operation" in result);
  equal(
    ((result.payload.actions as Record<string, unknown>[])[0].payload as Record<string, unknown>).occurred_at,
    "2026-11-13T19:30:00.000Z",
  );
});

Deno.test("repeated same-kind event amounts and unreported relative times cannot be collapsed or invented", () => {
  for (const text of ["Victoria drank 180 mil and drank 180 mil.", "Victoria drank 180 mil then 180 mil."]) {
    clarification(envelope({ evidence: text, actions: [{ evidence: text, extraction: extracted() }] }), text);
  }
  const relative = "Victoria drank 180 mil five minutes ago.";
  clarification(envelope({ evidence: relative, actions: [{ evidence: relative, extraction: extracted() }] }), relative);
  clarification(
    envelope({
      evidence: "Victoria drank 180 mil.",
      actions: [{
        evidence: "Victoria drank 180 mil.",
        extraction: extracted({ time_kind: "relative", minutes_ago: 5 }),
      }],
    }),
    "Victoria drank 180 mil.",
  );
  for (const text of [relative, "Victoria五分鐘前飲咗180毫升"]) {
    const result = run(
      envelope({
        evidence: text,
        actions: [{ evidence: text, extraction: extracted({ time_kind: "relative", minutes_ago: 5 }) }],
      }),
      text,
    );
    assert("operation" in result);
    equal(
      ((result.payload.actions as Record<string, unknown>[])[0].payload as Record<string, unknown>).occurred_at,
      "2026-11-13T19:55:00.000Z",
    );
  }
});

Deno.test("code-switched and Chinese-number batches use exact original quantities per clause", () => {
  const text = "Victoria飲咗一百八十毫升奶，同埋換咗濕尿片。";
  const result = run(
    envelope({
      language: "yue",
      evidence: text,
      actions: [
        { evidence: "Victoria飲咗一百八十毫升奶", extraction: extracted() },
        { evidence: "換咗濕尿片。", extraction: extracted({ action: "diaper", volume_ml: null, diaper_kind: "wet" }) },
      ],
    }),
    text,
  );
  assert("operation" in result);
  equal(result.language, "yue");
  equal(result.payload.actions instanceof Array && result.payload.actions.length, 2);
  const bad = envelope({
    evidence: "Victoria drank 180 mil and Oliver drank 80 mil.",
    actions: [{ evidence: "Victoria drank 180 mil and Oliver drank 80 mil.", extraction: extracted() }],
  });
  clarification(bad, String(bad.evidence));
});

Deno.test("from old to new corrections independently bind both values and never silently swap them", () => {
  for (
    const text of [
      "Change Victoria’s last feed from 30ml to 80ml.",
      "Change Victoria’s last feed from 30 to 80 mil.",
      "Victoria上次飲奶由三十毫升改做八十毫升",
    ]
  ) {
    const result = run(correction(text, { selector: selector({ expected_volume_ml: 30 }) }), text);
    assert("operation" in result);
    equal(result.operation, "correct");
    equal(result.payload, {
      selector: { kind: "feeding", expected_volume_ml: 30 },
      changes: { correction_kind: "total", amount_ml: 80 },
      remove: false,
    });
    clarification(
      correction(text, {
        selector: selector({ expected_volume_ml: 80 }),
        changes: changes({ correction_kind: "total", amount_ml: 30 }),
      }),
      text,
    );
    clarification(correction(text), text);
  }
});

Deno.test("leftover mil corrections, latest wet deletion and diaper correction retain finite selectors", () => {
  for (const text of ["Victoria left twenty mil in the last bottle.", "Victoria上次支奶剩返二十毫升"]) {
    const result = run(correction(text, { changes: changes({ correction_kind: "leftover", amount_ml: 20 }) }), text);
    assert("operation" in result);
    equal(result.payload.changes, { correction_kind: "leftover", amount_ml: 20 });
    clarification(correction(text, { changes: changes({ correction_kind: "total", amount_ml: 20 }) }), text);
  }
  for (const text of ["Delete Victoria’s last wet diaper.", "刪除Victoria上次濕尿片"]) {
    const result = run(
      correction(text, {
        selector: selector({ kind: "diaper", diaper_kind: "wet" }),
        changes: changes(),
        remove: true,
      }),
      text,
    );
    assert("operation" in result);
    equal(result.payload, { selector: { kind: "diaper", diaper_kind: "wet" }, changes: {}, remove: true });
  }
  const text = "Change Victoria’s last diaper to dirty.";
  const result = run(
    correction(text, { selector: selector({ kind: "diaper" }), changes: changes({ diaper_kind: "dirty" }) }),
    text,
  );
  assert("operation" in result);
  equal(result.payload.changes, { diaper_kind: "dirty" });
  clarification(
    correction(text, { selector: selector({ kind: "diaper" }), changes: changes({ diaper_kind: "wet" }) }),
    text,
  );
});

Deno.test("unsupported older targets and mixed operations never become partial actions", () => {
  for (
    const text of [
      "Change Victoria’s second last feeding to 80 mil.",
      "Change Victoria’s feeding yesterday to 80 mil.",
      "Change Victoria’s last feeding to 80 mil and delete her last diaper.",
      "Victoria drank 80 mil and when was her last diaper?",
      "Change Victoria’s last feed to 80 mil and play music.",
    ]
  ) {
    const result = run(correction(text), text);
    assert("status" in result);
  }
});

Deno.test("closed read queries use phone-local dates and cannot invent totals, switch kinds or save records", () => {
  for (
    const [text, kind] of [
      ["When was Victoria’s last feeding?", "last_feeding"],
      ["How many wet diapers did Victoria have today?", "wet_count"],
      ["Victoria今日有冇大便？", "has_dirty"],
      ["Victoria今日瞓咗幾耐？", "sleep_total"],
      ["What was Victoria’s latest weight?", "last_weight"],
      ["Summarize Victoria’s day today.", "day_summary"],
    ]
  ) {
    const result = run(question(text, kind), text);
    assert("operation" in result);
    equal(result.operation, "query");
    equal(result.payload, { kind, day: kind.startsWith("last_") ? null : "2026-11-13" });
    assert(!("actions" in result.payload));
  }
  clarification(
    question("How many wet diapers did Victoria have today?", "dirty_count"),
    "How many wet diapers did Victoria have today?",
  );
  clarification(question("Victoria drank 180 mil.", "last_feeding"), "Victoria drank 180 mil.");
  clarification(
    question("How many wet diapers did Victoria have yesterday?", "wet_count", "2026-11-13"),
    "How many wet diapers did Victoria have yesterday?",
  );
  clarification(
    question("How many wet diapers did Victoria have last Friday?", "wet_count"),
    "How many wet diapers did Victoria have last Friday?",
  );
  clarification(
    question("How many wet diapers and how long did Victoria sleep today?", "sleep_total"),
    "How many wet diapers and how long did Victoria sleep today?",
  );
  const yesterday = run(
    question("How many wet diapers did Victoria have yesterday?", "wet_count"),
    "How many wet diapers did Victoria have yesterday?",
  );
  assert("operation" in yesterday);
  equal(yesterday.payload.day, "2026-11-12");
  const dated = run(
    question("How many wet diapers did Victoria have on August 9?", "wet_count", "2026-08-09"),
    "How many wet diapers did Victoria have on August 9?",
  );
  assert("operation" in dated);
  equal(dated.payload.day, "2026-08-09");
});

Deno.test("latest weight, sleep and milestone changes produce typed proposals without new events", () => {
  for (
    const [text, kind, patch] of [
      ["Change Victoria’s last weight to seven point five kilograms.", "weight", { weight_kg: 7.5 }],
      ["Change Victoria’s last sleep start to 2026-11-13T18:00:00.000Z.", "sleep", {
        occurred_at: "2026-11-13T18:00:00.000Z",
      }],
      ["Change Victoria’s last milestone title to waved hello.", "milestone", { title: "waved hello" }],
    ] as const
  ) {
    const result = run(correction(text, { selector: selector({ kind }), changes: changes(patch) }), text);
    assert("operation" in result);
    equal(result.operation, "correct");
    equal(result.payload.changes, patch);
  }
  for (const kind of ["feeding", "weight", "sleep", "milestone"]) {
    const text = `Delete Victoria’s last ${kind}.`;
    const result = run(correction(text, { selector: selector({ kind }), changes: changes(), remove: true }), text);
    assert("operation" in result);
    equal(result.payload.remove, true);
  }
});

Deno.test("schema and runtime reject instructions, unrelated correction fields and unknown operation authority", () => {
  throws(() => run({ ...envelope(), sql: "select * from events" }, "Victoria drank 180 mil."));
  throws(() => run(envelope({ operation: "execute_sql" }), "Victoria drank 180 mil."));
  const text = "Change Victoria’s last feeding to 80 mil.";
  clarification(
    correction(text, { changes: changes({ correction_kind: "total", amount_ml: 80, weight_kg: 7 }) }),
    text,
  );
  assert(conversationSchema.additionalProperties === false);
});

Deno.test("explicit future speech remains informative even when extraction rejects it", () => {
  for (const text of ["Victoria drank 250 mil five minutes from now.", "Victoria五分鐘後飲250毫升"]) {
    const response = run(envelope({ decision: "reject", operation: null, actions: null, evidence: text }), text);
    assert("status" in response);
    equal(response.status, "rejected");
    equal(response.code, "future_event");
  }
});
Deno.test("Cantonese milestone wording and calendar dates are grounded without English word boundaries", () => {
  const text = "Victoria喺8月9日第一次識得坐";
  const response = run(
    envelope({
      evidence: text,
      actions: [{
        evidence: text,
        extraction: extracted({
          action: "milestone",
          volume_ml: null,
          time_kind: null,
          title: "第一次識得坐",
          occurred_on: "2026-08-09",
          date_precision: "day",
          is_first: true,
        }),
      }],
    }),
    text,
  );
  assert("operation" in response);
  equal((response.payload.actions as { payload: { title: string } }[])[0].payload.title, "第一次識得坐");
  clarification(
    envelope({
      evidence: text,
      actions: [{
        evidence: text,
        extraction: extracted({
          action: "milestone",
          volume_ml: null,
          time_kind: null,
          title: "第一次識得坐",
          occurred_on: "2026-08-05",
          date_precision: "day",
          is_first: true,
        }),
      }],
    }),
    text,
  );
});

Deno.test("negative contractions, interrogatives without punctuation and Chinese negation never become writes", () => {
  for (
    const text of [
      "Victoria doesn’t drink 180 mil.",
      "Victoria doesn't drink 180 mil.",
      "Victoria hadn't drunk 180 mil.",
      "Why did Victoria drink 180 mil",
      "Where did Victoria drink 180 mil",
      "Victoria不飲奶180毫升",
    ]
  ) {
    const response = run(envelope({ evidence: text, actions: [{ evidence: text, extraction: extracted() }] }), text);
    assert("status" in response, text);
    equal(response.status, "rejected");
  }
});
Deno.test("Cantonese unfinished-bottle wording permits only a validated leftover proposal", () => {
  const text = "Victoria支奶仲有20mil未飲完";
  const response = run(correction(text, { changes: changes({ correction_kind: "leftover", amount_ml: 20 }) }), text);
  assert("operation" in response);
  equal(response.operation, "correct");
  equal((response.payload.changes as Record<string, unknown>).amount_ml, 20);
  const negated = "Victoria支奶冇剩20mil未飲完";
  const rejection = run(
    correction(negated, { changes: changes({ correction_kind: "leftover", amount_ml: 20 }) }),
    negated,
  );
  assert("status" in rejection);
});
Deno.test("reported noon cannot silently default to now and resolves to the actual local noon", () => {
  const text = "Victoria drank 180 mil at noon.";
  clarification(envelope({ evidence: text, actions: [{ evidence: text, extraction: extracted() }] }), text);
  const response = run(
    envelope({
      evidence: text,
      actions: [{
        evidence: text,
        extraction: extracted({ time_kind: "absolute", absolute_local: "2026-11-13T12:00:00" }),
      }],
    }),
    text,
  );
  assert("operation" in response);
  equal(
    (response.payload.actions as { payload: { occurred_at: string } }[])[0].payload.occurred_at,
    "2026-11-13T19:00:00.000Z",
  );
});

Deno.test("multi-event speech is not rejected by an unrelated false first-occurrence flag", () => {
  const text = "Victoria drank eighty mil and had a wet diaper";
  const raw = envelope({
    evidence: text,
    actions: [
      { evidence: "Victoria drank eighty mil", extraction: extracted({ volume_ml: 80, is_first: false }) },
      {
        evidence: "had a wet diaper",
        extraction: extracted({ action: "diaper", volume_ml: null, diaper_kind: "wet", is_first: false }),
      },
    ],
  });
  const result = run(raw, text);
  assert("operation" in result);
  equal(result.operation, "batch");
  const actions = result.payload.actions as { action: string; payload: Record<string, unknown> }[];
  equal(actions.length, 2);
  equal(actions[0].payload.volume_ml, 80);
  equal(actions[1].payload.diaper_kind, "wet");
});

Deno.test("batch extraction schema prevents event fields leaking between action types", () => {
  const branches = conversationSchema.properties.interpretation as { anyOf: { properties: Record<string, unknown> }[] };
  const actionSchema = branches.anyOf[0].properties.actions as {
    items: {
      properties: { extraction: { anyOf: { properties: Record<string, { type: unknown; enum?: unknown[] }> }[] } };
    };
  };
  const extraction = actionSchema.items.properties.extraction;
  assert(Array.isArray(extraction.anyOf));
  const feeding = extraction.anyOf.find((s) => s.properties.action.enum?.[0] === "feeding");
  const diaper = extraction.anyOf.find((s) => s.properties.action.enum?.[0] === "diaper");
  const milestone = extraction.anyOf.find((s) => s.properties.action.enum?.[0] === "milestone");
  assert(feeding && diaper && milestone);
  equal(feeding.properties.diaper_kind.type, "null");
  equal(feeding.properties.is_first.type, "null");
  equal(diaper.properties.volume_ml.type, "null");
  equal(diaper.properties.is_first.type, "null");
  equal(milestone.properties.volume_ml.type, "null");
  equal(milestone.properties.is_first.type, "boolean");
});

Deno.test("ignoring a false metadata flag never hides another action or meaningful cross-event values", () => {
  const text = "Victoria drank eighty mil and had a wet diaper";
  clarification(
    envelope({
      evidence: text,
      actions: [{ evidence: text, extraction: extracted({ volume_ml: 80, is_first: false }) }],
    }),
    text,
  );
  const conflicting = envelope({
    evidence: text,
    actions: [
      {
        evidence: "Victoria drank eighty mil",
        extraction: extracted({ volume_ml: 80, weight_kg: 7.5, is_first: false }),
      },
      {
        evidence: "had a wet diaper",
        extraction: extracted({ action: "diaper", volume_ml: null, diaper_kind: "wet", is_first: false }),
      },
    ],
  });
  const result = run(conflicting, text);
  assert("status" in result);
  equal(result.status, "needs_clarification");
  assert(!result.message.includes("one complete action"));
});

Deno.test("operation-specific schema requires correction fields and forbids batch defaults", () => {
  const root = conversationSchema.properties.interpretation as {
    anyOf: { properties: Record<string, { type?: unknown; enum?: unknown[] }> }[];
  } | undefined;
  assert(root && Array.isArray(root.anyOf));
  const correction = root.anyOf.find((branch) => branch.properties.operation.enum?.[0] === "correct");
  const query = root.anyOf.find((branch) => branch.properties.operation.enum?.[0] === "query");
  assert(correction && query);
  equal(correction.properties.remove.type, "boolean");
  equal(correction.properties.selector.type, "object");
  equal(correction.properties.changes.type, "object");
  equal(correction.properties.actions.type, "null");
  equal(correction.properties.query.type, "null");
  equal(query.properties.query.type, "object");
  equal(query.properties.remove.type, "null");
});
Deno.test("wrapped correction output creates only a proposal with the stated before and after", () => {
  const text = "Change Victoria’s last feed from eighty mil to ninety mil";
  const raw = correction(text, {
    selector: selector({ expected_volume_ml: 80 }),
    changes: changes({ correction_kind: "total", amount_ml: 90 }),
  });
  const result = run({ interpretation: raw }, text);
  assert("operation" in result);
  equal(result.operation, "correct");
  equal((result.payload.selector as Record<string, unknown>).expected_volume_ml, 80);
  equal((result.payload.changes as Record<string, unknown>).amount_ml, 90);
  equal(result.payload.remove, false);
});
Deno.test("neutral correction defaults do not surface an internal interpretation error", () => {
  const text = "Change Victoria’s last feed from eighty mil to ninety mil";
  const raw = correction(text, {
    actions: [],
    remove: null,
    selector: selector({ expected_volume_ml: 80 }),
    changes: changes({ correction_kind: "total", amount_ml: 90 }),
  });
  const result = run(raw, text);
  assert("operation" in result);
  equal(result.operation, "correct");
  equal(result.payload.remove, false);
});
Deno.test("malformed interpretations use a helpful unsaved response instead of an internal type label", () => {
  try {
    run({ interpretation: { unexpected: true } }, "Change Victoria’s last feeding to ninety mil");
    throw new Error("Expected malformed extraction to be rejected");
  } catch (error) {
    assert(error instanceof Error);
    assert(!error.message.includes("Invalid conversation interpretation"));
    assert(error.message.includes("Nothing was recorded or changed"));
  }
});

Deno.test("neutral defaults never authorize deletion or discard a populated extra action", () => {
  const deletion = "Delete Victoria’s last feed";
  throws(() => run(correction(deletion, { remove: null, changes: changes() }), deletion));
  const text = "Change Victoria’s last feed from eighty mil to ninety mil";
  throws(() =>
    run(
      correction(text, {
        actions: [{ evidence: "Victoria drank eighty mil", extraction: extracted({ volume_ml: 80 }) }],
      }),
      text,
    )
  );
  throws(() => run({ interpretation: correction(text), unexpected: true }, text));
});

Deno.test("reported dashboard phrases map to their exact read-only metric", () => {
  for (
    const [text, kind] of [
      ["Has Victoria had a dirty diaper today?", "has_dirty"],
      ["How much has Victoria drunk today?", "milk_total"],
      ["When did Victoria fall asleep?", "last_sleep_start"],
      ["When did Victoria wake up?", "last_sleep_end"],
      ["Status report, Victoria", "care_report"],
      ["Care report, Victoria", "care_report"],
    ]
  ) {
    const result = run(question(text, kind), text);
    assert("operation" in result, text);
    equal(result.operation, "query");
    equal(result.payload, { kind, day: kind.startsWith("last_") ? null : "2026-11-13" });
  }
});

Deno.test("direct queries never discard events, assume a baby or reinterpret a negation", () => {
  for (
    const text of [
      "Has Victoria had a dirty diaper today and log 80 mil?",
      "Victoria did not drink 120 mil",
      "If Victoria wakes up, log it",
      "Care report, Victoria and log a wet diaper",
      "Status report, Oliver and Victoria",
    ]
  ) {
    equal(knownCareQuery(babies, parse({ ...command, text }, now), now), undefined);
  }
  const text = "When did she wake up?";
  const result = knownCareQuery(babies, parse({ ...command, text }, now), now);
  assert(result && "status" in result);
  equal(result.status, "needs_clarification");
  const yesterday = "Has Victoria had a dirty diaper yesterday?";
  const query = knownCareQuery(babies, parse({ ...command, text: yesterday }, now), now);
  assert(query && "operation" in query);
  equal(query.payload, { kind: "has_dirty", day: "2026-11-12" });
});

Deno.test("report extraction cannot discard a requested write or pretend a plan is a question", () => {
  for (const text of ["Care report, Victoria and log a wet diaper", "Status report, Victoria then record 80 mil"]) {
    clarification(question(text, "care_report"), text);
  }
});
