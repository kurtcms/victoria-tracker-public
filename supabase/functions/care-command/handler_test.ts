import { createHandler, hash } from "./handler.ts";
import { parse } from "./domain.ts";
import { assert, babies, child, command, equal, extracted, now, parent } from "./test_helpers.ts";
// Provider fixtures use the same strict conversation envelope as production.
function providerEnvelope(raw: Record<string, unknown>, text: string): unknown {
  return "interpretation" in raw ? raw : { interpretation: innerProviderEnvelope(raw, text) };
}
function innerProviderEnvelope(raw: Record<string, unknown>, text: string): unknown {
  if (!["record", "reject", "clarify"].includes(String(raw.decision))) return raw;
  const base = {
    decision: raw.decision === "record" ? "execute" : raw.decision,
    child_name: raw.child_name ?? null,
    language: "en",
    evidence: text,
    operation: null,
    actions: null,
    selector: null,
    changes: null,
    remove: null,
    query: null,
  };
  if (raw.decision !== "record") return base;
  if (raw.action === "feeding_correction") {
    return {
      ...base,
      operation: "correct",
      selector: { kind: "feeding", diaper_kind: null, title: null, expected_volume_ml: null },
      remove: false,
      changes: {
        correction_kind: raw.correction_kind,
        amount_ml: raw.correction_ml,
        diaper_kind: null,
        weight_kg: null,
        measurement_date: null,
        occurred_at: null,
        ended_at: null,
        title: null,
        note: null,
        occurred_on: null,
        date_precision: null,
      },
    };
  }
  return { ...base, operation: "batch", actions: [{ evidence: text, extraction: raw }] };
}
const proposal = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const event = "ffffffff-ffff-4fff-8fff-ffffffffffff";
const config = {
  supabaseURL: "https://project.supabase.co",
  supabaseKey: "public-test",
  openAIKey: "fake-key",
  model: "gpt-4.1-mini",
};
function setup(
  options: {
    auth?: number;
    anonymous?: boolean;
    roster?: typeof babies;
    prior?: unknown;
    model?: unknown;
    providerFailure?: boolean;
    rpcStatus?: number;
    rpcBody?: unknown;
    refusal?: boolean;
    expectedText?: string;
  } = {},
) {
  const calls: string[] = [];
  let saved: Record<string, unknown> | undefined;
  const fetcher: typeof fetch = async (input, init) => {
    const url = String(input);
    calls.push(url);
    equal(init?.redirect, "error");
    const headers = new Headers(init?.headers);
    if (url.startsWith(config.supabaseURL)) {
      equal(headers.get("Authorization"), "Bearer user-token");
      equal(headers.get("apikey"), config.supabaseKey);
      assert(!String(init?.body ?? "").includes(config.openAIKey));
    }
    const reply = (v: unknown, status = 200) => new Response(JSON.stringify(v), { status });
    if (url.endsWith("/auth/v1/user")) {
      return reply({ id: parent, is_anonymous: options.anonymous ?? false }, options.auth ?? 200);
    }
    if (url.includes("care_receipts?")) return reply(options.prior ? [options.prior] : []);
    if (url.includes("children?")) return reply(options.roster ?? babies);
    if (url.endsWith("consume_event_budget")) return reply(true);
    if (url === "https://api.openai.com/v1/responses") {
      const body = JSON.parse(String(init?.body));
      equal(body.store, false);
      equal(body.text.format.strict, true);
      assert(!("tools" in body));
      equal(body.input[1].content, options.expectedText ?? command.text);
      if (options.providerFailure) throw Error("Private provider detail");
      return reply({
        status: "completed",
        output: [{
          type: "message",
          content: options.refusal ? [{ type: "refusal" }] : [{
            type: "output_text",
            text: JSON.stringify(
              providerEnvelope(
                (options.model ?? extracted()) as Record<string, unknown>,
                options.expectedText ?? command.text,
              ),
            ),
          }],
        }],
      });
    }
    if (url.endsWith("execute_care_conversation")) {
      saved = JSON.parse(String(init?.body));
      return reply(
        options.rpcBody ?? (saved?.p_operation === "correct"
          ? {
            status: "needs_confirmation",
            message: "Change from 200 to 180 mL?",
            proposal_id: proposal,
            child_id: child,
          }
          : { status: "recorded", message: "Recorded.", event_id: event, child_id: child }),
        options.rpcStatus ?? 200,
      );
    }
    throw Error("Unexpected fake request");
  };
  return { handler: createHandler(config, { fetch: fetcher, now: () => now }), calls, saved: () => saved };
}
const request = (body: unknown = command, token = "Bearer user-token") =>
  new Request("https://project.supabase.co/functions/v1/care-command", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: token },
    body: JSON.stringify(body),
  });
