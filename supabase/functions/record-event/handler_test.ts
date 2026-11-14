import { commandHash, createHandler } from "./handler.ts";
import { clarificationMessage, futureEventMessage, interpretationUnavailableMessage, parseCommand, unsupportedEventMessage } from "./domain.ts";
import { assert, command, equal, extraction, now } from "./test_helpers.ts";

const config = {
  supabaseURL: "https://project.supabase.co",
  supabaseKey: "public-test-key",
  openAIKey: "fake-test-key",
  model: "gpt-4.1-mini",
};
const userID = "33333333-3333-4333-8333-333333333333";
const response = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status });
function setup(
  options: {
    unauthorized?: boolean;
    authStatus?: number;
    authUser?: unknown;
    invisible?: boolean;
    budget?: boolean;
    existing?: unknown;
    saveFailure?: boolean;
    extraction?: unknown;
    refusal?: boolean;
    incomplete?: boolean;
    providerResponse?: unknown;
    providerStatus?: number;
    providerFailure?: boolean;
    expectedText?: string;
  } = {},
) {
  const calls: string[] = [];
  let savedBody: Record<string, unknown> | undefined;
  let extractionInput: string | undefined;
  const fakeFetch: typeof fetch = (input, init) => {
    const url = String(input);
    calls.push(url);
    equal(init?.redirect, "error");
    const sentHeaders = new Headers(init?.headers);
    if (url.startsWith(config.supabaseURL)) {
      equal(sentHeaders.get("apikey"), config.supabaseKey);
      equal(sentHeaders.get("Authorization"), "Bearer test-user-jwt");
      assert(!String(init?.body ?? "").includes(config.openAIKey));
    }
    if (url.includes("/auth/v1/user")) {
      return Promise.resolve(
        response(options.authUser ?? { id: userID }, options.authStatus ?? (options.unauthorized ? 401 : 200)),
      );
    }
    if (url.includes("/children?")) {
      return Promise.resolve(
        response(options.invisible ? [] : [{ id: command.child_id, name: "Victoria", time_zone: "America/Vancouver" }]),
      );
    }
    if (url.includes("/events?")) return Promise.resolve(response(options.existing ? [options.existing] : []));
    if (url.endsWith("consume_event_budget")) return Promise.resolve(response(options.budget ?? true));
    if (url === "https://api.openai.com/v1/responses") {
      const body = JSON.parse(String(init?.body));
      extractionInput = body.input[0].content;
      if (options.expectedText !== undefined) equal(body.input[1].content, options.expectedText);
      equal(body.store, false);
      equal(body.text.format.strict, true);
      equal(body.model, config.model);
      assert(!("tools" in body));
      if (options.providerFailure) return Promise.reject(new Error("Private provider diagnostic"));
      return Promise.resolve(
        response("providerResponse" in options ? options.providerResponse : {
          status: options.incomplete ? "incomplete" : "completed",
          output: [{
            type: "message",
            content: options.refusal
              ? [{ type: "refusal" }]
              : [{ type: "output_text", text: JSON.stringify(options.extraction ?? extraction()) }],
          }],
        }, options.providerStatus ?? 200),
      );
    }
    if (url.endsWith("rpc/record_event")) {
      savedBody = JSON.parse(String(init?.body));
      if (options.saveFailure) return Promise.resolve(response({ code: "XX000" }, 500));
      return Promise.resolve(
        response({
          id: "44444444-4444-4444-8444-444444444444",
          child_id: savedBody!.p_child_id,
          request_id: savedBody!.p_request_id,
          event_type: savedBody!.p_event_type,
          occurred_at: savedBody!.p_occurred_at,
          volume_ml: savedBody!.p_volume_ml,
          diaper_kind: savedBody!.p_diaper_kind,
          weight_kg: savedBody!.p_weight_kg,
          created_at: now.toISOString(),
          recorded_by: userID,
        }),
      );
    }
    throw new Error("Unexpected request: " + url);
  };
  return {
    handler: createHandler(config, { fetch: fakeFetch, now: () => now }),
    calls,
    saved: () => savedBody,
    prompt: () => extractionInput,
  };
}
function request(body: unknown = command, auth = "Bearer test-user-jwt") {
  return new Request("https://project.supabase.co/functions/v1/record-event", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: auth },
    body: JSON.stringify(body),
  });
}
Deno.test("handler confirms only after a successful database write", async () => {
  const s = setup();
  const r = await s.handler(request());
  const body = await r.json();
  equal(r.status, 200);
  equal(body.status, "recorded");
  equal(body.message, "Recorded 160 millilitres for Victoria.");
  assert(s.calls.at(-1)?.endsWith("rpc/record_event"));
  assert(!("p_recorded_by" in s.saved()!));
});
Deno.test("persistence failure never produces a success response", async () => {
  const s = setup({ saveFailure: true });
  const r = await s.handler(request());
  const body = await r.json();
  equal(r.status, 503);
  equal(body.code, "persistence_unconfirmed");
  equal(body.message, "Could not confirm recording. Retry the pending entry in the app.");
  assert(body.status !== "recorded");
  assert(!body.message.startsWith("Recorded"));
});
Deno.test("missing or invalid auth never calls AI or the database", async () => {
  for (const auth of ["", "not bearer"]) {
    const s = setup();
    equal((await s.handler(request(command, auth))).status, 401);
    equal(s.calls.length, 0);
  }
  const s = setup({ unauthorized: true });
  equal((await s.handler(request())).status, 401);
  equal(s.calls.length, 1);
});
Deno.test("unrelated family cannot spend AI tokens or write events", async () => {
  const s = setup({ invisible: true });
  equal((await s.handler(request())).status, 404);
  assert(!s.calls.some((c) => c.includes("openai") || c.includes("rpc/record_event")));
});
Deno.test("auth failure, missing identity, and anonymous sessions fail before database or AI access", async () => {
  for (
    const option of [{ authStatus: 401 }, { authStatus: 500 }, { authUser: {} }, { authUser: { id: "invalid" } }, {
      authUser: { id: userID, is_anonymous: true },
    }]
  ) {
    const s = setup(option);
    const result = await s.handler(request());
    assert(result.status >= 400);
    equal(s.calls.length, 1);
    assert(!s.saved());
  }
});
Deno.test("upstream secret-bearing errors are not returned to the caller", async () => {
  const s = setup({ authStatus: 500, authUser: { diagnostic: config.openAIKey } });
  const result = await s.handler(request());
  const text = await result.text();
  assert(!text.includes(config.openAIKey));
  assert(!text.includes("diagnostic"));
});
Deno.test("recorded request is returned before invoking AI again", async () => {
  const hash = await commandHash(parseCommand(command, now));
  const s = setup({
    existing: { id: "event", child_id: command.child_id, request_hash: hash, event_type: "feeding", volume_ml: 160 },
  });
  const r = await s.handler(request());
  const body = await r.json();
  equal(body.replayed, true);
  assert(!s.calls.some((c) => c.includes("openai") || c.includes("rpc/record_event")));
});
Deno.test("reuse of an idempotency key with changed text returns conflict", async () => {
  const hash = await commandHash(parseCommand(command, now));
  const s = setup({ existing: { child_id: command.child_id, request_hash: hash } });
  equal((await s.handler(request({ ...command, text: "Log 120 mL for Victoria." }))).status, 409);
});
Deno.test("clarification and rejected interpretations never reach persistence", async () => {
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
  for (const decision of ["clarify", "reject"]) {
    const s = setup({ extraction: extraction({ ...empty, decision, clarification: "Please clarify." }) });
    const result = await (await s.handler(request())).json();
    equal(result.status, decision === "clarify" ? "needs_clarification" : "rejected");
    assert(!s.saved());
  }
});
Deno.test("out-of-range model values, refusal and incomplete output never save", async () => {
  for (
    const options of [{ extraction: extraction({ volume_ml: -10 }) }, { refusal: true }, { incomplete: true }, {
      extraction: { invalid: true },
    }]
  ) {
    const s = setup(options);
    const r = await s.handler(request());
    const result = await r.json();
    assert(result.status !== "recorded");
    assert(!s.saved());
  }
});
Deno.test("manual fallback skips OpenAI and still uses the authenticated write path", async () => {
  const { text: _, ...base } = command;
  const s = setup();
  const r = await s.handler(request({
    ...base,
    mode: "manual",
    source: "manual",
    event: {
      event_type: "weight",
      occurred_at: now.toISOString(),
      volume_ml: null,
      diaper_kind: null,
      weight_kg: 7.5,
    },
  }));
  equal(r.status, 200);
  equal(s.saved()?.p_weight_kg, 7.5);
  assert(!s.calls.some((c) => c.includes("openai")));
});
Deno.test("rate limit blocks new model calls", async () => {
  const s = setup({ budget: false });
  equal((await s.handler(request())).status, 429);
  assert(!s.calls.some((c) => c.includes("openai")));
  assert(!s.saved());
});
Deno.test("oversized and malformed requests are rejected", async () => {
  const s = setup();
  equal((await s.handler(request({ ...command, text: "a".repeat(9000) }))).status, 413);
  equal(
    (await s.handler(
      new Request("https://example.com", {
        method: "POST",
        headers: { Authorization: "Bearer test-user-jwt", "Content-Type": "application/json" },
        body: "{bad json",
      }),
    )).status,
    400,
  );
});

