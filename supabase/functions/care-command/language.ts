export type Language = "en" | "yue";
export function detectLanguage(text: string): Language {
  return /\p{Script=Han}/u.test(text) ? "yue" : "en";
}
const labels: Record<string, string> = {
  feeding: "飲奶",
  diaper: "尿片",
  weight: "體重",
  sleep: "睡眠",
  milestone: "成長記錄",
  wet: "濕尿片",
  dirty: "大便尿片",
  mixed: "濕同大便尿片",
};
function label(value: unknown): string {
  if (typeof value !== "string") return "記錄";
  return labels[value] ?? value.slice(0, 200)
    .replace(/wet and dirty diaper/gi, "濕同大便尿片").replace(/wet diaper/gi, "濕尿片")
    .replace(/dirty diaper/gi, "大便尿片").replace(/\bmL\b/g, "毫升").replace(/\bkg\b/g, "公斤");
}
function text(value: unknown, max = 160): string {
  return typeof value === "string" ? value.slice(0, max) : "";
}
function number(value: unknown): string | undefined {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? String(value) : undefined;
}
function unit(value: unknown): string {
  return value === "ml" || value === "mL" ? "毫升" : value === "kg" ? "公斤" : value === "minutes" ? "分鐘" : "";
}
function answer(d: Record<string, unknown>): string {
  const name = text(d.child_name) || "寶寶", day = text(d.day);
  const at = d.query_kind === "last_weight"
    ? text(d.measurement_date) || text(d.display_time)
    : d.query_kind === "last_milestone"
    ? (d.date_precision === "month" ? text(d.occurred_on).slice(0, 7) : text(d.occurred_on))
    : text(d.display_time);
  const context = day ? `${name}喺${day}` : name;
  if (d.has_records === false) return `${context}未有相關記錄。`;
  if (d.has_records !== true) return "暫時未能確認查詢結果，請再試一次。";
  const value = number(d.value);
  const time = at ? `（${at}）` : "";
  switch (d.query_kind) {
    case "last_feeding": {
      const amount = value ?? number(d.feeding_ml);
      return amount === undefined ? "暫時未能確認上次飲奶份量。" : `${name}上次飲奶係${amount}毫升${time}。`;
    }
    case "last_weight":
      return value === undefined ? "暫時未能確認最近體重。" : `${name}最近體重係${value}公斤${time}。`;
    case "last_milestone":
      return text(d.title) ? `${name}最近嘅成長記錄係「${text(d.title)}」${time}。` : "暫時未能確認最近嘅成長記錄。";
    case "last_diaper":
      return labels[String(d.diaper_kind)]
        ? `${name}上次換嘅係${label(d.diaper_kind)}${time}。`
        : "暫時未能確認上次尿片類別。";
    case "wet_count":
      return number(d.wet_count) === undefined
        ? "暫時未能確認濕尿片數目。"
        : `${context}有${number(d.wet_count)}次濕尿片（包括混合尿片）。`;
    case "dirty_count":
      return number(d.dirty_count) === undefined
        ? "暫時未能確認大便尿片數目。"
        : `${context}有${number(d.dirty_count)}次大便尿片（包括混合尿片）。`;
    case "has_dirty":
      return number(d.dirty_count) === undefined
        ? "暫時未能確認有冇大便記錄。"
        : d.dirty_count === 0
        ? `${context}未有大便尿片記錄。`
        : `${context}有${number(d.dirty_count)}次大便尿片記錄。`;
    case "sleep_total":
      return number(d.sleep_minutes) === undefined
        ? "暫時未能確認睡眠總時間。"
        : `${context}總共瞓咗${number(d.sleep_minutes)}分鐘。`;
    case "day_summary": {
      const facts: string[] = [];
      if (number(d.feeding_ml) !== undefined) {
        facts.push(
          `飲奶${number(d.feeding_ml)}毫升${
            number(d.feeding_count) !== undefined ? `（${number(d.feeding_count)}次）` : ""
          }`,
        );
      }
      if (number(d.wet_count) !== undefined) facts.push(`濕尿片${number(d.wet_count)}次`);
      if (number(d.dirty_count) !== undefined) facts.push(`大便尿片${number(d.dirty_count)}次`);
      if (number(d.sleep_minutes) !== undefined) facts.push(`睡眠${number(d.sleep_minutes)}分鐘`);
      return facts.length ? `${context}：${facts.join("，")}。混合尿片會計入濕同大便兩類。` : "暫時未能確認當日總數。";
    }
    default:
      return "暫時未能確認查詢結果，請再試一次。";
  }
}
// RPC display times are already in the captured phone timezone. Do not parse
// them as UTC or apply the server timezone when shortening a report.
function reportTime(value: unknown, day: unknown, language: Language): string {
  const original = text(value);
  const match = original.match(/^(\d{4}-\d{2}-\d{2}) (\d{2}):(\d{2})$/);
  if (!match || Number(match[2]) > 23 || Number(match[3]) > 59) return original;
  const hour = Number(match[2]);
  const clock = language === "en"
    ? `${hour % 12 || 12}:${match[3]} ${hour < 12 ? "AM" : "PM"}`
    : `${match[2]}:${match[3]}`;
  return match[1] === day ? clock : language === "en" ? `${clock} on ${match[1]}` : `${match[1]} ${clock}`;
}
function extendedCareAnswer(d: Record<string, unknown>, language: Language): string | undefined {
  const kind = d.query_kind;
  if (!["last_sleep_start", "last_sleep_end", "care_report", "milk_total"].includes(String(kind))) return;
  const name = text(d.child_name) || (language === "en" ? "Your baby" : "寶寶");
  if (kind === "milk_total") {
    const amount = number(d.feeding_ml);
    if (amount === undefined || d.has_records !== true) {
      return language === "en"
        ? "I couldn’t confirm the milk total. Please try again."
        : "暫時未能確認飲奶總量，請再試一次。";
    }
    const day = text(d.day);
    return language === "en"
      ? `${name} has drunk ${amount} millilitres${d.is_today === true ? " today" : day ? ` on ${day}` : ""}.`
      : `${name}${d.is_today === true ? "今日" : day ? `喺${day}` : ""}飲咗${amount}毫升奶。`;
  }
  if (kind !== "care_report") {
    const at = text(d.display_time);
    if (d.has_records !== true || !at) {
      return language === "en"
        ? `No ${kind === "last_sleep_start" ? "sleep start" : "wake-up"} is recorded for ${name}${
          text(d.day) ? ` on ${text(d.day)}` : ""
        }.`
        : `${name}${text(d.day) ? `喺${text(d.day)}` : ""}未有${kind === "last_sleep_start" ? "瞓著" : "醒來"}記錄。`;
    }
    return language === "en"
      ? `${name} last ${kind === "last_sleep_start" ? "fell asleep" : "woke up"} at ${at}.`
      : `${name}上次${kind === "last_sleep_start" ? "瞓著" : "醒來"}係${at}。`;
  }
  const required = [d.feeding_ml, d.wet_count, d.dirty_count, d.sleep_minutes];
  if (required.some((value) => number(value) === undefined) || d.has_records !== true) {
    return language === "en"
      ? "I couldn’t confirm the care report. Please try again."
      : "暫時未能確認照顧報告，請再試一次。";
  }
  const lastAmount = number(d.last_feeding_ml), lastTime = reportTime(d.last_feeding_display_time, d.day, language);
  const sleepTime = reportTime(d.sleep_display_time, d.day, language),
    cutoff = reportTime(d.sleep_status_display_time, d.day, language);
  if (language === "en") {
    const totals = `${name} on ${text(d.day)}: ${number(d.feeding_ml)} millilitres, ${
      number(d.wet_count)
    } wet diapers, ${number(d.dirty_count)} dirty diapers, and ${number(d.sleep_minutes)} minutes of sleep.`;
    const feeding = lastAmount !== undefined && lastTime
      ? `Last feeding: ${lastAmount} millilitres at ${lastTime}.`
      : "No feeding is recorded before that time.";
    const sleep = d.sleep_running === true && sleepTime
      ? `sleeping since ${sleepTime}.`
      : d.sleep_running === false
      ? "no sleep running."
      : "sleep status unavailable.";
    return `${totals} ${feeding} Sleep status${cutoff ? ` at ${cutoff}` : ""}: ${sleep}`;
  }
  const totals = `${name}喺${text(d.day)}：飲奶${number(d.feeding_ml)}毫升，濕尿片${number(d.wet_count)}次，大便尿片${
    number(d.dirty_count)
  }次，瞓咗${number(d.sleep_minutes)}分鐘。`;
  const feeding = lastAmount !== undefined && lastTime
    ? `上次飲奶係${lastAmount}毫升（${lastTime}）。`
    : "嗰個時間之前未有飲奶記錄。";
  const sleep = d.sleep_running === true && sleepTime
    ? `由${sleepTime}開始瞓緊。`
    : d.sleep_running === false
    ? "冇進行中嘅睡眠。"
    : "暫時未能確認睡眠狀態。";
  return `${totals}${feeding}睡眠狀態${cutoff ? `（${cutoff}）` : ""}：${sleep}`;
}
/** Only render server/RPC facts. No model translation, totals, or inferred saves. */
export function localizeResponse(result: Record<string, unknown>, language: Language): Record<string, unknown> {
  const d = result.details && typeof result.details === "object" && !Array.isArray(result.details)
    ? result.details as Record<string, unknown>
    : {};
  if (result.status === "answered") {
    const message = extendedCareAnswer(d, language);
    if (message) return { ...result, message, language };
  }
  if (language === "en") {
    const records: Record<string, string> = {
      feeding: "feeding",
      diaper: "diaper",
      weight: "weight",
      sleep: "sleep",
      milestone: "milestone",
    };
    if (
      result.status === "recorded" && d.kind === "deleted" &&
      result.replayed !== true && result.already_recorded !== true
    ) {
      const diapers: Record<string, string> = {
        wet: "wet diaper",
        dirty: "dirty diaper",
        mixed: "wet and dirty diaper",
      };
      const record = d.record_kind === "diaper"
        ? diapers[String(d.diaper_kind)] ?? "diaper"
        : records[String(d.record_kind)];
      const name = text(d.child_name);
      if (record && name) return { ...result, message: `Deleted ${name}’s ${record} record.`, language };
    }
    return { ...result, language };
  }
  const name = text(d.child_name) || "寶寶";
  let message: string;
  if (result.replayed === true && result.status === "recorded" || result.already_recorded === true) {
    message = "呢項記錄之前已經儲存，今次冇重複新增。請喺 App 查看最新內容。";
  } else if (result.code === "future_event") message = "未有新增或更改記錄。唔可以記錄未來嘅事件，請講已經發生嘅事。";
  else if (result.code === "interpretation_unavailable") {
    message = "暫時未能理解呢句話，未有新增或更改記錄。請再講一次，或者喺 App 手動記錄。";
  } else if (result.code === "sleep_start_required") {
    message = "呢句描述入面嘅事件全部未有儲存，因為未有開始睡眠嘅記錄。請提供瞓著同醒來時間。";
  } else if (result.code === "sleep_overlap") {
    message = "呢句描述入面嘅事件全部未有儲存，因為睡眠時間同已有記錄重疊。請先喺 App 檢查睡眠記錄。";
  } else if (result.code === "record_not_found") {
    message = "搵唔到符合描述嘅記錄，冇更改任何內容。請喺 App 揀返要更正嘅記錄。";
  } else if (result.code === "ambiguous_record") {
    message = "有多過一項記錄符合描述，冇更改任何內容。請喺 App 揀返要更正嘅記錄。";
  } else if (result.code === "previous_amount_mismatch") {
    message = "上次飲奶記錄嘅份量同你講嘅原本份量唔一致，冇更改任何內容。請先確認要更正邊一餐。";
  } else if (result.status === "answered") message = answer(d);
  else if (result.status === "needs_confirmation") {
    const at = text(d.recorded_at) ? `（${text(d.recorded_at)}）` : "";
    const record = `${name}嘅${label(d.record_kind)}記錄${at}`;
    if (d.action === "delete") {
      message = `要刪除${record}${d.old_label ? `，原本係${label(d.old_label)}` : ""}嗎？請確認；未確認前唔會刪除。`;
    } else {
      const old = number(d.old_value), next = number(d.new_value), u = unit(d.unit);
      const before = old !== undefined ? `${old}${u}` : text(d.old_label) ? label(d.old_label) : "原本內容";
      const after = next !== undefined ? `${next}${u}` : text(d.new_label) ? label(d.new_label) : "所選內容";
      message = `要將${record}由${before}改成${after}嗎？請確認；未確認前唔會更改。`;
    }
  } else if (result.status === "cancelled" || d.kind === "cancelled") message = "已取消，冇更改任何記錄。";
  else if (result.status === "recorded") {
    if (d.kind === "deleted") message = `已刪除${name}嘅${label(d.record_kind)}記錄。`;
    else if (d.kind === "changed") message = `已更新${name}嘅${label(d.record_kind)}記錄。`;
    else if (d.kind === "batch" && number(d.count) !== undefined) message = `已記錄${name}嘅${number(d.count)}項事件。`;
    else if (d.kind === "recorded") {
      const value = number(d.value);
      message = `已記錄${name}嘅${label(d.record_kind)}${
        value !== undefined
          ? `：${value}${unit(d.unit)}`
          : d.diaper_kind
          ? `：${label(d.diaper_kind)}`
          : text(d.title)
          ? `：「${text(d.title)}」`
          : ""
      }。`;
    } else message = "已儲存記錄。";
  } else if (result.status === "rejected") message = "冇新增或更改記錄。請描述已經發生嘅事件，或者查詢照顧記錄。";
  else message = "未有新增或更改記錄。請講清楚一位寶寶嘅名字、事件、份量同時間；如要更正，請講明上次記錄同新數值。";
  return { ...result, message, language };
}