Deno.test("missing/invalid/anonymous auth cannot read family data, spend tokens or write", async () => {
  for (const token of ["", "invalid"]) {
    const s = setup();
    equal((await s.handler(request(command, token))).status, 401);
    equal(s.calls.length, 0);
  }
  for (const option of [{ auth: 401 }, { auth: 500 }, { anonymous: true }]) {
    const s = setup(option);
    assert((await s.handler(request())).status >= 400);
    equal(s.calls.length, 1);
  }
});
Deno.test("missing multi-baby name asks instead of assuming the dashboard child", async () => {
  const s = setup({ model: extracted({ child_name: null }), expectedText: "She drank 180 millilitres." });
  const r = await s.handler(request({ ...command, child_id: child, text: "She drank 180 millilitres." }));
  equal(r.status, 200);
  equal((await r.json()).status, "needs_clarification");
  assert(!s.saved());
});
Deno.test("explicit baby and real amount reach the authenticated recording RPC", async () => {
  const s = setup();
  const r = await s.handler(request());
  equal(r.status, 200);
  equal((await r.json()).status, "recorded");
  equal(s.saved()?.p_child_id, child);
  equal(
    (s.saved()?.p_payload as { actions: { payload: Record<string, unknown> }[] }).actions[0].payload.volume_ml,
    180,
  );
  assert(!("p_recorded_by" in s.saved()!));
});
Deno.test("leftover speech produces only a proposal; explicit separate confirmation commits it", async () => {
  const text = "Victoria left 20 millilitres from her last bottle.";
  const s = setup({
    expectedText: text,
    model: extracted({
      action: "feeding_correction",
      volume_ml: null,
      time_kind: null,
      correction_kind: "leftover",
      correction_ml: 20,
    }),
  });
  const r = await s.handler(request({ ...command, text }));
  equal((await r.json()).status, "needs_confirmation");
  equal(s.saved()?.p_operation, "correct");
  for (const confirmed of [false, true]) {
    const flow = setup();
    const body = {
      request_id: command.request_id,
      reference_at: command.reference_at,
      time_zone: command.time_zone,
      utc_offset_seconds: command.utc_offset_seconds,
      zone_offsets: command.zone_offsets,
      mode: "confirm",
      source: "siri",
      child_id: child.toUpperCase(),
      proposal_id: proposal,
      confirmed,
    };
    await flow.handler(request(body));
    equal(flow.saved()?.p_operation, "action");
    equal((flow.saved()?.p_payload as Record<string, unknown>).action, confirmed ? "confirm" : "cancel");
    equal((flow.saved()?.p_payload as Record<string, unknown>).payload, { proposal_id: proposal });
    assert(!flow.calls.some((c) => c.includes("openai")));
  }
});
Deno.test("receipt replay avoids extraction and conflicting request bodies cannot reuse its ID", async () => {
  const prior = {
    request_hash: await hash(parse(command, now)),
    response: { status: "recorded", message: "Recorded.", event_id: event, child_id: child },
  };
  const s = setup({ prior });
  equal((await s.handler(request())).status, 200);
  assert(!s.calls.some((c) => c.includes("openai") || c.endsWith("execute_care_conversation")));
  const replay = setup({ prior });
  const body = await (await replay.handler(request())).json();
  equal(body.replayed, true);
  assert(body.message.includes("later corrections"));
  const conflict = setup({ prior });
  equal((await conflict.handler(request({ ...command, text: "Changed" }))).status, 409);
  equal(await hash({ a: 1, b: { y: 2, x: 1 } }), await hash({ b: { x: 1, y: 2 }, a: 1 }));
});
Deno.test("unrelated child is rejected before paid extraction; model refusals/failures never write", async () => {
  const invisible = setup();
  equal((await invisible.handler(request({ ...command, child_id: event }))).status, 404);
  assert(!invisible.calls.some((c) => c.includes("openai")));
  for (const option of [{ providerFailure: true }, { refusal: true }, { model: { invalid: true } }]) {
    const s = setup(option);
    const r = await s.handler(request());
    equal(r.status, 200);
    const body = await r.json();
    assert(body.status !== "recorded");
    assert(!s.saved());
    assert(!JSON.stringify(body).includes("Private provider"));
  }
});
Deno.test("persistence uncertainty is never relabelled as nothing recorded", async () => {
  const s = setup({ rpcStatus: 503, rpcBody: { private: config.openAIKey } });
  const r = await s.handler(request());
  equal(r.status, 503);
  const body = await r.json();
  equal(body.code, "persistence_unconfirmed");
  assert(!body.message.includes("Nothing was recorded"));
  assert(!JSON.stringify(body).includes(config.openAIKey));
});
Deno.test("manual sleep avoids OpenAI; invalid manual future and extra confirmation fields cannot write", async () => {
  const base = {
    request_id: command.request_id,
    reference_at: command.reference_at,
    time_zone: command.time_zone,
    utc_offset_seconds: command.utc_offset_seconds,
    zone_offsets: command.zone_offsets,
    source: "manual",
    mode: "action",
    child_id: child,
    action: "sleep_start",
    payload: { occurred_at: now.toISOString() },
  };
  const s = setup();
  equal((await s.handler(request(base))).status, 200);
  equal((s.saved()?.p_payload as Record<string, unknown>).action, "sleep_start");
  assert(!s.calls.some((c) => c.includes("openai")));
  for (
    const body of [{ ...base, payload: { occurred_at: "2026-11-13T20:01:00Z" } }, {
      ...base,
      mode: "confirm",
      proposal_id: proposal,
      confirmed: true,
    }]
  ) {
    const s = setup();
    assert((await s.handler(request(body))).status >= 400);
    assert(!s.saved());
  }
});