Deno.test("phone timezone overrides the child zone; legacy requests retain their original context", async () => {
  const local = setup();
  equal((await local.handler(request({ ...command, time_zone: "Asia/Tokyo" }))).status, 200);
  assert(local.prompt()?.includes('Time zone: "Asia/Tokyo"'));
  assert(!local.prompt()?.includes("America/Vancouver"));
  const legacy = setup();
  equal((await legacy.handler(request())).status, 200);
  assert(legacy.prompt()?.includes('Time zone: "America/Vancouver"'));
});

Deno.test("invalid timezone stops before child access, budget consumption, extraction or insertion", async () => {
  const s = setup();
  equal((await s.handler(request({ ...command, time_zone: "invalid/zone" }))).status, 400);
  equal(s.calls.length, 1); // Auth only.
});

Deno.test("changing the captured timezone on a recorded retry returns conflict without extraction", async () => {
  const original = { ...command, time_zone: "Asia/Tokyo" };
  const hash = await commandHash(parseCommand(original, now));
  const s = setup({ existing: { child_id: command.child_id, request_hash: hash } });
  equal((await s.handler(request({ ...original, time_zone: "America/Vancouver" }))).status, 409);
  assert(!s.calls.some((c) => c.includes("openai") || c.includes("rpc/record_event")));
});

