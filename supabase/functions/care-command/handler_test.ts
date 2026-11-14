import { createHandler, hash } from "./handler.ts";
import { parse } from "./domain.ts";
import { assert, babies, child, command, equal, extracted, now, parent } from "./test_helpers.ts";
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
          content: options.refusal
            ? [{ type: "refusal" }]
            : [{ type: "output_text", text: JSON.stringify(options.model ?? extracted()) }],
        }],
      });
    }
    if (url.endsWith("execute_care_command")) {
      saved = JSON.parse(String(init?.body));
      return reply(
        options.rpcBody ?? (saved?.p_action === "propose_feeding"
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
  equal((s.saved()?.p_payload as Record<string, unknown>).volume_ml, 180);
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
  equal(s.saved()?.p_action, "propose_feeding");
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
    equal(flow.saved()?.p_action, confirmed ? "confirm" : "cancel");
    equal(flow.saved()?.p_payload, { proposal_id: proposal });
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
  assert(!s.calls.some((c) => c.includes("openai") || c.endsWith("execute_care_command")));
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
  equal(s.saved()?.p_action, "sleep_start");
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
  assert(!s.calls.some((c) => c.endsWith("execute_care_command")));
  assert(!s.saved());
});

Deno.test("date-only historical weight reaches persistence once with its measurement date", async () => {
  const text = "Victoria weighted 7.365 kg on August 21";
  const weight = extracted({
    action: "weight",
    volume_ml: null,
    weight_kg: 7.365,
    time_kind: "date",
    absolute_local: "2026-08-21",
  });
  const s = setup({ expectedText: text, model: weight });
  const r = await s.handler(request({ ...command, text }));
  equal(r.status, 200);
  equal((await r.json()).status, "recorded");
  equal(s.saved()?.p_child_id, child);
  equal(s.saved()?.p_action, "record");
  const payload = s.saved()?.p_payload as Record<string, unknown>;
  equal(payload.measurement_date, "2026-08-21");
  equal(payload.weight_kg, 7.365);
  equal(s.calls.filter((url) => url.endsWith("execute_care_command")).length, 1);

  const future = setup({ expectedText: text, model: { ...weight, absolute_local: "2026-11-14" } });
  const body = await (await future.handler(request({ ...command, text }))).json();
  equal(body.status, "rejected");
  equal(body.code, "future_event");
  assert(!future.saved());
});

Deno.test("unsupported weight values, lost dates and invented milestone words never reach persistence", async () => {
  const weightText = "Victoria weighed 7.365kg on Aug 21st";
  const weight = extracted({
    action: "weight",
    volume_ml: null,
    weight_kg: 7.365,
    time_kind: "date",
    absolute_local: "2026-08-21",
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
  equal((good.saved()?.p_payload as Record<string, unknown>).title, "First waved hello");
  equal((good.saved()?.p_payload as Record<string, unknown>).occurred_on, "2026-11-01");
});