Deno.test("20 mL speech with a model-generated 200 mL leftover never reaches the database RPC", async () => {
  const text = "Victoria left 20 millilitres from her last bottle.";
  const s = setup({
    expectedText: text,
    model: extracted({
      action: "feeding_correction",
      volume_ml: null,
      time_kind: null,
      correction_kind: "leftover",
      correction_ml: 200,
    }),
  });
  const response = await s.handler(request({ ...command, text }));
  equal(response.status, 200);
  equal((await response.json()).status, "needs_clarification");
  assert(!s.calls.some((c) => c.endsWith("execute_care_conversation")));
  assert(!s.saved());
});

Deno.test("date-only historical weight reaches persistence once with its measurement date", async () => {
  const text = "Victoria weighted 6.125 kg on August 9";
  const weight = extracted({
    action: "weight",
    volume_ml: null,
    weight_kg: 6.125,
    time_kind: "date",
    absolute_local: "2026-08-09",
  });
  const s = setup({ expectedText: text, model: weight });
  const r = await s.handler(request({ ...command, text }));
  equal(r.status, 200);
  equal((await r.json()).status, "recorded");
  equal(s.saved()?.p_child_id, child);
  equal(s.saved()?.p_operation, "batch");
  const payload = (s.saved()?.p_payload as { actions: { payload: Record<string, unknown> }[] }).actions[0].payload;
  equal(payload.measurement_date, "2026-08-09");
  equal(payload.weight_kg, 6.125);
  equal(s.calls.filter((url) => url.endsWith("execute_care_conversation")).length, 1);

  const mismatched = setup({ expectedText: text, model: { ...weight, absolute_local: "2026-11-14" } });
  equal((await (await mismatched.handler(request({ ...command, text }))).json()).status, "needs_clarification");
  assert(!mismatched.saved());
  const futureText = "Victoria weighed 6.125 kg on November 14";
  const future = setup({ expectedText: futureText, model: { ...weight, absolute_local: "2026-11-14" } });
  const body = await (await future.handler(request({ ...command, text: futureText }))).json();
  equal(body.status, "rejected");
  equal(body.code, "future_event");
  assert(!future.saved());
});