Deno.test("legacy idempotency hash is unchanged by the optional timezone rollout", async () => {
  equal(
    await commandHash(parseCommand(command, now)),
    "e36dac3eaac1dee80529c0d9a0d1ee5eaa22ff967a9108f25f9f52285f7eb819",
  );
  assert(
    await commandHash(parseCommand({ ...command, time_zone: "Asia/Tokyo" }, now)) !==
      await commandHash(parseCommand(command, now)),
  );
});

Deno.test("180 and 200 mL descriptions reach extraction unchanged and save their extracted amounts", async () => {
  for (const volume of [180, 200]) {
    const text = `She drank ${volume} millilitres.`;
    const s = setup({ extraction: extraction({ volume_ml: volume }), expectedText: text });
    const r = await s.handler(request({ ...command, text, time_zone: "America/Vancouver" }));
    equal(r.status, 200);
    const result = await r.json();
    equal(s.saved()?.p_volume_ml, volume);
    equal(result.event.volume_ml, volume);
    equal(result.message, `Recorded ${volume} millilitres for Victoria.`);
  }
});

Deno.test("future plans return a normal informative rejection instead of throwing or reprompting", async () => {
  for (
    const raw of [
      extraction({
        decision: "reject",
        clarification: "Future",
        child_name: null,
        event_type: null,
        volume_ml: null,
        diaper_kind: null,
        weight_kg: null,
        time_kind: "future",
      }),
      extraction({ volume_ml: 250, time_kind: "relative", minutes_ago: -5 }),
      extraction({ volume_ml: 250, time_kind: "absolute", absolute_utc: "2026-11-12T20:05:00.000Z" }),
    ]
  ) {
    const s = setup({ extraction: raw });
    const r = await s.handler(request({ ...command, text: "She drank 250 mL five minutes from now." }));
    equal(r.status, 200);
    const body = await r.json();
    equal(body.status, "rejected");
    equal(body.code, "future_event");
    equal(body.message, futureEventMessage);
    assert(!s.saved());
    assert(!s.calls.some((c) => c.includes("rpc/record_event")));
  }
});

