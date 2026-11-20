import { phoneDate, type RequestCommand } from "./domain.ts";
import { statedDates } from "./grounding.ts";
import { spokenNumber } from "./quantities.ts";
import type { QueryDomain, QuerySpec } from "./query_types.ts";

export const queryDomains = ["feeding", "diaper", "sleep", "weight", "milestone", "care"] as const;
export const queryOperations = [
  "latest",
  "first",
  "exists",
  "count",
  "total",
  "state",
  "elapsed",
  "duration",
  "report",
] as const;
export const readQuerySchema = {
  type: "object",
  additionalProperties: false,
  required: ["domain", "operation", "subtype", "quantity", "day", "period", "minutes", "detailed", "exact"],
  properties: {
    domain: { type: "string", enum: queryDomains },
    operation: { type: "string", enum: queryOperations },
    subtype: { type: "string", enum: ["all", "wet", "dirty", "nap", "wake", "start"] },
    quantity: { type: "string", enum: ["consumed", "offered", "remaining"] },
    day: { type: ["string", "null"] },
    period: {
      type: "string",
      enum: [
        "day",
        "morning",
        "afternoon",
        "tonight",
        "rolling",
        "since_feeding",
        "before_sleep",
        "after_sleep",
        "all",
      ],
    },
    minutes: { type: ["number", "null"] },
    detailed: { type: "boolean" },
    exact: { type: "boolean" },
  },
};
export const readCue = (s: string) =>
  /[?？]|\b(?:when|what|how|has|have|did|does|is|was|are|any|report|summary|summarize|tell|show)\b|幾時|幾多|幾耐|有冇|有沒有|嗎|未[？?。!！]?$|報告|總結/iu
    .test(s);
export const unsafeRead = (s: string) =>
  /\b(?:log|record|save|add|delete|remove|change|correct|set|if|suppose|imagine|should|would|could|will|plan)\b|記低|記錄咗|刪除|更正|如果|假設|應唔應該|打算/iu
    .test(s);
// Match inflections of the parent's actual words, not inferred cross-language
// equivalences. A title that cannot support this lexical topic stays unmatched.
function normalizeTopic(text: string): string {
  return text.normalize("NFC").toLowerCase()
    .replace(/\b(?:waved|waves|waving)\b/gu, "wave")
    .replace(/\b(?:smiled|smiles|smiling)\b/gu, "smile")
    .replace(/\b(?:crawled|crawls|crawling)\b/gu, "crawl")
    .replace(/\b(?:rolled|rolls|rolling)\b/gu, "roll")
    .replace(/\s+/gu, " ").trim();
}
export function milestoneTopicMatches(title: string, topic: string): boolean {
  if (/\b(?:not|never|no)\b|唔|冇|未|沒有/iu.test(title)) return false;
  const hay = normalizeTopic(title), needle = normalizeTopic(topic);
  if (!needle) return false;
  const escaped = needle.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  return /\p{Script=Latin}/u.test(needle)
    ? new RegExp("(^|[^\\p{Script=Latin}\\p{N}_])" + escaped + "(?=$|[^\\p{Script=Latin}\\p{N}_])", "u").test(hay)
    : hay.includes(needle);
}
const shiftDay = (day: string, n: number) =>
  new Date(Date.parse(day + "T12:00:00Z") + n * 86400000).toISOString().slice(0, 10);
