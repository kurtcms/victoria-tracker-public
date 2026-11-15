import { detectLanguage, localizeResponse } from "./language.ts";
import { assert, child, equal } from "./test_helpers.ts";

Deno.test("Cantonese answers use deterministic recorded facts and cannot claim persistence", () => {
  const result = localizeResponse({
    status: "answered",
    child_id: child,
    message: "English answer",
    details: {
      kind: "answer",
      query_kind: "day_summary",
      child_name: "Victoria",
      day: "2026-11-13",
      has_records: true,
      feeding_count: 3,
      feeding_ml: 360,
      wet_count: 4,
      dirty_count: 2,
      sleep_minutes: 95,
    },
  }, "yue");
  equal(result.status, "answered");
  equal(result.language, "yue");
  for (const text of ["Victoria", "2026-11-13", "360", "3", "4", "2", "95"]) {
    assert(String(result.message).includes(text));
  }
  assert(!/已記錄|已儲存|saved|recorded/i.test(String(result.message)));
  const empty = localizeResponse({
    status: "answered",
    details: { kind: "answer", query_kind: "last_feeding", child_name: "Victoria", has_records: false },
  }, "yue");
  assert(String(empty.message).includes("未有"));
  assert(!String(empty.message).includes("0"));
});

Deno.test("last and count answers include only supplied finite values with their meaning", () => {
  for (
    const [kind, patch, words] of [
      ["last_feeding", { value: 80, unit: "mL", display_time: "2026-11-13 12:30" }, ["80", "毫升", "2026-11-13 12:30"]],
      ["wet_count", { wet_count: 4, day: "2026-11-13" }, ["濕", "4", "2026-11-13"]],
      ["dirty_count", { dirty_count: 2, day: "2026-11-13" }, ["大便", "2"]],
      ["has_dirty", { dirty_count: 0, day: "2026-11-13" }, ["未有", "大便"]],
      ["sleep_total", { sleep_minutes: 95 }, ["95", "分鐘"]],
      ["last_weight", { value: 7.5, unit: "kg", measurement_date: "2026-11-12" }, ["7.5", "公斤", "2026-11-12"]],
      ["last_diaper", { diaper_kind: "mixed", display_time: "2026-11-13 12:30" }, ["濕", "大便", "2026-11-13 12:30"]],
      ["last_milestone", { title: "Waved hello", occurred_on: "2026-11-01", date_precision: "day" }, [
        "Waved hello",
        "2026-11-01",
      ]],
    ] as const
  ) {
    const result = localizeResponse({
      status: "answered",
      details: { kind: "answer", query_kind: kind, child_name: "Victoria", has_records: true, ...patch },
    }, "yue");
    for (const word of words) assert(String(result.message).includes(word), JSON.stringify(result));
  }
  const invalid = localizeResponse({
    status: "answered",
    details: { kind: "answer", query_kind: "wet_count", child_name: "Victoria", has_records: true, wet_count: "999" },
  }, "yue");
  assert(!String(invalid.message).includes("999"));
});

Deno.test("proposal wording preserves before/after and explicit confirmation without implying a save", () => {
  const result = localizeResponse({
    status: "needs_confirmation",
    proposal_id: child,
    details: {
      kind: "proposal",
      child_name: "Victoria",
      action: "change",
      record_kind: "feeding",
      recorded_at: "2026-11-13 12:30",
      old_value: 30,
      new_value: 80,
      unit: "mL",
    },
  }, "yue");
  for (const text of ["30", "80", "毫升", "確認", "2026-11-13 12:30"]) assert(String(result.message).includes(text));
  assert(!String(result.message).includes("已更新"));
  equal(result.proposal_id, child);
  const deletion = localizeResponse({
    status: "needs_confirmation",
    details: {
      kind: "proposal",
      child_name: "Victoria",
      action: "delete",
      record_kind: "diaper",
      recorded_at: "2026-11-13 12:30",
      old_label: "wet",
    },
  }, "yue");
  for (const text of ["刪除", "確認", "濕"]) assert(String(deletion.message).includes(text));
});

Deno.test("persistence and cancellation stay distinct and English server messages remain verbatim", () => {
  for (
    const [status, kind, phrase] of [["recorded", "batch", "2"], ["recorded", "changed", "已更新"], [
      "recorded",
      "deleted",
      "已刪除",
    ], ["cancelled", "cancelled", "取消"]]
  ) {
    const result = localizeResponse(
      { status, event_id: child, details: { kind, child_name: "Victoria", count: 2 } },
      "yue",
    );
    assert(String(result.message).includes(phrase));
    equal(result.event_id, child);
  }
  const original = { status: "answered", message: "Victoria has 4 wet diapers today.", details: { kind: "answer" } };
  equal(localizeResponse(original, "en"), { ...original, language: "en" });
  equal(detectLanguage("Victoria drank 80 mil."), "en");
  equal(detectLanguage("Victoria飲咗80 mil"), "yue");
});

