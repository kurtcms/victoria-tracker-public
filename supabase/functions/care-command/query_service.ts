import { type Baby, type Outcome, type RequestCommand } from "./domain.ts";
import { type Conversation, resolveBaby } from "./conversation.ts";
import { interpretReadQuery } from "./query_interpret.ts";
import type { QueryContext, QuerySpec } from "./query_types.ts";
function currentContext(c: RequestCommand): QueryContext | undefined {
  const context = c.query_context;
  if (!context) return;
  const age = Date.parse(c.reference_at) - Date.parse(context.at);
  return age >= 0 && age <= 10 * 60000 ? context : undefined;
}
export function queryWithContext(spec: QuerySpec, c: RequestCommand, childID: string): QuerySpec {
  const context = currentContext(c), text = c.text ?? "";
  if (!context || context.child_id !== childID) return spec;
  // An explicit window/latest/total request always wins. A brief amount follow-up
  // reuses the exact prior record, never a moving 'latest' selection.
  if (
    !spec.explicit_time && context.domain === "feeding" && context.record_id && spec.domain === "feeding" &&
    spec.operation === "total" &&
    !/\b(?:today|yesterday|total|all|last|latest|morning|afternoon|tonight|since|before|after|hours?|minutes?|on)\b|今日|琴日|尋日|總共|上次|最近|今朝|下晝|今晚|月|日/iu
      .test(text)
  ) {
    return { ...spec, operation: "latest", period: "all", day: null, target_id: context.record_id };
  }
  return spec;
}
export function conversationalRead(babies: Baby[], c: RequestCommand): Conversation | Outcome | undefined {
  const text = c.text ?? "", context = currentContext(c);
  const spec = interpretReadQuery(text, c, context?.domain);
  if (!spec) return;
  const baby = resolveBaby(text, null, babies);
  if (!baby) {
    return {
      status: "needs_clarification",
      message: "Which baby is this for? Please include exactly one baby’s profile name.",
    };
  }
  // A literal name outside the roster must not silently resolve to the sole baby.
  const subject = text.match(/\b(?:has|did|does|is|was|have)\s+([\p{L}]+)\b/iu)?.[1] ??
    text.match(/([\p{L}]+)[’']s\b|([\p{Script=Latin}]+)嘅/iu)?.slice(1).find(Boolean);
  if (
    subject &&
    ![
      "she",
      "he",
      "the",
      "her",
      "his",
      "it",
      "that",
      "there",
      "offered",
      "consumed",
      "remaining",
      "recorded",
      "prepared",
      "what",
      "when",
      "how",
    ].includes(subject.toLowerCase()) && subject.toLowerCase() !== baby.name.toLowerCase()
  ) return { status: "needs_clarification", message: "Which baby do you mean? Please use a profile name." };

  return {
    child_id: baby.id,
    operation: "query",
    payload: { spec: queryWithContext(spec, c, baby.id) },
    language: /\p{Script=Han}/u.test(text) ? "yue" : "en",
  };
}
/** Convert old finite extraction contracts to the same calculation/presentation layer. */
export function legacyQuerySpec(_payload: Record<string, unknown>, c: RequestCommand): QuerySpec | undefined {
  // Legacy model kinds are suggestions, never permission to discard a temporal
  // qualifier that the current interpreter cannot validate.
  return interpretReadQuery(c.text ?? "", c);
}
