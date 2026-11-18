import { type Baby, phoneDate, type RequestCommand } from "./domain.ts";
import { milestoneTopicMatches } from "./query_interpret.ts";
import type { QueryFacts, QueryRecord, QuerySpec } from "./query_types.ts";
export type Snapshot = {
  complete: boolean;
  events: Record<string, unknown>[];
  sleep: Record<string, unknown>[];
  milestones: Record<string, unknown>[];
};
const time = (v: unknown): number => typeof v === "string" ? Date.parse(v) : NaN;
const finite = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v) && v >= 0;
const validID = (v: unknown): v is string => typeof v === "string" && v.length > 0;
export function wallTime(at: number, c: RequestCommand): Date {
  const offset = [...c.zone_offsets].reverse().find((o) => time(o.from) <= at);
  if (offset) return new Date(at + offset.seconds * 1000);
  // Older date-only memories use their stored date. Older instants use the IANA rules
  // only outside the captured 366-day phone context.
  const p = new Intl.DateTimeFormat("sv-SE", {
    timeZone: c.time_zone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).format(new Date(at));
  return new Date(p.replace(" ", "T") + "Z");
}
/** Intersect a wall-clock range with every captured offset segment, including DST. */
function wallRanges(day: string, fromHour: number, toHour: number, c: RequestCommand): [number, number][] {
  const start = Date.parse(day + "T00:00Z") + fromHour * 3600000,
    end = Date.parse(day + "T00:00Z") + toHour * 3600000,
    ref = time(c.reference_at);
  const ranges: [number, number][] = [];
  for (let i = 0; i < c.zone_offsets.length; i++) {
    const o = c.zone_offsets[i],
      a = Math.max(start - o.seconds * 1000, time(o.from)),
      b = Math.min(end - o.seconds * 1000, c.zone_offsets[i + 1] ? time(c.zone_offsets[i + 1].from) : Infinity, ref);
    if (a < b) ranges.push([a, b]);
  }
  // Requests outside captured offsets cannot silently return empty totals.
  return ranges;
}
// Calendar observations describe intervals, not midnight instants. UUIDs only
// stabilize display order; they never establish which observation happened first.
function boundaryCandidates(records: QueryRecord[], first: boolean, c: RequestCommand): QueryRecord[] {
  if (records.length < 2) return records;
  const calendarCoordinates = records.some((r) => r.date !== undefined);
  const intervals = records.map((record) => {
    if (record.date) {
      const start = Date.parse(
        `${record.date.slice(0, 7)}-${record.precision === "month" ? "01" : record.date.slice(8, 10)}T00:00:00Z`,
      );
      const date = new Date(start);
      const end = record.precision === "month"
        ? Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 1)
        : start + 86400000;
      return { record, start, end, exclusive: true };
    }
    const at = time(record.at);
    const point = calendarCoordinates ? wallTime(at, c).getTime() : at;
    return { record, start: point, end: point, exclusive: false };
  });
  if (first) {
    const end = Math.min(...intervals.map((i) => i.end));
    const inclusive = intervals.filter((i) => i.end === end).every((i) => !i.exclusive);
    return intervals.filter((i) => i.start < end || i.start === end && inclusive).map((i) => i.record);
  }
  const start = Math.max(...intervals.map((i) => i.start));
  return intervals.filter((i) => i.end > start || i.end === start && !i.exclusive).map((i) => i.record);
}
export function calculateQuery(q: QuerySpec, s: Snapshot, c: RequestCommand, baby: Baby): QueryFacts {
  if (s.complete !== true || !Array.isArray(s.events) || !Array.isArray(s.sleep) || !Array.isArray(s.milestones)) {
    throw Error("Incomplete care snapshot");
  }
  const commandRef = time(c.reference_at), issues: string[] = [];
  const reportRanges =
    q.operation === "report" && q.day && ["day", "morning", "afternoon", "tonight"].includes(q.period)
      ? wallRanges(
        q.day,
        q.period === "afternoon" ? 12 : q.period === "tonight" ? 18 : 0,
        q.period === "morning" ? 12 : q.period === "afternoon" ? 18 : 24,
        c,
      )
      : [];
  const ref = reportRanges.length ? Math.min(commandRef, Math.max(...reportRanges.map(([, end]) => end))) : commandRef;
  const feeds: QueryRecord[] = [],
    diapers: QueryRecord[] = [],
    weights: QueryRecord[] = [],
    sleeps: QueryRecord[] = [],
    milestones: QueryRecord[] = [];
  for (const row of s.events) {
    if (row.voided_at) continue;
    if (!validID(row.id) || !Number.isFinite(time(row.occurred_at))) throw Error("Invalid care event");
    if (time(row.occurred_at) > ref || ref < commandRef && time(row.occurred_at) === ref) continue;
    const r: QueryRecord = { id: row.id, at: String(row.occurred_at), domain: row.event_type as QueryRecord["domain"] };
    if (row.event_type === "feeding") {
      if (finite(row.volume_ml)) r.value = row.volume_ml;
      // A basis can be a prior corrected consumed total, not confirmed offered milk.
      // There is no offered/remaining observation in the current schema.
      feeds.push(r);
    } else if (row.event_type === "diaper") {
      if (!["wet", "dirty", "mixed"].includes(String(row.diaper_kind))) throw Error("Invalid diaper");
      r.diaper = row.diaper_kind as QueryRecord["diaper"];
      diapers.push(r);
    } else if (row.event_type === "weight") {
      if (finite(row.weight_kg)) r.value = row.weight_kg;
      if (typeof row.measurement_date === "string") {
        r.date = row.measurement_date;
        r.precision = "day";
        delete r.at;
      }
      weights.push(r);
    }
  }
  for (const row of s.sleep) {
    if (row.voided_at) continue;
    if (!validID(row.id) || !Number.isFinite(time(row.started_at))) throw Error("Invalid sleep");
    if (time(row.started_at) > ref || ref < commandRef && time(row.started_at) === ref) continue;
    const end = row.ended_at == null || time(row.ended_at) > ref ? null : String(row.ended_at);
    if (end !== null && (!Number.isFinite(time(end)) || time(end) <= time(row.started_at))) {
      issues.push("inconsistent_sleep");
    }
    sleeps.push({ id: row.id, domain: "sleep", at: String(row.started_at), end });
  }
  for (const row of s.milestones) {
    if (row.voided_at) continue;
    if (
      !validID(row.id) || typeof row.occurred_on !== "string" ||
      !["day", "month"].includes(String(row.date_precision)) || typeof row.title !== "string"
    ) throw Error("Invalid milestone");
    if (row.occurred_on > phoneDate(c.reference_at, c)) continue;
    milestones.push({
      id: row.id,
      domain: "milestone",
      date: row.occurred_on,
      precision: row.date_precision as "day" | "month",
      title: row.title,
    });
  }
  const stamp = (r: QueryRecord) => r.date ?? r.at ?? "";
  const desc = (a: QueryRecord, b: QueryRecord) => stamp(b).localeCompare(stamp(a)) || a.id.localeCompare(b.id);
  [feeds, diapers, weights, sleeps, milestones].forEach((rows) => rows.sort(desc));
  const ordered = [...sleeps].reverse();
  for (let i = 1; i < ordered.length; i++) {
    if ((ordered[i - 1].end === null || time(ordered[i - 1].end) > time(ordered[i].at))) {
      issues.push("inconsistent_sleep");
    }
  }
  const sleepBoundary = q.operation === "report" ? boundaryCandidates(sleeps, false, c) : sleeps.slice(0, 1);
  const feedBoundary = q.operation === "report" ? boundaryCandidates(feeds, false, c) : feeds.slice(0, 1);
  const latestSleep = sleepBoundary.length === 1 ? sleepBoundary[0] : undefined;
  const latestFeed = feedBoundary.length === 1 ? feedBoundary[0] : undefined;
  if (q.operation === "report" && (sleepBoundary.length > 1 || feedBoundary.length > 1)) issues.push("ambiguous_order");
  let ranges: [number, number][] = [[-Infinity, ref]];
  let periodUnavailable = false;
  if (q.period === "rolling") ranges = [[ref - (q.minutes ?? 0) * 60000, ref]];
  else if (["day", "morning", "afternoon", "tonight"].includes(q.period)) {
    const hours = q.period === "morning"
      ? [0, 12]
      : q.period === "afternoon"
      ? [12, 18]
      : q.period === "tonight"
      ? [18, 24]
      : [0, 24];
    ranges = wallRanges(q.day ?? phoneDate(c.reference_at, c), hours[0], hours[1], c);
    if (!ranges.length) {
      issues.push("unavailable_time_range");
      periodUnavailable = true;
    }
  } else if (q.period === "since_feeding") {
    if (latestFeed) ranges = [[time(latestFeed.at), ref]];
    else {
      issues.push("missing_anchor");
      periodUnavailable = true;
    }
  } else if (q.period === "before_sleep" || q.period === "after_sleep") {
    // "her nap" without a unique session is ambiguous. Use the most recent matching
    // session only when it is the sole session today; never pick among several naps.
    const today = phoneDate(c.reference_at, c),
      candidates = sleeps.filter((r) => {
        const local = wallTime(time(r.at), c);
        return local.toISOString().slice(0, 10) === today &&
          (q.anchor_subtype !== "nap" || local.getUTCHours() >= 6 && local.getUTCHours() < 18);
      });
    if (candidates.length !== 1 || (q.period === "after_sleep" && !candidates[0].end)) {
      issues.push("ambiguous_anchor");
      periodUnavailable = true;
    } else {ranges = q.period === "before_sleep"
        ? wallRanges(today, 0, 24, c).map(([a, b]) => [a, Math.min(b, time(candidates[0].at))] as [number, number])
          .filter(([a, b]) => a < b)
        : [[time(candidates[0].end), ref]];}
  }
  const inRange = (at: number) => ranges.some(([a, b]) => at >= a && at <= b && (at < b || b === commandRef));
  const dateInRange = (r: QueryRecord) => {
    if (!r.date) return inRange(time(r.at));
    if (q.period === "all") return true;
    if (q.period === "day") {
      if (r.precision === "month") {
        if (r.date.slice(0, 7) === q.day?.slice(0, 7)) issues.push("month_precision");
        return false;
      }
      return r.date === q.day;
    }
    issues.push("date_only_outside_day_query");
    return false;
  };
  const nap = (r: QueryRecord) => {
    const h = wallTime(time(r.at), c).getUTCHours();
    return h >= 6 && h < 18;
  };
  if (q.subtype === "nap" || q.anchor_subtype === "nap") issues.push("nap_definition");
  const dayFeeds = feeds.filter((r) => inRange(time(r.at))), dayDiapers = diapers.filter((r) => inRange(time(r.at)));
  let completed = 0, open = 0;
  const relevantSleep = sleeps.filter((r) => q.subtype !== "nap" || nap(r)).filter((r) =>
    ranges.some(([a, b]) => time(r.at) < b && (r.end === null || time(r.end) > a))
  );
  for (const r of relevantSleep) {
    const overlap = ranges.reduce(
      (sum, [a, b]) => sum + Math.max(0, Math.min(r.end ? time(r.end) : ref, b) - Math.max(time(r.at), a)) / 60000,
      0,
    );
    if (r.end === null) open += overlap;
    else completed += overlap;
  }
  if (relevantSleep.some((r) => r.end === null)) issues.push("open_sleep");
  if (issues.includes("inconsistent_sleep")) completed = 0;
  const stateRecord = latestSleep;
  let sleepState: QueryFacts["sleep_state"] = "unknown";
  const stateAt = stateRecord ? (stateRecord.end ?? stateRecord.at) : undefined;
  const stale = stateAt !== undefined && ref - time(stateAt) > 6 * 3600000;
  if (stale) issues.push("stale_sleep");
  if (stateRecord && !stale && !issues.includes("inconsistent_sleep")) {
    sleepState = stateRecord.end ? "awake" : "asleep";
  }
  let records: QueryRecord[] = q.domain === "feeding"
    ? dayFeeds
    : q.domain === "diaper"
    ? dayDiapers
    : q.domain === "sleep"
    ? relevantSleep
    : q.domain === "weight"
    ? weights.filter(dateInRange)
    : q.domain === "milestone"
    ? milestones.filter(dateInRange)
    : [];
  if (q.domain === "care") {
    records = [
      ...dayFeeds,
      ...dayDiapers,
      ...relevantSleep,
      ...weights.filter(dateInRange),
    ];
  }
  if (q.domain === "milestone" && q.topic) {
    records = records.filter((r) => r.title !== undefined && milestoneTopicMatches(r.title, q.topic!));
  }
  if (q.domain === "diaper" && q.subtype !== "all") {
    records = records.filter((r) => r.diaper === q.subtype || r.diaper === "mixed");
  }
  if (q.domain === "sleep" && q.subtype === "wake") {
    records = sleeps.filter((r) => r.end && inRange(time(r.end))).map((r) => ({ ...r, at: r.end! }));
  }
  if (q.domain === "sleep" && q.subtype === "start") records = sleeps.filter((r) => inRange(time(r.at)));
  if (q.domain === "sleep" && q.focus === "time" && q.subtype !== "wake") {
    records = records.filter((r) => inRange(time(r.at)));
  }
  if (q.target_id) records = records.filter((r) => r.id === q.target_id);
  records.sort(desc);
  const count = records.length;
  if (q.operation === "state") records = stateRecord ? [stateRecord] : [];
  else if (["latest", "duration", "elapsed", "first"].includes(q.operation)) {
    records = boundaryCandidates(records, q.operation === "first", c);
    if (records.length > 1) issues.push("ambiguous_order");
  }
  let evidence: QueryFacts["evidence"] = count ? "positive" : "unknown", value: number | undefined;
  if (q.domain === "feeding") {
    if (q.quantity !== "consumed") {
      issues.push("unknown_" + q.quantity);
      evidence = count ? "incomplete" : "unknown";
    } else if (records.some((r) => r.value === undefined)) {
      issues.push("missing_quantity");
      evidence = "incomplete";
    } else {value = q.operation === "total" || q.operation === "report"
        ? records.reduce((n, r) => n + Math.round((r.value ?? 0) * 100), 0) / 100
        : records[0]?.value;}
  } else if (q.domain === "weight") value = records[0]?.value;
  else if (q.domain === "sleep" && q.operation === "total") value = completed;
  if (q.operation === "elapsed" && records[0]?.at) value = (ref - time(records[0].at)) / 60000;
  if (q.operation === "duration" && records[0]) {
    if (records[0].end) value = (time(records[0].end) - time(records[0].at)) / 60000;
    else {
      value = undefined;
      evidence = "incomplete";
    }
  }
  if (q.operation === "state") {
    evidence = stale ? "stale" : sleepState === "unknown" ? "unknown" : "positive";
    if (q.subtype === "nap" && stateRecord && !nap(stateRecord)) {
      sleepState = "unknown";
      evidence = "unknown";
    }
  }
  if (
    (q.domain === "sleep" || q.domain === "care") && ["total", "duration", "report"].includes(q.operation) &&
    issues.some((i) => ["open_sleep", "inconsistent_sleep"].includes(i))
  ) evidence = "incomplete";
  if (q.domain === "care" && dayFeeds.length + dayDiapers.length + relevantSleep.length > 0 && evidence === "unknown") {
    evidence = "positive";
  }
  if (periodUnavailable || issues.includes("month_precision") || issues.includes("date_only_outside_day_query")) {
    evidence = "incomplete";
  }
  if (issues.includes("ambiguous_order")) {
    evidence = "incomplete";
    value = undefined;
  }
  return {
    version: 2,
    query: q,
    child_id: baby.id,
    child_name: baby.name,
    evidence,
    issues: [...new Set(issues)],
    records: periodUnavailable ? [] : records,
    count: periodUnavailable ? 0 : count,
    value: periodUnavailable ? undefined : value,
    completed_minutes: completed,
    open_minutes: open,
    wet_count: dayDiapers.filter((r) => r.diaper === "wet" || r.diaper === "mixed").length,
    dirty_count: dayDiapers.filter((r) => r.diaper === "dirty" || r.diaper === "mixed").length,
    diaper_count: dayDiapers.length,
    feeding_count: dayFeeds.length,
    feeding_ml: dayFeeds.reduce((n, r) => n + Math.round((r.value ?? 0) * 100), 0) / 100,
    sleep_state: sleepState,
    last_feeding: latestFeed,
    last_sleep: latestSleep,
  };
}
