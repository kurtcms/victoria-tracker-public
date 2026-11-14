import {
  APIError,
  Command,
  confirmation,
  EventPayload,
  extractionPrompt,
  extractionSchema,
  interpret,
  interpretationUnavailableMessage,
  unsupportedEventMessage,
  object,
  parseCommand,
} from "./domain.ts";

type Config = { supabaseURL: string; supabaseKey: string; openAIKey: string; model: string };
type Dependencies = { fetch: typeof fetch; now: () => Date };
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
async function boundedBody(req: Request): Promise<unknown> {
  if (!req.headers.get("content-type")?.toLowerCase().startsWith("application/json")) {
    throw new APIError(415, "invalid_input", "Send JSON.");
  }
  const reader = req.body?.getReader();
  if (!reader) throw new APIError(400, "invalid_input", "A request body is required.");
  const chunks: Uint8Array[] = [];
  let size = 0;
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
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new APIError(400, "invalid_input", "Invalid JSON.");
  }
}
export async function commandHash(c: Command): Promise<string> {
  // Fixed order, canonical payload; insignificant JSON key ordering does not affect retry identity.
  const event = c.mode === "manual"
    ? [c.event.event_type, c.event.occurred_at, c.event.volume_ml, c.event.diaper_kind, c.event.weight_kg]
    : c.text;
  const identity: unknown[] = [c.child_id.toLowerCase(), c.reference_at, c.source, c.locale, c.mode, event];
  // Preserve the exact legacy hash for old pending entries. A captured phone zone
  // becomes part of retry identity only when the client supplied one.
  if (c.time_zone !== undefined) identity.push(c.time_zone);
  const bytes = new TextEncoder().encode(JSON.stringify(identity));
  return Array.from(
    new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)),
    (b) => b.toString(16).padStart(2, "0"),
  ).join("");
}
export function createHandler(config: Config, deps: Dependencies = { fetch, now: () => new Date() }) {
  return async (req: Request): Promise<Response> => {
    try {
      if (req.method !== "POST") return json({ code: "method_not_allowed", message: "Use POST." }, 405);
      const authorization = req.headers.get("Authorization");
      if (!authorization || !/^Bearer \S+$/i.test(authorization)) {
        throw new APIError(401, "unauthorized", "Sign in to Victoria Tracker first.");
      }
      if (!config.supabaseURL || !config.supabaseKey) throw new Error("Missing Supabase configuration");
      const headers = { apikey: config.supabaseKey, Authorization: authorization, "Content-Type": "application/json" };
      const authResponse = await deps.fetch(`${config.supabaseURL}/auth/v1/user`, {
        headers,
        redirect: "error",
        signal: AbortSignal.timeout(8000),
      });
      if (authResponse.status >= 500) {
        throw new APIError(503, "auth_unavailable", "Authentication is temporarily unavailable.");
      }
      if (!authResponse.ok) throw new APIError(401, "unauthorized", "Sign in to Victoria Tracker first.");
      const user = object(await authResponse.json());
      if (
        typeof user.id !== "string" ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(user.id)
      ) {
        throw new APIError(401, "unauthorized", "Sign in again.");
      }
      if (user.is_anonymous === true) {
        throw new APIError(403, "anonymous_user", "Sign in with your parent account first.");
      }
      const command = parseCommand(await boundedBody(req), deps.now());
      const requestHash = await commandHash(command);
      const rest = async (path: string, body?: unknown): Promise<Response> => {
        return await deps.fetch(`${config.supabaseURL}/rest/v1/${path}`, {
          method: body === undefined ? "GET" : "POST",
          headers,
          redirect: "error",
          ...(body === undefined ? {} : { body: JSON.stringify(body) }),
          signal: AbortSignal.timeout(8000),
        });
      };
      const childResponse = await rest(`children?id=eq.${command.child_id}&select=id,name,time_zone&limit=1`);
      if (!childResponse.ok) throw new APIError(503, "database_unavailable", "Cannot check child access right now.");
      const children = await childResponse.json();
      if (!Array.isArray(children) || children.length !== 1) {
        throw new APIError(404, "child_unavailable", "Open the app and select your family's child.");
      }
      const child = children[0] as { id: string; name: string; time_zone: string };
      const existingResponse = await rest(
        `events?recorded_by=eq.${encodeURIComponent(user.id)}&request_id=eq.${command.request_id}&select=*&limit=1`,
      );
      if (!existingResponse.ok) {
        throw new APIError(503, "database_unavailable", "Cannot check previous recording right now.");
      }
      const existing = await existingResponse.json();
      if (!Array.isArray(existing)) throw new Error("Invalid database response");
      if (existing.length) {
        const event = existing[0];
        if (event.request_hash !== requestHash || event.child_id.toLowerCase() !== command.child_id.toLowerCase()) {
          throw new APIError(409, "idempotency_conflict", "This retry identifier belongs to a different command.");
        }
        return json({ status: "recorded", event, replayed: true, message: confirmation(event, child.name) });
      }
      const budget = await rest("rpc/consume_event_budget", {});
      if (!budget.ok) throw new APIError(503, "database_unavailable", "Recording is temporarily unavailable.");
      if (await budget.json() !== true) {
        throw new APIError(429, "rate_limited", "Too many attempts. Please wait one minute before retrying.");
      }
      let payload: EventPayload;
      if (command.mode === "manual") payload = command.event;
      else {
        const unavailable = () => json({
          status: "rejected",
          code: "interpretation_unavailable",
          message: interpretationUnavailableMessage,
        });
        if (!config.openAIKey) return unavailable();
        let result: ReturnType<typeof interpret>;
        // No recording RPC has run here. Return a normal dialog for interpretation
        // failures, rather than an App Intent error that Siri may render generically.
        try {
          const response = await deps.fetch("https://api.openai.com/v1/responses", {
            method: "POST",
            redirect: "error",
            headers: { Authorization: `Bearer ${config.openAIKey}`, "Content-Type": "application/json" },
            signal: AbortSignal.timeout(15000),
            body: JSON.stringify({
              model: config.model || "gpt-4.1-mini",
              store: false,
              max_output_tokens: 700,
              input: [{
                role: "system",
                content: extractionPrompt({
                  name: child.name,
                  time_zone: command.time_zone ?? child.time_zone,
                }, command.reference_at),
              }, {
                role: "user",
                content: command.text,
              }],
              text: { format: { type: "json_schema", name: "baby_event", strict: true, schema: extractionSchema } },
            }),
          });
          if (!response.ok) return unavailable();
          const data = object(await response.json());
          if (data.status !== "completed" || !Array.isArray(data.output)) return unavailable();
          const parts = data.output.map(object).filter((o) => o.type === "message").flatMap((o) => {
            if (!Array.isArray(o.content)) throw new Error("Invalid extraction content");
            return o.content.map(object);
          });
          if (parts.some((p) => p.type === "refusal")) {
            return json({ status: "rejected", code: "unsupported_event", message: unsupportedEventMessage });
          }
          const texts = parts.filter((p) => p.type === "output_text");
          if (texts.length !== 1 || typeof texts[0].text !== "string") return unavailable();
          result = interpret(JSON.parse(texts[0].text), child.name, command.reference_at, deps.now());
        } catch {
          // Do not return/log provider bodies, raw extraction, speech or credentials.
          return unavailable();
        }
        if (result.status !== "valid") return json(result);
        payload = result.event;
      }
      const saved = await rest("rpc/record_event", {
        p_child_id: command.child_id,
        p_request_id: command.request_id,
        p_request_hash: requestHash,
        p_event_type: payload.event_type,
        p_occurred_at: payload.occurred_at,
        p_input_source: command.source,
        p_volume_ml: payload.volume_ml,
        p_diaper_kind: payload.diaper_kind,
        p_weight_kg: payload.weight_kg,
      });
      if (!saved.ok) {
        const error = await saved.json();
        if (error.code === "23505") {
          throw new APIError(409, "idempotency_conflict", "This retry identifier belongs to a different command.");
        }
        throw new APIError(
          503,
          "persistence_unconfirmed",
          "Could not confirm recording. Retry the pending entry in the app.",
        );
      }
      const event = await saved.json();
      if (!event.id || !event.created_at || event.request_id?.toLowerCase() !== command.request_id.toLowerCase()) {
        throw new Error("Persistence not confirmed");
      }
      return json({ status: "recorded", event, replayed: false, message: confirmation(event, child.name) });
    } catch (error) {
      if (error instanceof APIError) return json({ code: error.code, message: error.message }, error.status);
      // Do not log command text, model output, tokens, or API responses.
      return json({
        code: "temporarily_unavailable",
        message: "Could not confirm recording. Open the app and retry the pending entry.",
      }, 503);
    }
  };
}
