import {
  APIError,
  Baby,
  interpret,
  interpretationUnavailableMessage,
  object,
  parse,
  prompt,
  schema,
  uuid,
  validateAction,
} from "./domain.ts";
// Do not log request text, family data, provider output or credentials.
type Config = { supabaseURL: string; supabaseKey: string; openAIKey: string; model: string };
type Dependencies = { fetch: typeof fetch; now: () => Date };
const json = (v: unknown, status = 200) =>
  new Response(JSON.stringify(v), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
function canonical(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(canonical);
  if (v && typeof v === "object") {
    return Object.fromEntries(
      Object.entries(v).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => [k, canonical(v)]),
    );
  }
  return v;
}
export async function hash(v: unknown): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(canonical(v))));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}
async function body(req: Request): Promise<unknown> {
  if (!req.headers.get("Content-Type")?.toLowerCase().startsWith("application/json")) {
    throw new APIError(415, "invalid_input", "Send JSON.");
  }
  const reader = req.body?.getReader();
  if (!reader) throw new APIError(400, "invalid_input", "A request body is required.");
  let size = 0;
  const chunks: Uint8Array[] = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > 8192) {
      await reader.cancel();
      throw new APIError(413, "too_large", "Request is too large.");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let i = 0;
  for (const c of chunks) {
    bytes.set(c, i);
    i += c.length;
  }
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new APIError(400, "invalid_input", "Invalid JSON.");
  }
}
export function createHandler(config: Config, deps: Dependencies = { fetch, now: () => new Date() }) {
  return async (req: Request): Promise<Response> => {
    try {
      if (req.method !== "POST") return json({ code: "method_not_allowed", message: "Use POST." }, 405);
      const authorization = req.headers.get("Authorization");
      if (!authorization || !/^Bearer \S+$/i.test(authorization)) {
        throw new APIError(401, "unauthorized", "Open Victoria Tracker and sign in first.");
      }
      if (!config.supabaseURL || !config.supabaseKey) throw Error("Configuration unavailable");
      const headers = { apikey: config.supabaseKey, Authorization: authorization, "Content-Type": "application/json" };
      const auth = await deps.fetch(config.supabaseURL + "/auth/v1/user", {
        headers,
        redirect: "error",
        signal: AbortSignal.timeout(8000),
      });
      if (auth.status >= 500) throw new APIError(503, "auth_unavailable", "Authentication is temporarily unavailable.");
      if (!auth.ok) throw new APIError(401, "unauthorized", "Open Victoria Tracker and sign in first.");
      const user = object(await auth.json());
      if (typeof user.id !== "string" || !uuid.test(user.id)) throw new APIError(401, "unauthorized", "Sign in again.");
      if (user.is_anonymous === true) throw new APIError(403, "anonymous_user", "Use your parent account.");
      const command = parse(await body(req), deps.now());
      const requestHash = await hash(command);
      const rest = (path: string, data?: unknown) =>
        deps.fetch(config.supabaseURL + "/rest/v1/" + path, {
          headers,
          redirect: "error",
          signal: AbortSignal.timeout(8000),
          method: data === undefined ? "GET" : "POST",
          ...(data === undefined ? {} : { body: JSON.stringify(data) }),
        });
      const prior = await rest(
        `care_receipts?recorded_by=eq.${user.id}&request_id=eq.${command.request_id}&select=request_hash,response&limit=1`,
      );
      if (!prior.ok) {
        throw new APIError(
          503,
          "database_unavailable",
          "Cannot check the previous attempt. Retry the pending entry in the app.",
        );
      }
      const receipts = await prior.json();
      if (!Array.isArray(receipts)) throw Error("Invalid receipt");
      if (receipts.length) {
        if (receipts[0].request_hash !== requestHash) {
          throw new APIError(409, "idempotency_conflict", "This identifier belongs to a different command.");
        }
        const replay = object(receipts[0].response);
        return json({
          ...replay,
          replayed: true,
          ...(replay.status === "recorded"
            ? {
              message:
                "This action was already saved. Nothing was recorded again. Check the app for any later corrections.",
            }
            : {}),
        });
      }
      const babies: Baby[] = [];
      for (let offset = 0;; offset += 500) {
        const r = await rest(`children?archived_at=is.null&select=id,name&order=id&limit=500&offset=${offset}`);
        if (!r.ok) throw new APIError(503, "database_unavailable", "Cannot check the family right now.");
        const page = await r.json();
        if (
          !Array.isArray(page) ||
          page.some((b) => typeof b.id !== "string" || !uuid.test(b.id) || typeof b.name !== "string")
        ) throw Error("Invalid roster");
        babies.push(...page);
        if (page.length < 500) break;
      }
      if (!babies.length) {
        return json({
          status: "rejected",
          message: "Open Victoria Tracker and add or join your family’s baby profile first.",
        });
      }
      if (command.child_id && !babies.some((b) => b.id === command.child_id)) {
        throw new APIError(404, "child_unavailable", "That baby is not available in your family.");
      }
      let action: string;
      let payload: Record<string, unknown>;
      let childID: string;
      if (command.mode === "confirm") {
        action = command.confirmed ? "confirm" : "cancel";
        payload = { proposal_id: command.proposal_id };
        childID = command.child_id!;
      } else if (command.mode === "action") {
        action = command.action!;
        payload = validateAction(action, command.payload, command, deps.now());
        childID = command.child_id!;
      } else {
        const budget = await rest("rpc/consume_event_budget", {});
        if (!budget.ok) throw new APIError(503, "database_unavailable", "Recording is temporarily unavailable.");
        if (await budget.json() !== true) {
          throw new APIError(429, "rate_limited", "Too many attempts. Wait one minute before retrying.");
        }
        const unavailable = () =>
          json({ status: "rejected", code: "interpretation_unavailable", message: interpretationUnavailableMessage });
        if (!config.openAIKey) return unavailable();
        let result;
        try {
          const r = await deps.fetch("https://api.openai.com/v1/responses", {
            method: "POST",
            redirect: "error",
            signal: AbortSignal.timeout(15000),
            headers: { Authorization: "Bearer " + config.openAIKey, "Content-Type": "application/json" },
            body: JSON.stringify({
              model: config.model || "gpt-4.1-mini",
              store: false,
              max_output_tokens: 1200,
              input: [{ role: "system", content: prompt(babies, command) }, { role: "user", content: command.text }],
              text: { format: { type: "json_schema", name: "baby_care_action", strict: true, schema } },
            }),
          });
          if (!r.ok) return unavailable();
          const data = object(await r.json());
          if (data.status !== "completed" || !Array.isArray(data.output)) return unavailable();
          const parts = data.output.map(object).filter((o) => o.type === "message").flatMap((o) => {
            if (!Array.isArray(o.content)) throw Error("Invalid content");
            return o.content.map(object);
          });
          if (parts.some((p) => p.type === "refusal")) {
            return json({
              status: "rejected",
              message: "Nothing was recorded. Please describe one baby-care event or correction.",
            });
          }
          const text = parts.filter((p) => p.type === "output_text");
          if (text.length !== 1 || typeof text[0].text !== "string") return unavailable();
          result = interpret(JSON.parse(text[0].text), babies, command, deps.now());
        } catch (e) {
          if (
            e instanceof APIError &&
            ["invalid_action", "future_event", "invalid_event", "invalid_time"].includes(e.code)
          ) {
            return json({
              status: e.code === "future_event" ? "rejected" : "needs_clarification",
              code: e.code,
              message: e.message,
            });
          }
          return unavailable();
        }
        if ("status" in result) return json(result);
        action = result.action;
        payload = result.payload;
        childID = result.child_id;
      }
      const r = await rest("rpc/execute_care_command", {
        p_child_id: childID,
        p_request_id: command.request_id,
        p_request_hash: requestHash,
        p_action: action,
        p_reference_at: command.reference_at,
        p_source: command.source,
        p_payload: payload,
        p_time_zone: command.time_zone,
        p_utc_offset_seconds: command.utc_offset_seconds,
        p_zone_offsets: command.zone_offsets,
      });
      if (!r.ok) {
        if (r.status < 500) {
          const err = object(await r.json());
          if (err.code === "23505") {
            throw new APIError(
              409,
              "idempotency_conflict",
              "This recording identifier conflicts. Check the pending entry.",
            );
          }
          if (err.code === "42501") {
            throw new APIError(404, "child_unavailable", "That record or confirmation is not accessible.");
          }
          if (["22023", "40001", "23514", "22P02", "22007", "22008", "22003"].includes(String(err.code))) {
            return json({
              status: "rejected",
              message: err.code === "22023" || err.code === "40001"
                ? String(err.message).slice(0, 400)
                : "Nothing changed. Check the values and dates, then try again.",
            });
          }
        }
        throw new APIError(
          503,
          "persistence_unconfirmed",
          "Could not confirm recording. Retry the pending entry in the app.",
        );
      }
      const result = object(await r.json());
      if (
        typeof result.message !== "string" ||
        !["recorded", "needs_confirmation", "needs_clarification", "rejected"].includes(String(result.status)) ||
        result.status === "recorded" && (typeof result.event_id !== "string" || !uuid.test(result.event_id)) ||
        result.status === "needs_confirmation" &&
          (typeof result.proposal_id !== "string" || !uuid.test(result.proposal_id))
      ) throw Error("Unconfirmed result");
      return json(result);
    } catch (e) {
      if (e instanceof APIError) return json({ code: e.code, message: e.message }, e.status);
      return json({
        code: "temporarily_unavailable",
        message: "Could not confirm recording. Open the app and retry the pending entry.",
      }, 503);
    }
  };
}