Deno.test("actual RPC dates use local clocks, weight dates and milestone month precision", () => {
  for (
    const [kind, facts, expected, unwanted] of [
      [
        "last_feeding",
        { value: 180, display_time: "2026-11-13 19:30", occurred_at: "2026-11-14T03:30:00Z" },
        "2026-11-13 19:30",
        "03:30",
      ],
      [
        "last_weight",
        { value: 7.1, measurement_date: "2026-11-10", occurred_at: "2026-11-12T00:00:00Z" },
        "2026-11-10",
        "2026-11-12",
      ],
      [
        "last_milestone",
        { title: "Learned to sit", occurred_on: "2026-07-01", date_precision: "month" },
        "2026-07",
        "2026-07-01",
      ],
    ] as const
  ) {
    const response = localizeResponse({
      status: "answered",
      details: { kind: "answer", query_kind: kind, child_name: "Ava", has_records: true, ...facts },
    }, "yue");
    assert(String(response.message).includes(expected));
    assert(!String(response.message).includes(unwanted));
  }
});
Deno.test("Cantonese replay and future errors preserve their distinct safe meaning", () => {
  const replay = localizeResponse({
    status: "recorded",
    replayed: true,
    details: { kind: "changed", child_name: "Ava", record_kind: "feeding", value: 80 },
  }, "yue");
  assert(String(replay.message).includes("之前"));
  assert(!String(replay.message).includes("80"));
  const future = localizeResponse(
    { status: "rejected", code: "future_event", message: "Cannot log future events." },
    "yue",
  );
  assert(String(future.message).includes("未來"));
});

Deno.test("Cantonese saved sleep and milestone confirmations retain units and observed words", () => {
  const sleep = localizeResponse({
    status: "recorded",
    details: {
      kind: "recorded",
      child_name: "Ava",
      record_kind: "sleep",
      value: 30,
      unit: "minutes",
      sleep_running: false,
    },
  }, "yue");
  assert(String(sleep.message).includes("30分鐘"));
  const milestone = localizeResponse({
    status: "recorded",
    details: { kind: "recorded", child_name: "Ava", record_kind: "milestone", title: "第一次識得坐" },
  }, "yue");
  assert(String(milestone.message).includes("第一次識得坐"));
});

Deno.test("successful deletions name the baby and record in plain English", () => {
  for (
    const [record_kind, diaper_kind, expected] of [
      ["diaper", "wet", "wet diaper"],
      ["diaper", "dirty", "dirty diaper"],
      ["diaper", "mixed", "wet and dirty diaper"],
      ["diaper", null, "diaper"],
      ["feeding", null, "feeding"],
      ["weight", null, "weight"],
      ["sleep", null, "sleep"],
      ["milestone", null, "milestone"],
    ]
  ) {
    const result = localizeResponse({
      status: "recorded",
      event_id: child,
      message: "Removed the record for Victoria from totals.",
      details: { kind: "deleted", child_name: "Victoria", record_kind, diaper_kind },
    }, "en");
    equal(result.message, `Deleted Victoria’s ${expected} record.`);
    equal(result.event_id, child);
  }
});
Deno.test("deletion copy never turns a proposal, cancellation, failure or replay into a fresh success", () => {
  for (
    const patch of [
      { status: "needs_confirmation" },
      { status: "cancelled" },
      { status: "rejected" },
      { status: "recorded", replayed: true },
      { status: "recorded", already_recorded: true },
    ]
  ) {
    const original = {
      message: "Original safe response",
      details: { kind: "deleted", child_name: "Victoria", record_kind: "diaper", diaper_kind: "wet" },
      ...patch,
    };
    equal(localizeResponse(original, "en").message, original.message);
  }
});