Deno.test("unclear descriptions request the familiar complete-event clarification without writing", async () => {
  for (const text of ["blue banana spaceship", "She had some", "A diaper", "She slept well"]) {
    const s = setup({
      expectedText: text,
      extraction: extraction({
        decision: "clarify", clarification: "Recorded a guessed event!",
        child_name: null, event_type: null, volume_ml: null, diaper_kind: null,
        weight_kg: null, time_kind: null, minutes_ago: null, absolute_utc: null,
      }),
    });
    const r = await s.handler(request({ ...command, text }));
    equal(r.status, 200);
    equal(await r.json(), { status: "needs_clarification", message: clarificationMessage });
    assert(!s.calls.some((c) => c.endsWith("rpc/record_event")));
  }
});

Deno.test("interpretation failures return an informative unsaved dialog without exposing diagnostics", async () => {
  for (const options of [
    { incomplete: true },
    { extraction: { invalid: true } },
    { providerFailure: true },
    { providerStatus: 503, providerResponse: { diagnostic: config.openAIKey } },
    { providerResponse: null },
    { providerResponse: { status: "completed", output: [] } },
    { providerResponse: { status: "completed", output: [{ type: "message", content: null }] } },
    { providerResponse: { status: "completed", output: [{ type: "message", content: [{ type: "output_text", text: "not JSON" }] }] } },
  ]) {
    const s = setup(options);
    const r = await s.handler(request());
    equal(r.status, 200);
    equal(await r.json(), { status: "rejected", code: "interpretation_unavailable", message: interpretationUnavailableMessage });
    assert(!s.calls.some((c) => c.endsWith("rpc/record_event")));
    assert(!s.saved());
  }
});

Deno.test("refusals and non-event statements return informative normal rejections without writing", async () => {
  const refused = setup({ refusal: true });
  const r = await refused.handler(request());
  equal(r.status, 200);
  equal(await r.json(), { status: "rejected", code: "unsupported_event", message: unsupportedEventMessage });
  assert(!refused.saved());
  for (const text of ["Did she drink 180 mL?", "She did not drink 180 mL", "If she drank 180 mL"]) {
    const s = setup({ expectedText: text, extraction: extraction({
      decision: "reject", clarification: "Private model explanation",
      child_name: null, event_type: null, volume_ml: null, diaper_kind: null,
      weight_kg: null, time_kind: null, minutes_ago: null, absolute_utc: null,
    }) });
    const result = await s.handler(request({ ...command, text }));
    equal(result.status, 200);
    equal(await result.json(), { status: "rejected", message: unsupportedEventMessage });
    assert(!s.calls.some((c) => c.endsWith("rpc/record_event")));
  }
});
