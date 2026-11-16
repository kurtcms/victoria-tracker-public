import { createHandler } from "./handler.ts";
import { assert, babies, child, command, equal, now, parent } from "./test_helpers.ts";
const config = { supabaseURL: "https://db.invalid", supabaseKey: "public-test", openAIKey: "", model: "unused" };
const record = "11111111-1111-4111-8111-111111111111";
async function run(
  text: string,
  extra: Record<string, unknown> = {},
  sleep: unknown[] = [],
  events: unknown[] = [{ id: record, event_type: "feeding", volume_ml: 80, occurred_at: "2026-11-13T18:00Z" }],
  roster = babies,
  snapshotResponse?: () => Response,
) {
  const calls: string[] = [];
  const fetcher: typeof fetch = async (input, init) => {
    const url = String(input);
    calls.push(url);
    const data = url.endsWith("/auth/v1/user")
      ? { id: parent }
      : url.includes("care_receipts?")
      ? []
      : url.includes("children?")
      ? roster
      : url.endsWith("rpc/read_care_snapshot")
      ? { complete: true, events, sleep, milestones: [] }
      : null;
    if (data === null) throw Error("Unexpected request " + url);
    if (url.endsWith("rpc/read_care_snapshot")) {
      equal(JSON.parse(String(init?.body)), { p_child_id: child, p_reference_at: command.reference_at });
      if (snapshotResponse) return snapshotResponse();
    }
    return new Response(JSON.stringify(data));
  };
  const response = await createHandler(config, { fetch: fetcher, now: () => now })(
    new Request(config.supabaseURL, {
      method: "POST",
      headers: { Authorization: "Bearer fake", "Content-Type": "application/json" },
      body: JSON.stringify({ ...command, text, ...extra }),
    }),
  );
  return { response, body: await response.json(), calls };
}
Deno.test("authenticated reads share interpretation calculation and formatting without writes or paid calls", async () => {
  for (
    const [text, words] of [
      ["How much has Victoria drunk today?", ["80", "millilitres"]],
      ["Has Victoria had a wet diaper today?", ["wet", "record"]],
      ["Victoria今日飲咗幾多奶？", ["80", "毫升"]],
      ["Is Victoria sleeping?", ["sleep"]],
    ] as const
  ) {
    const r = await run(text);
    equal(r.response.status, 200);
    equal(r.body.status, "answered");
    for (const w of words) assert(r.body.message.includes(w), r.body.message);
    assert(
      r.calls.every((u) => !u.includes("execute_care") && !u.includes("openai") && !u.includes("consume_event_budget")),
    );
  }
});
Deno.test("follow-up uses exact previous feeding; explicit today overrides prior record", async () => {
  const events = [{ id: record, event_type: "feeding", volume_ml: 80, occurred_at: "2026-11-13T18:00Z" }, {
    id: "22222222-2222-4222-8222-222222222222",
    event_type: "feeding",
    volume_ml: 90,
    occurred_at: "2026-11-13T19:00Z",
  }];
  const context = { child_id: child, domain: "feeding", record_id: record, at: "2026-11-13T19:59:00Z" };
  // Multiple profiles still require a literal profile name, even on follow-ups.
  const ambiguous = await run("How much did she drink?", { query_context: context }, [], events);
  equal(ambiguous.body.status, "needs_clarification");
  const follow = await run("How much did Victoria drink?", { query_context: context }, [], events);
  equal(follow.body.details.value, 80);
  const explicit = await run("How much did Victoria drink today?", { query_context: context }, [], events);
  equal(explicit.body.details.value, 170);
  const stale = await run(
    "How much did Victoria drink?",
    { query_context: { ...context, at: "2026-11-13T18:00Z" } },
    [],
    events,
  );
  equal(stale.body.details.value, 170);
});
Deno.test("sleep answers separate completed duration from elapsed open session and preserve stale uncertainty", async () => {
  const sleep = [{ id: record, started_at: "2026-11-13T10:00Z", ended_at: null }];
  const total = await run("How long has Victoria slept today?", {}, sleep);
  equal(total.body.details.completed_minutes, 0);
  equal(total.body.details.open_minutes, 600);
  assert(total.body.message.includes("unconfirmed"));
  const state = await run("Is Victoria sleeping?", {}, sleep);
  equal(state.body.details.evidence, "stale");
  assert(!state.body.message.includes("is sleeping"));
});
Deno.test("explicit ISO, abbreviated rolling and Cantonese windows override feeding context", async () => {
  const context = { child_id: child, domain: "feeding", record_id: record, at: "2026-11-13T19:59Z" };
  for (
    const text of [
      "How much milk has Victoria had 2026-11-12?",
      "How much milk has Victoria had in the past two hrs?",
      "Victoria過去兩個鐘飲咗幾多奶？",
    ]
  ) {
    const r = await run(text, { query_context: context });
    equal(r.body.status, "answered");
    assert(r.body.details.query.operation !== "latest", text);
    assert(!r.body.details.query.target_id, text);
  }
});
Deno.test("single-child pronoun follow-up binds exact record, unknown names clarify, explicit names override selection", async () => {
  const one = [babies[0]],
    events = [{ id: record, event_type: "feeding", volume_ml: 80, occurred_at: "2026-11-13T18:00Z" }, {
      id: "22222222-2222-4222-8222-222222222222",
      event_type: "feeding",
      volume_ml: 90,
      occurred_at: "2026-11-13T19:00Z",
    }];
  const first = await run("When did Victoria last eat?", {}, [], events, one);
  equal(first.body.query_context.record_id, events[1].id);
  assert(first.body.message.includes("12:00 PM"), first.body.message);
  const follow = await run(
    "How much did she drink?",
    { query_context: { ...first.body.query_context, record_id: record } },
    [],
    events,
    one,
  );
  equal(follow.body.details.value, 80);
  equal(follow.body.message, "80 millilitres.");
  for (const text of ["When did Oliver feed?", "How much milk has Oliver consumed today?"]) {
    const r = await run(text, {}, [], events, one);
    equal(r.body.status, "needs_clarification");
  }
  const explicit = await run("How much has Victoria drunk today?", { child_id: babies[1].id }, [], events);
  equal(explicit.body.child_id, child);
  equal(explicit.body.details.value, 170);
});
Deno.test("explicit presentation applies to recorded quantities without changing calculations", async () => {
  const r = await run("How much has Victoria drunk today?", {
    presentation: { milk: "oz", weight: "lb", surface: "spoken" },
  });
  equal(r.body.details.value, 80);
  assert(r.body.message.includes("US fluid ounces"), r.body.message);
  const requested = await run("How much milk has Victoria had in ounces today?");
  equal(requested.body.details.value, 80);
  assert(requested.body.message.includes("US fluid ounces"), requested.body.message);
});