/** Semantic components, not a list of utterance-specific handlers. Unsupported modifiers fail closed. */
export function interpretReadQuery(text: string, c: RequestCommand, followDomain?: QueryDomain): QuerySpec | undefined {
  // A single event can answer both its time and amount; conjunctions joining
  // independent clauses still fail closed before any retrieval or mutation.
  const projection = /\b(?:when\s+and\s+how much|how much\s+and\s+when)\b/iu;
  const bothFields = projection.test(text);
  const scopedText = text.replace(projection, "when");
  if (!readCue(text) || unsafeRead(text) || /\b(?:and|then|also)\b|同埋|跟住|然後/iu.test(scopedText)) return;
  const t = scopedText.normalize("NFC").toLowerCase();
  const temporalText = t.replace(/上(?:個)?(?:星期|禮拜)[一二三四五六日天]/gu, "");
  if (
    /\b(?:tomorrow|next|week|month|previous)\b|\b(?:last|this|past|next) year\b|聽日|明天|上星期|下星期|上個月|第二|前日|尋晚|去年|今年|明年/iu
      .test(temporalText)
  ) return;
  // Temporal uses of "last" are windows, never an event subject or selector.
  const selectorText = t.replace(
    /\b(?:last|past)\s+(?:(?:[\w.-]+\s+)?(?:hours?|minutes?|hrs?|mins?)|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/giu,
    "",
  ).replace(
    /(?:過去|最近)[零一二兩三四五六七八九十百\d]+(?:小時|個鐘|分鐘)|上(?:個)?(?:星期|禮拜)[一二三四五六日天]/gu,
    "",
  );
  const subjectPhrase = selectorText.match(/\b(?:first|last|latest|most recent)\s+([^?？。!！,，]+)/u)?.[1] ??
    selectorText.match(/(?:第一次|上次|最後一次)([^?？。!！,，]+)/u)?.[1];
  const subjectTopic = subjectPhrase?.split(
    /\s+(?:today|yesterday|this|on|in|since|before|after)\b|係幾時|幾時|係邊日|喺邊日/u,
  )[0].trim();
  const genericSubject = subjectTopic !== undefined &&
    /^(?:milestones?|records?)\b|^(?:成長記錄|里程碑)/u.test(subjectTopic);
  if (
    /\blast night\b|\brecently\b|\blately\b|尋晚|昨晚/iu.test(t) ||
    /\b(?:since|before|after)\b.*\b(?:first|second|third|earlier|previous)\b|\bat\s+(?:\d|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|noon|midnight)\b/iu
      .test(t)
  ) return;
  const topicMatch = selectorText.match(
    /\b(?:wav(?:e[ds]?|ing)|smil(?:e[ds]?|ing)|crawl(?:ed|s|ing)?|roll(?:ed|s|ing)?)(?: (?!(?:today|yesterday|this|on|in)\b)[a-z]+)*\b|揮手|微笑|笑|爬行|爬|翻身|轉身/iu,
  );
  const topic = subjectTopic && !genericSubject
    ? normalizeTopic(subjectTopic)
    : topicMatch
    ? normalizeTopic(topicMatch[0])
    : undefined;
  const isWet = (s: string) => /\b(?:wet|pee(?:d|ing)?|wee|urine|number\s*(?:one|1))\b|濕|尿尿|屙尿|小便/iu.test(s);
  const isDirty = (s: string) =>
    /\b(?:dirty|poop(?:ed|ing)?|poo|stool|bowel|number\s*(?:two|2))\b|大便|便便|屙屎/iu.test(s);
  const isNap = (s: string) => /\bnap(?:s|ped|ping)?\b|小睡|午睡/iu.test(s);
  const isWake = (s: string) => /\b(?:up|awake|wake|woke|woken)\b|起身|醒/iu.test(s);
  const wet = isWet(t), dirty = isDirty(t), nap = isNap(t), wake = isWake(t);
  const domainCues: [QueryDomain, (s: string) => boolean][] = [
    [
      "feeding",
      (s) =>
        /\b(?:feed(?:ing|s)?|fed|eat|ate|eaten|drink|drank|drunk|milk|bottles?|nurse|nursed|millilitres?|milliliters?|ml|mil)\b|飲奶|飲咗|食奶|餵奶|奶量/iu
          .test(s),
    ],
    ["diaper", (s) => isWet(s) || isDirty(s) || /\b(?:diapers?|napp(?:y|ies))\b|尿片/iu.test(s)],
    ["sleep", (s) => isNap(s) || isWake(s) || /\b(?:sleep(?:ing)?|slept|asleep|bed)\b|瞓|睡/iu.test(s)],
    ["weight", (s) => /\b(?:weight|weigh|heavy|weighed)\b|體重|幾重/iu.test(s)],
  ];
  const cues: [QueryDomain, boolean][] = domainCues.map(([domain, matches]) => [domain, matches(t)]);
  cues.push(["milestone", topic !== undefined || /\bmilestones?\b|成長記錄|里程碑/iu.test(t)]);
  // First/latest feed, diaper, sleep and weight keep their concrete domain.
  // Otherwise the parent's contiguous subject is an exact lexical memory topic.
  if (subjectTopic && !genericSubject && !topicMatch && domainCues.some(([, matches]) => matches(subjectTopic))) {
    cues[cues.length - 1][1] = false;
  }
  const sinceFeeding = !/^how long since/iu.test(t) &&
    /\bsince\b.*\b(?:feed|feeding|fed|ate|eat|milk)\b|上次飲奶之後/iu.test(t);
  const beforeSleep = /\bbefore\b.*\b(?:nap|sleep)\b|(?:瞓覺|午睡|小睡)之前/iu.test(t);
  const afterSleep = /\bafter\b.*\b(?:nap|sleep)\b|(?:瞓醒|午睡|小睡)之後/iu.test(t);
  const anchorDomain = sinceFeeding ? "feeding" : beforeSleep || afterSleep ? "sleep" : null;
  let domains = cues.filter(([, yes]) => yes).map(([domain]) => domain);
  if (anchorDomain && domains.length > 1) domains = domains.filter((d) => d !== anchorDomain);
  const care = /\b(?:care|status|doing|summary|summari[sz]e)\b|點呀|點樣|照顧報告|狀態報告|總結|總覽/iu.test(t);
  if (domains.length > 1 && !care) return;
  const anaphora =
    /^(?:how much|when|what time) (?:was|is|did|has) (?:that|it|she|he|her|him)(?: (?:have|had|drink|drunk|consume))?[? .]*$|^嗰次(?:幾多|幾時)[？?。]*$/iu
      .test(t);
  const domain: QueryDomain | undefined = care ? "care" : domains[0] ?? (anaphora ? followDomain : undefined);
  if (!domain) return;
  if (domain === "milestone" && !topic) {
    if (/\bmilestones?\s+(?:about|of|for|called|named|involving)\b/iu.test(t)) return;
    const modifier = t.match(/\b([a-z]+)\s+milestones?\b/u)?.[1];
    if (
      modifier &&
      ![
        "last",
        "latest",
        "first",
        "recent",
        "recorded",
        "any",
        "all",
        "her",
        "his",
        "a",
        "the",
        "new",
        "what",
        "which",
        "many",
        "detailed",
      ].includes(modifier)
    ) return;
  }
  if (/[?？].*\S|[.!。！]\s+\p{L}/u.test(t.replace(/[?？.!。！]\s*$/u, ""))) return;
  // Multiple event assertions in a read request cannot be silently ignored.
  if (
    /\b(?:she|he|baby) (?:drank|ate|had|slept|woke)\b.*\b(?:ml|mil|minutes?|hours?)\b/iu.test(t) &&
    !/^\s*(?:how|when|what|has|did)/iu.test(t)
  ) return;
  const latest = /\b(?:last|latest|most recent)\b|上次|最後/iu.test(selectorText) && !sinceFeeding &&
    !beforeSleep && !afterSleep;
  const when = /\bwhen\b|幾時/iu.test(t);
  const duration = /\bhow (?:long|much sleep)\b|幾耐/iu.test(t);
  const elapsed = /\b(?:since|ago)\b|距離|之前幾耐/iu.test(t);
  let operation: QuerySpec["operation"];
  if (domain === "care" || /\b(?:report|summary|list|show|tell)\b|報告|列出/iu.test(t)) operation = "report";
  else if (domain === "sleep" && /^(?:is|are)\b|緊|起身未|醒咗未/iu.test(t) && !duration && !when) operation = "state";
  else if (
    domain === "sleep" && duration && /\b(?:awake|asleep|been sleeping)\b/iu.test(t) && !/\b(?:was|did)\b/iu.test(t)
  ) operation = "elapsed";
  else if (duration && elapsed && !sinceFeeding) operation = "elapsed";
  else if (domain === "sleep" && duration && latest) operation = "duration";
  else if (/\bfirst\b|第一次/iu.test(t)) operation = "first";
  else if (latest || when || domain === "weight") operation = "latest";
  else if (
    domain === "feeding" && /\bhow many\b/iu.test(t) && /\b(?:ounces?|oz|millilitres?|milliliters?|ml)\b/iu.test(t)
  ) operation = "total";
  else if (
    /\bhow many\b|\bcount\b|幾多(?:次|餐)|多少次/iu.test(t) ||
    /幾多|多少/iu.test(t) && domain !== "feeding" && domain !== "sleep"
  ) operation = "count";
  else if (/\b(?:has|have|did|any)\b|有冇|有沒有/iu.test(t) && !duration && !/\bhow much\b|幾多/iu.test(t)) {
    operation = "exists";
  } else if (domain === "feeding" || domain === "sleep") {
    operation = duration || /\b(?:how much|total|amount)\b|幾多|總共/iu.test(t) ? "total" : "report";
  } else operation = "report";
  const subtype: QuerySpec["subtype"] = domain === "diaper"
    ? (wet && !dirty ? "wet" : dirty && !wet ? "dirty" : "all")
    : domain === "sleep"
    ? (nap ? "nap" : wake ? "wake" : when || operation === "elapsed" ? "start" : "all")
    : "all";
  const quantity: QuerySpec["quantity"] = /\b(?:offered|prepared)\b|沖咗|提供/iu.test(t)
    ? "offered"
    : /\b(?:remaining|leftover|left)\b|剩返|剩低/iu.test(t)
    ? "remaining"
    : "consumed";
  const today = phoneDate(c.reference_at, c), days = statedDates(t, today);
  if (
    (/\b(?:january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sept|sep|october|oct|november|nov|december|dec)\b/iu
      .test(t) && days.length === 0) || /\b\d{1,2}\/\d{1,2}\b/u.test(t)
  ) return;
  if (/\byesterday\b|琴日|尋日|昨天/iu.test(t)) days.push(shiftDay(today, -1));
  if (/\btoday\b|今日|今天/iu.test(t)) days.push(today);
  const weekday = t.match(/\blast\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/u);
  if (weekday) {
    const target = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"].indexOf(weekday[1]);
    const current = new Date(today + "T12:00Z").getUTCDay();
    days.push(shiftDay(today, -((current - target + 7) % 7 || 7)));
  }
  const hanWeek = t.match(/上(?:個)?(?:星期|禮拜)([一二三四五六日天])/u);
  if (hanWeek) {
    const target = "日一二三四五六".indexOf(hanWeek[1].replace("天", "日"));
    const current = new Date(today + "T12:00Z").getUTCDay();
    days.push(shiftDay(today, -((current - target + 7) % 7 || 7)));
  }
  const unique = [...new Set(days)];
  if (
    unique.length > 1 ||
    unique.some((d) =>
      !/^\d{4}-\d{2}-\d{2}$/.test(d) || !Number.isFinite(Date.parse(d + "T00:00Z")) ||
      new Date(d + "T00:00Z").toISOString().slice(0, 10) !== d || d > today
    )
  ) return;
  const rolling =
    t.match(/\b(?:(?:in|over|within|during) )?(?:the )?(?:last|past) ([\w .-]+?) (hours?|minutes?|mins?|hrs?)\b/u) ??
      t.match(/(?:過去|最近)([零一二兩三四五六七八九十百\d]+)(小時|個鐘|分鐘)/u);
  let minutes: number | null = null;
  if (rolling) {
    const n = spokenNumber(rolling[1]);
    if (n === undefined || n <= 0 || n > 10080) return;
    minutes = n * (/hour|hr|小時|個鐘/.test(rolling[2]) ? 60 : 1);
    if (minutes > 10080) return;
  }
  const morning = /\b(?:this morning|morning)\b|今朝|早上|朝早/iu.test(t),
    afternoon = /\b(?:this afternoon|afternoon)\b|下晝|下午/iu.test(t),
    tonight = /\b(?:tonight|this evening|evening)\b|今晚|傍晚/iu.test(t);
  if ([!!rolling, sinceFeeding, beforeSleep, afterSleep, morning, afternoon, tonight].filter(Boolean).length > 1) {
    return;
  }
  if ((rolling || sinceFeeding || beforeSleep || afterSleep) && unique.length) return;
  if (
    /\b(?:before|after|since|between|at \d|at noon|at midnight)\b|之前|之後/iu.test(t) && !sinceFeeding &&
    !beforeSleep && !afterSleep && operation !== "elapsed"
  ) return;
  if (/\bago\b|小時前|分鐘前|個鐘前/iu.test(t) && operation !== "elapsed") return;
  const period: QuerySpec["period"] = rolling
    ? "rolling"
    : sinceFeeding
    ? "since_feeding"
    : beforeSleep
    ? "before_sleep"
    : afterSleep
    ? "after_sleep"
    : morning
    ? "morning"
    : afternoon
    ? "afternoon"
    : tonight
    ? "tonight"
    : unique.length
    ? "day"
    : ["latest", "first", "elapsed", "duration", "state"].includes(operation)
    ? "all"
    : "day";
  if (operation === "state" && period !== "all") return; // historical state needs an explicit instant, not a whole day
  return {
    domain,
    operation,
    ...(!bothFields && when
      ? { focus: "time" as const }
      : !bothFields && /how much|幾多/iu.test(t) && domain === "feeding"
      ? { focus: "amount" as const }
      : {}),
    ...(domain === "feeding" && /\b(?:ounces?|oz)\b|安士|盎司/iu.test(t)
      ? { unit: "oz" as const }
      : domain === "feeding" && /\b(?:ml|mil|millilitres?|milliliters?)\b|毫升/iu.test(t)
      ? { unit: "ml" as const }
      : domain === "weight" && /\b(?:pounds?|lbs?)\b|磅/iu.test(t)
      ? { unit: "lb" as const }
      : domain === "weight" && /\b(?:kg|kilograms?)\b|公斤|千克/iu.test(t)
      ? { unit: "kg" as const }
      : {}),
    subtype,
    quantity,
    ...(domain === "milestone" && topic ? { topic } : {}),
    ...((beforeSleep || afterSleep) && nap ? { anchor_subtype: "nap" as const } : {}),
    day: period === "all" || ["rolling", "since_feeding", "before_sleep", "after_sleep"].includes(period)
      ? null
      : unique[0] ?? today,
    period,
    explicit_time: unique.length > 0 || !!rolling || sinceFeeding || beforeSleep || afterSleep || morning ||
      afternoon || tonight,
    minutes,
    detailed: /\b(?:detailed|full|individual|each)\b|詳細|逐次/iu.test(t),
    exact: /\b(?:exact|full date|timestamp|year)\b|完整日期|確實日期|年份/iu.test(t),
  };
}