Deno.test("sleep answers and care reports use supplied facts in English and Cantonese", () => {
  for (const language of ["en", "yue"] as const) {
    for (const query_kind of ["last_sleep_start", "last_sleep_end"]) {
      const result = localizeResponse({
        status: "answered",
        message: "placeholder",
        details: {
          kind: "answer",
          query_kind,
          child_name: "Victoria",
          has_records: true,
          display_time: "2026-11-15 01:00",
        },
      }, language);
      assert(String(result.message).includes("2026-11-15 01:00"));
      assert(
        String(result.message).includes(
          language === "en"
            ? query_kind === "last_sleep_start" ? "fell asleep" : "woke up"
            : query_kind === "last_sleep_start"
            ? "瞓著"
            : "醒",
        ),
      );
    }
    const report = localizeResponse({
      status: "answered",
      message: "placeholder",
      details: {
        kind: "answer",
        query_kind: "care_report",
        child_name: "Victoria",
        has_records: true,
        day: "2026-11-15",
        feeding_ml: 230,
        feeding_count: 2,
        wet_count: 3,
        dirty_count: 1,
        sleep_minutes: 125,
        last_feeding_ml: 80,
        last_feeding_display_time: "2026-11-15 01:10",
        sleep_running: true,
        sleep_display_time: "2026-11-15 01:20",
        sleep_status_display_time: "2026-11-15 01:30",
      },
    }, language);
    for (
      const fact of [
        "230",
        "3",
        "1",
        "125",
        "80",
        ...(language === "en" ? ["1:10 AM", "1:20 AM", "1:30 AM"] : ["01:10", "01:20", "01:30"]),
      ]
    ) {
      assert(String(report.message).includes(fact));
    }
    assert(!String(report.message).includes("placeholder"));
    const missing = localizeResponse({
      status: "answered",
      message: "placeholder",
      details: { kind: "answer", query_kind: "last_sleep_end", child_name: "Victoria", has_records: false },
    }, language);
    assert(!String(missing.message).includes("placeholder"));
  }
});

Deno.test("milk totals are concise, preserve meaningful decimals and never invent missing amounts", () => {
  for (const [amount, expected] of [[150, "150"], [150.5, "150.5"], [0, "0"]]) {
    for (const language of ["en", "yue"] as const) {
      const result = localizeResponse({
        status: "answered",
        details: {
          kind: "answer",
          query_kind: "milk_total",
          child_name: "Victoria",
          has_records: true,
          feeding_ml: amount,
          day: "2026-11-15",
        },
      }, language);
      assert(String(result.message).includes(String(expected)));
      assert(!/diaper|sleep|尿片|睡眠|瞓/iu.test(String(result.message)));
    }
  }
  const result = localizeResponse({
    status: "answered",
    details: { kind: "answer", query_kind: "milk_total", child_name: "Victoria", has_records: true, feeding_ml: null },
  }, "en");
  assert(!String(result.message).includes("0 millilitres"));
});

Deno.test("care reports use time-only details within their day and retain earlier dates", () => {
  for (const language of ["en", "yue"] as const) {
    const facts = {
      kind: "answer",
      query_kind: "care_report",
      child_name: "Victoria",
      has_records: true,
      day: "2026-11-15",
      feeding_ml: 150,
      wet_count: 0,
      dirty_count: 0,
      sleep_minutes: 20,
      last_feeding_ml: 50,
      last_feeding_display_time: "2026-11-15 02:25",
      sleep_running: true,
      sleep_display_time: "2026-11-15 03:10",
      sleep_status_display_time: "2026-11-15 03:30",
    };
    const today = String(localizeResponse({ status: "answered", details: facts }, language).message);
    equal((today.match(/2026-11-15/g) ?? []).length, 1);
    assert(today.includes(language === "en" ? "50 millilitres at 2:25 AM" : "50毫升（02:25）"));
    assert(today.includes(language === "en" ? "sleeping since 3:10 AM" : "03:10"));
    const earlier = String(
      localizeResponse({
        status: "answered",
        details: { ...facts, last_feeding_display_time: "2026-11-14 23:50", sleep_display_time: "2026-11-14 23:55" },
      }, language).message,
    );
    equal((earlier.match(/2026-11-14/g) ?? []).length, 2);
  }
});
Deno.test("report clocks distinguish noon and midnight without changing source facts", () => {
  for (const [clock, spoken] of [["00:00", "12:00 AM"], ["12:00", "12:00 PM"], ["23:59", "11:59 PM"]]) {
    const details = {
      kind: "answer",
      query_kind: "care_report",
      child_name: "Victoria",
      has_records: true,
      day: "2026-11-15",
      feeding_ml: 50,
      wet_count: 0,
      dirty_count: 0,
      sleep_minutes: 0,
      last_feeding_ml: 50,
      last_feeding_display_time: `2026-11-15 ${clock}`,
      sleep_running: false,
    };
    const response = localizeResponse({ status: "answered", details }, "en");
    assert(String(response.message).includes(`at ${spoken}.`));
    equal(response.details, details);
  }
});