// Generated by /ship coverage pass 1.
// Value: protects=malformed read metadata fails before retrieval or spending;
// fails_when=context or presentation validation accepts invalid wire fields;
// why_new=existing pipeline cases contain valid metadata only; seam=none;
// no_claim=real provider acceptance, hosted Auth or native transport (all fetches mocked).
Deno.test("malformed read context and preferences cannot read records, spend or write", async () => {
  const context = { child_id: child, domain: "feeding", record_id: record, at: command.reference_at };
  const presentation = { milk: "ml", weight: "kg", surface: "spoken" };
  const invalid: Record<string, unknown>[] = [
    { query_context: null },
    ...[
      { child_id: "unknown" },
      { domain: "medicine" },
      { record_id: "unknown" },
      { at: "not a timestamp" },
      { at: undefined },
      { extra: true },
    ].map((patch) => ({ query_context: { ...context, ...patch } })),
    { presentation: null },
    ...[
      { milk: "litres" },
      { weight: "grams" },
      { surface: "audio" },
      { surface: undefined },
      { extra: true },
    ].map((patch) => ({ presentation: { ...presentation, ...patch } })),
  ];
  for (const extra of invalid) {
    const r = await run("How much has Victoria drunk today?", extra);
    equal(r.response.status, extra.query_context === null || extra.presentation === null ? 400 : 422);
    assert(r.body.status !== "answered", JSON.stringify(extra));
    equal(r.calls, [config.supabaseURL + "/auth/v1/user"]);
  }
});