Deno.test("unsupported weight values, lost dates and invented milestone words never reach persistence", async () => {
  const weightText = "Victoria weighed 6.125kg on Aug 9th";
  const weight = extracted({
    action: "weight",
    volume_ml: null,
    weight_kg: 6.125,
    time_kind: "date",
    absolute_local: "2026-08-09",
  });
  for (
    const model of [
      { ...weight, weight_kg: 6.35 },
      { ...weight, time_kind: "now", absolute_local: null },
    ]
  ) {
    const s = setup({ expectedText: weightText, model });
    const response = await s.handler(request({ ...command, text: weightText }));
    equal((await response.json()).status, "needs_clarification");
    assert(!s.saved());
  }
  const text = "Victoria first waved hello on Nov 1st";
  const milestone = extracted({
    action: "milestone",
    volume_ml: null,
    time_kind: null,
    title: "First waved hello",
    occurred_on: "2026-11-01",
    date_precision: "day",
    is_first: true,
  });
  for (
    const model of [
      { ...milestone, title: "First bicycle" },
      { ...milestone, occurred_on: "2026-11-13" },
    ]
  ) {
    const s = setup({ expectedText: text, model });
    equal((await (await s.handler(request({ ...command, text }))).json()).status, "needs_clarification");
    assert(!s.saved());
  }
  const good = setup({ expectedText: text, model: milestone });
  equal((await (await good.handler(request({ ...command, text }))).json()).status, "recorded");
  equal(
    (good.saved()?.p_payload as { actions: { payload: Record<string, unknown> }[] }).actions[0].payload.title,
    "First waved hello",
  );
  equal(
    (good.saved()?.p_payload as { actions: { payload: Record<string, unknown> }[] }).actions[0].payload.occurred_on,
    "2026-11-01",
  );
});

Deno.test("dashboard questions return database answers without claiming a persisted event", async () => {
  const text = "How much has Victoria drunk today?";
  const model = {
    decision: "execute",
    child_name: "Victoria",
    language: "en",
    evidence: text,
    operation: "query",
    actions: null,
    selector: null,
    changes: null,
    remove: null,
    query: { kind: "milk_total", day: "2026-11-13" },
  };
  const s = setup({
    model,
    expectedText: text,
    rpcBody: {
      status: "answered",
      child_id: child,
      message: "Victoria has 240 millilitres recorded today.",
      details: {
        kind: "answer",
        query_kind: "day_summary",
        child_name: "Victoria",
        day: "2026-11-13",
        has_records: true,
        feeding_ml: 240,
        feeding_count: 2,
        wet_count: 3,
        dirty_count: 1,
        sleep_minutes: 120,
      },
    },
  });
  const response = await s.handler(request({ ...command, text }));
  equal(response.status, 200);
  const result = await response.json();
  equal(result.status, "answered");
  assert(!("event_id" in result));
  equal(s.saved()?.p_operation, "query");
  equal(s.calls.filter((c) => c.endsWith("execute_care_conversation")).length, 1);
});
Deno.test("confirmation language is validated and forwarded without paid extraction", async () => {
  const body = {
    ...command,
    mode: "confirm",
    text: undefined,
    child_id: child,
    proposal_id: proposal,
    confirmed: true,
    language: "yue",
  };
  const s = setup();
  equal((await s.handler(request(body))).status, 200);
  equal(s.saved()?.p_language, "yue");
  assert(!s.calls.some((c) => c.includes("openai")));
  equal((await setup().handler(request({ ...body, language: "arbitrary" }))).status, 422);
});

Deno.test("valid milk and diaper clauses with default first flags persist through one batch RPC", async () => {
  const text = "Victoria drank eighty mil and had a wet diaper";
  const model = {
    decision: "execute",
    operation: "batch",
    child_name: "Victoria",
    language: "en",
    evidence: text,
    actions: [
      { evidence: "Victoria drank eighty mil", extraction: extracted({ volume_ml: 80, is_first: false }) },
      {
        evidence: "had a wet diaper",
        extraction: extracted({ action: "diaper", volume_ml: null, diaper_kind: "wet", is_first: false }),
      },
    ],
    selector: null,
    changes: null,
    remove: null,
    query: null,
  };
  const secondEvent = "11111111-1111-4111-8111-111111111111";
  const s = setup({
    model,
    expectedText: text,
    rpcBody: {
      status: "recorded",
      message: "Recorded 2 events for Victoria.",
      event_id: event,
      event_ids: [event, secondEvent],
      child_id: child,
    },
  });
  const r = await s.handler(request({ ...command, text }));
  equal(r.status, 200);
  const result = await r.json();
  equal(result.status, "recorded");
  equal(result.event_ids, [event, secondEvent]);
  equal(s.saved()?.p_operation, "batch");
  const payload = s.saved()?.p_payload as { actions: { payload: Record<string, unknown> }[] };
  equal(payload.actions.length, 2);
  equal(payload.actions[0].payload.volume_ml, 80);
  equal(payload.actions[1].payload.diaper_kind, "wet");
  equal(s.calls.filter((url) => url.endsWith("execute_care_conversation")).length, 1);
});

