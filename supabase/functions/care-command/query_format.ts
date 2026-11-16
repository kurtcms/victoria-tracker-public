import type { FormatContext, Presentation, QueryFacts, QueryRecord, QuerySpec } from "./query_types.ts";
type Language = FormatContext["language"];
const metric: Presentation = { milk: "ml", weight: "kg", surface: "spoken" };
const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
const finite = (n: number | undefined): n is number => typeof n === "number" && Number.isFinite(n) && n >= 0;

export function formatDuration(
  minutes: number,
  language: Language = "en",
  surface: Presentation["surface"] = "spoken",
): string {
  const total = Math.max(0, Math.floor(minutes));
  const hours = Math.floor(total / 60), rest = total % 60;
  if (surface === "visual") return hours ? `${hours}h${rest ? ` ${rest}m` : ""}` : `${rest}m`;
  if (language === "yue") return hours ? `${hours}個鐘${rest ? `零${rest}分鐘` : ""}` : `${rest}分鐘`;
  return hours ? `${plural(hours, "hour")}${rest ? ` and ${plural(rest, "minute")}` : ""}` : plural(rest, "minute");
}
export function formatMilk(ml: number, language: Language = "en", presentation: Presentation = metric): string {
  if (presentation.milk === "oz") {
    const ounces = Number((ml / 29.5735295625).toFixed(2));
    return language === "yue"
      ? `約${ounces}美制液安士`
      : presentation.surface === "visual"
      ? `≈${ounces} US fl oz`
      : `approximately ${plural(ounces, "US fluid ounce")}`;
  }
  return language === "yue" ? `${ml}毫升` : presentation.surface === "visual" ? `${ml} mL` : plural(ml, "millilitre");
}
export function formatWeight(kg: number, language: Language = "en", presentation: Presentation = metric): string {
  if (presentation.weight === "lb") {
    const totalOunces = Math.round(kg / 0.45359237 * 16 * 100) / 100,
      pounds = Math.floor(totalOunces / 16),
      ounces = Number((totalOunces % 16).toFixed(2));
    if (language === "yue") return `約${pounds}磅${ounces ? `${ounces}安士` : ""}`;
    if (presentation.surface === "visual") return `≈${pounds} lb${ounces ? ` ${ounces} oz` : ""}`;
    return `approximately ${plural(pounds, "pound")}${ounces ? ` and ${plural(ounces, "ounce")}` : ""}`;
  }
  if (presentation.surface === "visual") return `${kg} kg`;
  const grams = Math.round(kg * 1000), kilos = Math.floor(grams / 1000), remainder = grams % 1000;
  if (language === "yue") return kilos ? `${kilos}公斤${remainder ? `${remainder}克` : ""}` : `${remainder}克`;
  return kilos
    ? `${plural(kilos, "kilogram")}${remainder ? ` and ${plural(remainder, "gram")}` : ""}`
    : plural(remainder, "gram");
}
// Offset tables captured by the phone own the calendar. Intl only labels an
// already resolved wall date, never chooses the offset or parses local strings.
function wall(at: string, context: FormatContext): string | undefined {
  if (/^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(?::\d{2})?$/.test(at)) return at.replace(" ", "T");
  if (!/(?:Z|[+-]\d{2}:\d{2})$/.test(at)) return;
  const instant = Date.parse(at);
  if (!Number.isFinite(instant)) return;
  const offset = [...context.command.zone_offsets].reverse().find((o) => Date.parse(o.from) <= instant);
  if (!offset) {
    const parts = new Intl.DateTimeFormat("sv-SE", {
      timeZone: context.command.time_zone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hourCycle: "h23",
    }).format(new Date(instant));
    return parts.replace(" ", "T");
  }
  return new Date(instant + offset.seconds * 1000).toISOString().slice(0, 19);
}
function calendarLabel(day: string, context: FormatContext, exact: boolean, month = false): string {
  const language = context.language;
  const today = wall(context.command.reference_at, context)?.slice(0, 10);
  // UTC here is a neutral calendar arithmetic coordinate, not an event instant.
  const date = new Date(`${day.slice(0, 7)}-${month ? "01" : day.slice(8, 10)}T12:00:00Z`);
  if (!Number.isFinite(date.getTime())) return day;
  const gap = today ? Math.round((Date.parse(`${today}T12:00:00Z`) - date.getTime()) / 86400000) : -1;
  if (!month && !exact) {
    if (gap === 0) return language === "en" ? "today" : "今日";
    if (gap === 1) return language === "en" ? "yesterday" : "琴日";
    if (gap >= 2 && gap <= 6) {
      return new Intl.DateTimeFormat(language === "en" ? "en-US" : "zh-HK", { timeZone: "UTC", weekday: "long" })
        .format(date);
    }
  }
  return new Intl.DateTimeFormat(language === "en" ? "en-US" : "zh-HK", {
    timeZone: "UTC",
    month: "long",
    ...(!month ? { day: "numeric" as const } : {}),
    ...(month || exact || day.slice(0, 4) !== today?.slice(0, 4) ? { year: "numeric" as const } : {}),
  }).format(date);
}
export function formatTemporal(record: QueryRecord, context: FormatContext, query: QuerySpec): string {
  if (record.date) return calendarLabel(record.date, context, query.exact, record.precision === "month");
  if (!record.at) return "";
  const local = wall(record.at, context);
  if (!local) return "";
  const day = local.slice(0, 10), hour = Number(local.slice(11, 13)), minute = local.slice(14, 16);
  const clock = context.language === "en"
    ? `${hour % 12 || 12}:${minute} ${hour < 12 ? "AM" : "PM"}`
    : `${local.slice(11, 13)}:${minute}`;
  const reportDay = query.day;
  if (!query.exact && day === (reportDay ?? wall(context.command.reference_at, context)?.slice(0, 10))) return clock;
  const date = calendarLabel(day, context, query.exact);
  if (query.exact) {
    const instant = Date.parse(record.at),
      tableOffset = [...context.command.zone_offsets].reverse().find((o) => Date.parse(o.from) <= instant);
    const offsetSeconds = tableOffset?.seconds ?? Math.round((Date.parse(local + "Z") - instant) / 1000);
    const abs = Math.abs(offsetSeconds),
      offset = `UTC${offsetSeconds < 0 ? "-" : "+"}${String(Math.floor(abs / 3600)).padStart(2, "0")}:${
        String(Math.floor(abs % 3600 / 60)).padStart(2, "0")
      }`;
    const fullClock = context.language === "en"
      ? clock.replace(/ (AM|PM)$/, `:${local.slice(17, 19) || "00"} $1`)
      : `${clock}:${local.slice(17, 19) || "00"}`;
    return `${date}${context.language === "en" ? " at " : " "}${fullClock} (${offset})`;
  }
  return context.language === "en" ? `${date} at ${clock}` : `${date}${clock}`;
}
function noun(q: QuerySpec, language: Language): string {
  if (language === "yue") {
    return q.domain === "feeding"
      ? "飲奶"
      : q.domain === "diaper"
      ? q.subtype === "wet" ? "濕尿片" : q.subtype === "dirty" ? "大便尿片" : "尿片"
      : q.domain === "sleep"
      ? q.subtype === "nap" ? "日間睡眠" : q.subtype === "wake" ? "醒來" : "睡眠"
      : q.domain === "weight"
      ? "體重"
      : q.domain === "milestone"
      ? "成長"
      : "照顧";
  }
  return q.domain === "feeding"
    ? "feeding"
    : q.domain === "diaper"
    ? q.subtype === "wet" ? "wet diaper" : q.subtype === "dirty" ? "dirty diaper" : "diaper"
    : q.domain === "sleep"
    ? q.subtype === "nap" ? "daytime sleep" : q.subtype === "wake" ? "wake-up" : "sleep"
    : q.domain === "weight"
    ? "weight"
    : q.domain === "milestone"
    ? "milestone"
    : "care";
}
function sleepTotal(f: QueryFacts, c: FormatContext): string {
  const done = formatDuration(f.completed_minutes, c.language, c.presentation.surface);
  const open = formatDuration(f.open_minutes, c.language, c.presentation.surface);
  return c.language === "en"
    ? `${done} of completed sleep${f.open_minutes > 0 ? `; an open session has ${open} elapsed, unconfirmed` : ""}`
    : `已完成睡眠共${done}${f.open_minutes > 0 ? `；未結束嘅一段已過咗${open}，實際睡眠時間未確認` : ""}`;
}
function sleepState(f: QueryFacts, c: FormatContext): string {
  const r = f.last_sleep, en = c.language === "en";
  if (!r || f.issues.includes("inconsistent_sleep")) {
    return en ? "The records do not confirm the current sleep state." : "現有記錄未能確認而家嘅睡眠狀態。";
  }
  const waking = !!r.end;
  const at = formatTemporal(waking ? { ...r, at: r.end! } : r, c, f.query);
  const stale = f.evidence === "stale" || f.issues.includes("stale_sleep");
  const lead = en
    ? `Latest recorded ${waking ? "wake-up" : "sleep start"}${at ? `: ${at}` : ""}.`
    : `最近${waking ? "醒來" : "瞓著"}記錄${at ? `係${at}` : ""}。`;
  if (!stale && f.sleep_state === "unknown") {
    return lead + (en ? " The records do not establish the current sleep state." : "現有記錄未能確認而家嘅睡眠狀態。");
  }
  if (stale) {
    return lead +
      (en
        ? `${
          !waking ? " I don’t have a wake-up recorded." : ""
        } This record is stale; I can’t confirm the current sleep state.`
        : `${!waking ? "未有醒來記錄。" : ""}呢項記錄已過時，未能確認而家係咪瞓緊。`);
  }
  return lead +
    (en
      ? ` ${waking ? "Last recorded awake" : "Still marked asleep"}; the current state is unconfirmed.`
      : `${waking ? "上次記錄係醒咗" : "記錄顯示未瞓醒"}，實際狀態未確認。`);
}
function recordDescription(r: QueryRecord, f: QueryFacts, c: FormatContext): string {
  const q = f.query, en = c.language === "en";
  const at = formatTemporal(q.domain === "sleep" && q.subtype === "wake" && r.end ? { ...r, at: r.end } : r, c, q);
  let value = "";
  if (q.domain === "feeding") {
    const amount = q.quantity === "offered" ? r.offered : q.quantity === "remaining" ? r.remaining : r.value;
    value = finite(amount) ? formatMilk(amount, c.language, c.presentation) : en ? "amount unknown" : "份量未確認";
    if (q.quantity !== "consumed") {
      value = `${en ? q.quantity : q.quantity === "offered" ? "提供份量" : "剩低份量"}: ${value}`;
    }
  } else if (q.domain === "weight") {
    value = finite(r.value) ? formatWeight(r.value, c.language, c.presentation) : en ? "weight unknown" : "體重未確認";
  } else if (q.domain === "milestone") value = r.title ?? (en ? "milestone record" : "成長記錄");
  else if (q.domain === "diaper") {
    value = en
      ? r.diaper === "mixed" ? "wet and dirty diaper" : `${r.diaper ?? ""} diaper`.trim()
      : r.diaper === "mixed"
      ? "濕同大便尿片"
      : r.diaper === "wet"
      ? "濕尿片"
      : r.diaper === "dirty"
      ? "大便尿片"
      : "尿片";
  } else if (q.subtype === "wake") value = en ? "wake-up" : "醒來";
  else if (r.end && r.at && Number.isFinite(Date.parse(r.end)) && Number.isFinite(Date.parse(r.at))) {
    const duration = formatDuration((Date.parse(r.end) - Date.parse(r.at)) / 60000, c.language, c.presentation.surface);
    const end = formatTemporal({ ...r, at: r.end }, c, q);
    value = en ? `sleep lasting ${duration}, wake-up ${end}` : `瞓咗${duration}，${end}醒來`;
  } else value = en ? "sleep start; wake-up unconfirmed" : "瞓著；醒來時間未確認";
  return `${value}${at ? en ? ` (${at})` : `（${at}）` : ""}`;
}
export function formatQuery(f: QueryFacts, context: FormatContext): string {
  const c: FormatContext = {
    ...context,
    presentation: {
      ...context.presentation,
      ...(f.query.unit === "oz" || f.query.unit === "ml" ? { milk: f.query.unit } : {}),
      ...(f.query.unit === "lb" || f.query.unit === "kg" ? { weight: f.query.unit } : {}),
    },
  };
  const q = f.query, en = c.language === "en", name = f.child_name, subject = noun(q, c.language);
  const day = q.day ? calendarLabel(q.day, c, q.exact) : "";
  const scope = q.period === "rolling"
    ? en ? ` in the last ${formatDuration(q.minutes ?? 0, "en")}` : `過去${formatDuration(q.minutes ?? 0, "yue")}`
    : q.period === "morning"
    ? en ? ` ${day === "today" ? "this morning" : `${day} morning`}` : `${day}朝早`
    : q.period === "afternoon"
    ? en ? ` ${day === "today" ? "this afternoon" : `${day} afternoon`}` : `${day}下晝`
    : q.period === "tonight"
    ? en ? ` ${day === "today" ? "tonight" : `${day} evening`}` : `${day}晚上`
    : day
    ? en ? ` ${day === "today" || day === "yesterday" ? day : `on ${day}`}` : day
    : "";
  const unknown = en
    ? `I couldn’t confirm ${name}’s ${subject} from the records.`
    : `暫時未能從記錄確認${name}嘅${subject}。`;
  if (f.evidence === "unknown" && q.operation !== "state") {
    return en ? `I don’t have any ${subject} records for ${name}${scope}.` : `${name}${scope}未有相關${subject}記錄。`;
  }
  if (f.evidence === "negative" && q.operation !== "report") {
    return en
      ? `No ${subject} records were found for ${name}${scope}. This does not confirm what happened outside the records.`
      : `${name}${scope}未有相關${subject}記錄；呢個唔代表實際上冇發生。`;
  }
  let answer: string;
  if (q.operation === "report" && q.domain !== "care") {
    if (q.domain === "feeding") {
      answer = finite(f.value)
        ? en
          ? `${formatMilk(f.value, c.language, c.presentation)} of recorded ${
            q.quantity === "consumed" ? "milk intake" : q.quantity + " milk"
          } across ${plural(f.count, "feed")}${scope}.`
          : `${scope}飲奶記錄共${formatMilk(f.value, c.language, c.presentation)}，共${f.count}餐。`
        : unknown;
    } else if (q.domain === "sleep") {
      answer = en ? `${name}${scope}: ${sleepTotal(f, c)}.` : `${name}${scope}：${sleepTotal(f, c)}。`;
    } else if (q.domain === "diaper" && q.subtype !== "all") {
      answer = en ? `${plural(f.count, subject)} recorded${scope}.` : `${scope}${subject}記錄共${f.count}次。`;
    } else if (q.domain === "diaper") {
      answer = en
        ? `${plural(f.diaper_count, "diaper change")}${scope}, with ${plural(f.wet_count, "wet diaper")} and ${
          plural(f.dirty_count, "dirty diaper")
        } recorded.`
        : `${scope}換尿片記錄共${f.diaper_count}次，濕尿片${f.wet_count}次，大便尿片${f.dirty_count}次。`;
    } else {answer = f.records.length
        ? f.records.map((r) => recordDescription(r, f, c)).join(en ? "; " : "；") + (en ? "." : "。")
        : unknown;}
    if (q.detailed && f.records.length && !["milestone", "weight"].includes(q.domain)) {
      answer += (en ? " " : "") + f.records.slice(0, 30).map((r) => recordDescription(r, f, c)).join(en ? "; " : "；") +
        (en ? "." : "。");
      if (f.records.length > 30) answer += en ? " More records are available in the app." : "更多記錄請喺App查看。";
    }
  } else if (q.domain === "care") {
    answer = en
      ? `${name}${scope}: ${formatMilk(f.feeding_ml, c.language, c.presentation)} recorded milk across ${
        plural(f.feeding_count, "feed")
      }, ${plural(f.wet_count, "wet diaper")}, ${plural(f.dirty_count, "dirty diaper")}, and ${sleepTotal(f, c)}.`
      : `${name}${scope}：飲奶記錄共${
        formatMilk(f.feeding_ml, c.language, c.presentation)
      }，濕尿片${f.wet_count}次，大便尿片${f.dirty_count}次，${sleepTotal(f, c)}。`;
    answer += f.last_feeding
      ? en
        ? ` Latest feeding: ${
          recordDescription(f.last_feeding, { ...f, query: { ...q, domain: "feeding", quantity: "consumed" } }, c)
        }.`
        : `最近飲奶：${
          recordDescription(f.last_feeding, { ...f, query: { ...q, domain: "feeding", quantity: "consumed" } }, c)
        }。`
      : en
      ? " No earlier feeding is recorded."
      : "未有之前嘅飲奶記錄。";
    answer += `${en ? " " : ""}${sleepState(f, c)}`;
    if (q.detailed && f.records.length) {
      answer += (en ? " Details: " : "詳細記錄：") + f.records.slice(0, 30).map((r) =>
        recordDescription(r, { ...f, query: { ...q, domain: r.domain ?? q.domain } }, c)
      ).join(en ? "; " : "；") + (en ? "." : "。");
      if (f.records.length > 30) {
        answer += en ? " More records are available in the app." : "更多記錄請喺App查看。";
      }
    }
  } else if (q.operation === "state") answer = sleepState(f, c);
  else if (q.operation === "count" || q.operation === "exists" || q.operation === "total" && q.domain === "diaper") {
    answer = en
      ? `${name} has ${plural(f.count, `${subject} record`)}${scope}.`
      : `${name}${scope}有${f.count}項${subject}記錄。`;
  } else if (q.operation === "total" && q.domain === "sleep") {
    answer = en ? `${name}${scope}: ${sleepTotal(f, c)}.` : `${name}${scope}：${sleepTotal(f, c)}。`;
  } else if (q.operation === "total" && q.domain === "feeding") {
    const amount = f.value;
    answer = finite(amount)
      ? en
        ? `${formatMilk(amount, c.language, c.presentation)} across ${plural(f.feeding_count, "recorded feed")}.`
        : `飲奶記錄共${formatMilk(amount, c.language, c.presentation)}，共${f.feeding_count}餐。`
      : unknown;
  } else if (q.operation === "elapsed" || q.operation === "duration") {
    answer = finite(f.value)
      ? en
        ? q.operation === "elapsed"
          ? `It’s been ${
            formatDuration(f.value, c.language, c.presentation.surface)
          } since ${name}’s last recorded ${subject}.`
          : `The recorded ${subject} lasted ${formatDuration(f.value, c.language, c.presentation.surface)}.`
        : `${name}嘅${subject}記錄${q.operation === "elapsed" ? "至今已過" : "持續"}${
          formatDuration(f.value, c.language, c.presentation.surface)
        }。`
      : unknown;
  } else if (f.issues.includes("ambiguous_order") && f.records.length > 1) {
    answer = en
      ? `I can’t tell which record came ${q.operation === "first" ? "first" : "last"}: ${
        f.records.slice(0, 10).map((r) => recordDescription(r, f, c)).join("; ")
      }.`
      : `未能確認邊項記錄${q.operation === "first" ? "最早" : "最近"}：${
        f.records.slice(0, 10).map((r) => recordDescription(r, f, c)).join("；")
      }。`;
  } else if (f.records[0] && q.focus === "time") {
    answer = formatTemporal(f.records[0], c, q) + (en ? "." : "。");
  } else if (f.records[0] && q.focus === "amount" && q.domain === "feeding") {
    const amount = q.quantity === "offered"
      ? f.records[0].offered
      : q.quantity === "remaining"
      ? f.records[0].remaining
      : f.records[0].value;
    answer = finite(amount) ? formatMilk(amount, c.language, c.presentation) + (en ? "." : "。") : unknown;
  } else if (f.records[0]) {
    answer = en
      ? `${name}’s ${q.operation === "first" ? "first" : "latest"} recorded ${subject}: ${
        recordDescription(f.records[0], f, c)
      }.`
      : `${name}${q.operation === "first" ? "第一次" : "最近"}嘅${subject}記錄：${
        recordDescription(f.records[0], f, c)
      }。`;
  } else answer = unknown;
  if (
    q.domain === "diaper" && ["count", "total", "exists"].includes(q.operation) && ["wet", "dirty"].includes(q.subtype)
  ) answer += en ? " Mixed diapers count in both wet and dirty totals." : "混合尿片會計入濕同大便兩類。";
  if (
    (f.evidence === "stale" || f.issues.includes("stale_sleep")) && q.operation !== "state" &&
    q.operation !== "report" && q.domain === "sleep"
  ) {
    answer += en
      ? " The sleep record is stale and cannot confirm the current state."
      : "睡眠記錄已過時，未能確認而家嘅狀態。";
  }
  if (f.evidence === "incomplete") {
    answer += en
      ? f.issues.includes("unknown_offered") || f.issues.includes("unknown_remaining")
        ? " Offered and remaining milk are not separately recorded."
        : f.issues.includes("missing_anchor") || f.issues.includes("ambiguous_anchor")
        ? " I need one clearly identified recorded event to use as the time reference."
        : f.issues.includes("month_precision")
        ? " A month-only observation cannot establish an exact day."
        : f.issues.includes("inconsistent_sleep")
        ? " Overlapping or inconsistent sleep records prevent a reliable duration total."
        : f.issues.includes("open_sleep")
        ? " No wake-up is confirmed for the open session."
        : f.issues.includes("ambiguous_order")
        ? " The recorded dates do not establish an exact order."
        : " Some records are incomplete; unknown amounts are not treated as zero."
      : f.issues.includes("unknown_offered") || f.issues.includes("unknown_remaining")
      ? "提供同剩低嘅奶量冇獨立記錄。"
      : f.issues.includes("month_precision")
      ? "只記低月份，未能確認確實日期。"
      : f.issues.includes("inconsistent_sleep")
      ? "睡眠記錄有重疊或唔一致，未能計算可靠總時間。"
      : f.issues.includes("open_sleep")
      ? "未結束嗰段未有確認醒來時間。"
      : "部分記錄唔完整，未知份量唔會當零計。";
  }
  if ((q.operation === "duration" || q.operation === "elapsed") && f.issues.includes("open_sleep")) {
    answer += en ? " The open sleep session is unconfirmed." : "未結束嘅睡眠時間仍未確認。";
  }
  if (f.issues.includes("nap_definition") || q.subtype === "nap") {
    answer += en
      ? " Daytime sleep means sessions starting from 06:00 to before 18:00 local time; naps are not separately labelled."
      : "日間睡眠係指手機當地時間06:00至18:00之前開始嘅睡眠，記錄本身冇獨立午睡標籤。";
  }
  return answer;
}