// Generated by /ship coverage pass 1.
// Value: protects=unreliable read snapshots never become successful zero totals;
// fails_when=RPC errors, malformed JSON or incomplete arrays yield answered facts;
// why_new=all previous snapshot responses are complete successful fixtures; seam=none;
// no_claim=hosted database/gateway connectivity (synthetic injected fetch responses).
Deno.test("unavailable or incomplete snapshots fail without answered totals or mutation fallback", async () => {
  const complete = { complete: true, events: [], sleep: [], milestones: [] };
  const responses = [
    () => new Response(JSON.stringify({ message: "database unavailable" }), { status: 500 }),
    () => new Response("not JSON"),
    ...[
      { ...complete, complete: false },
      { ...complete, events: null },
      { ...complete, sleep: {} },
      { ...complete, milestones: undefined },
    ].map((snapshot) => () => new Response(JSON.stringify(snapshot))),
  ];
  for (const snapshotResponse of responses) {
    const r = await run("How much has Victoria drunk today?", {}, [], [], babies, snapshotResponse);
    equal(r.response.status, 503);
    equal(r.body.code, "query_unavailable");
    assert(r.body.status !== "answered");
    assert(!("details" in r.body));
    equal(r.calls.filter((u) => u.endsWith("rpc/read_care_snapshot")).length, 1);
    assert(r.calls.every((u) => !/execute_care|consume_event_budget|openai/.test(u)));
  }
});

// Generated by /ship coverage pass 1.
// Value: protects=one last-feeding question can request both time and amount;
// fails_when=joined attribute wording clarifies or loses either recorded field;
// why_new=existing latest-feed flow asks time alone then a separate amount follow-up; seam=none;
// no_claim=real provider NLU or Siri recognition (deterministic text route, mocked records).
Deno.test("joined last-feeding time and amount questions return both recorded attributes", async () => {
  for (const text of [
    "When and how much was Victoria’s last feeding?",
    "How much and when was Victoria’s last feeding?",
  ]) {
    const r = await run(text);
    equal(r.response.status, 200);
    equal(r.body.status, "answered");
    assert(r.body.message.includes("80 millilitres"), r.body.message);
    assert(r.body.message.includes("11:00 AM"), r.body.message);
    equal(r.body.query_context.record_id, record);
    assert(r.calls.every((u) => !/execute_care|consume_event_budget|openai/.test(u)));
  }
});

// Generated by /ship coverage pass 1.
// Value: protects=native uppercase UUID context selects the exact prior feed;
// fails_when=UUID case mismatch drops child context or fails record selection;
// why_new=existing context tests use lowercase child and all-numeric record UUIDs; seam=none;
// no_claim=physical Swift transport or provider NLU (native-shaped JSON with mocked records).
Deno.test("native uppercase child and record UUIDs retain exact feeding context", async () => {
  const older = "abcdefab-cdef-4abc-8def-abcdefabcdef";
  const events = [
    { id: older, event_type: "feeding", volume_ml: 80, occurred_at: "2026-11-13T18:00Z" },
    { id: record, event_type: "feeding", volume_ml: 90, occurred_at: "2026-11-13T19:00Z" },
  ];
  const r = await run("How much did Victoria drink?", {
    child_id: child.toUpperCase(),
    query_context: {
      child_id: child.toUpperCase(),
      domain: "feeding",
      record_id: older.toUpperCase(),
      at: "2026-11-13T19:59:00Z",
    },
  }, [], events);
  equal(r.response.status, 200);
  equal(r.body.status, "answered");
  equal(r.body.details.value, 80);
  equal(r.body.message, "80 millilitres.");
  equal(r.body.query_context.record_id, older);
  assert(r.calls.every((u) => !/execute_care|consume_event_budget|openai/.test(u)));
});