Deno.test("wrapped from/to correction requests a proposal with exact amounts and never confirms it", async () => {
  const text = "Change Victoria’s last feed from eighty mil to ninety mil";
  const s = setup({
    expectedText: text,
    model: {
      interpretation: {
        decision: "execute",
        operation: "correct",
        child_name: "Victoria",
        language: "en",
        evidence: text,
        actions: null,
        query: null,
        remove: false,
        selector: { kind: "feeding", diaper_kind: null, title: null, expected_volume_ml: 80 },
        changes: {
          correction_kind: "total",
          amount_ml: 90,
          diaper_kind: null,
          weight_kg: null,
          measurement_date: null,
          occurred_at: null,
          ended_at: null,
          title: null,
          note: null,
          occurred_on: null,
          date_precision: null,
        },
      },
    },
  });
  const r = await s.handler(request({ ...command, text }));
  equal(r.status, 200);
  equal((await r.json()).status, "needs_confirmation");
  equal(s.saved()?.p_operation, "correct");
  equal(s.saved()?.p_payload, {
    selector: { kind: "feeding", expected_volume_ml: 80 },
    changes: { correction_kind: "total", amount_ml: 90 },
    remove: false,
  });
  equal(s.calls.filter((c) => c.endsWith("execute_care_conversation")).length, 1);
});

Deno.test("common dashboard questions bypass model interpretation and remain authenticated read-only", async () => {
  for (
    const [text, kind] of [
      ["Has Victoria had a dirty diaper today?", "has_dirty"],
      ["How much has Victoria drunk today?", "day_summary"],
      ["When did Victoria fall asleep?", "last_sleep_start"],
      ["When did Victoria wake up?", "last_sleep_end"],
      ["Status report, Victoria", "care_report"],
      ["Care report, Victoria", "care_report"],
    ]
  ) {
    const s = setup({
      expectedText: text,
      providerFailure: true,
      rpcBody: {
        status: "answered",
        child_id: child,
        message: "Stored facts",
        details: {
          kind: "answer",
          query_kind: kind,
          child_name: "Victoria",
          day: "2026-11-13",
          has_records: true,
          feeding_ml: 150,
        },
      },
    });
    const r = await s.handler(request({ ...command, text }));
    equal((await r.json()).status, "answered");
    equal(s.saved()?.p_operation, "query");
    equal((s.saved()?.p_payload as Record<string, unknown>).kind, kind);
    assert(!s.calls.some((c) => c.includes("openai") || c.endsWith("consume_event_budget")));
    assert(s.calls.some((c) => c.endsWith("/auth/v1/user")));
  }
});

Deno.test("milk-only question returns only the stored milk total without trailing zeroes", async () => {
  const text = "How much has Victoria drunk today?";
  const s = setup({
    expectedText: text,
    providerFailure: true,
    rpcBody: {
      status: "answered",
      child_id: child,
      message: "Full summary: 150.00 milk, 2 wet, 1 dirty, 90 sleep",
      details: {
        kind: "answer",
        query_kind: "day_summary",
        child_name: "Victoria",
        day: "2026-11-13",
        has_records: true,
        feeding_ml: 150,
        wet_count: 2,
        dirty_count: 1,
        sleep_minutes: 90,
      },
    },
  });
  const result = await (await s.handler(request({ ...command, text }))).json();
  equal(result.status, "answered");
  equal(result.message, "Victoria has drunk 150 millilitres today.");
  equal(result.details.query_kind, "milk_total");
  equal(s.saved()?.p_operation, "query");
  equal((s.saved()?.p_payload as Record<string, unknown>).kind, "day_summary");
  assert(!s.calls.some((c) => c.includes("openai")));
});
