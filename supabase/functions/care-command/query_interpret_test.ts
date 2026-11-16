import { interpretReadQuery } from "./query_interpret.ts";
import { assert, command, equal } from "./test_helpers.ts";
import { parse } from "./domain.ts";
const c = parse(command, new Date(command.reference_at));
Deno.test("compositional read queries preserve domain, operation and subtype across languages", () => {
  for (
    const [text, domain, operation, subtype] of [
      ["Is she sleeping?", "sleep", "state", "all"],
      ["Is she up?", "sleep", "state", "wake"],
      ["Is she napping?", "sleep", "state", "nap"],
      ["Has she slept?", "sleep", "exists", "all"],
      ["Has she napped?", "sleep", "exists", "nap"],
      ["Has she had a wet diaper?", "diaper", "exists", "wet"],
      ["Has she had a number one?", "diaper", "exists", "wet"],
      ["Has she peed?", "diaper", "exists", "wet"],
      ["Has she had a number two?", "diaper", "exists", "dirty"],
      ["Has she pooped?", "diaper", "exists", "dirty"],
      ["When was her last pee?", "diaper", "latest", "wet"],
      ["When was her last poop?", "diaper", "latest", "dirty"],
      ["When was her last dirty diaper?", "diaper", "latest", "dirty"],
      ["When did Victoria last eat?", "feeding", "latest", "all"],
      ["How much has she drunk today?", "feeding", "total", "all"],
      ["How long since she last ate?", "feeding", "elapsed", "all"],
      ["How long was her last nap?", "sleep", "duration", "nap"],
      ["How many diaper changes today?", "diaper", "count", "all"],
      ["佢瞓緊覺嗎？", "sleep", "state", "all"],
      ["佢起身未？", "sleep", "state", "wake"],
      ["今日有冇濕尿片？", "diaper", "exists", "wet"],
      ["佢有冇屙尿？", "diaper", "exists", "wet"],
      ["Victoria last poop係幾時？", "diaper", "latest", "dirty"],
      ["今日飲咗幾多奶？", "feeding", "total", "all"],
      ["How much does she weigh?", "weight", "latest", "all"],
      ["What milestones today?", "milestone", "report", "all"],
    ]
  ) {
    const q = interpretReadQuery(text, c);
    assert(q, text);
    equal([q.domain, q.operation, q.subtype], [domain, operation, subtype]);
  }
});
Deno.test("query windows are deterministic and unsupported/compound references clarify", () => {
  for (
    const [text, day, period, minutes] of [
      ["How much milk yesterday?", "2026-11-12", "day", null],
      ["How much milk this morning?", "2026-11-13", "morning", null],
      ["How much milk in the last three hours?", null, "rolling", 180],
      ["How much milk last Monday?", "2026-11-09", "day", null],
      ["How much milk on November 1?", "2026-11-01", "day", null],
      ["今日幾多濕尿片？", "2026-11-13", "day", null],
      ["How many wet diapers since her last feeding?", null, "since_feeding", null],
    ] as const
  ) {
    const q = interpretReadQuery(text, c);
    assert(q, text);
    equal([q.day, q.period, q.minutes], [day, period, minutes]);
  }
  for (
    const text of [
      "How much milk tomorrow?",
      "How much milk last week?",
      "How much milk yesterday and today?",
      "Has she peed and log a feed?",
      "She drank 80 ml.",
      "If she sleeps, record it",
      "How much milk before her second nap?",
    ]
  ) {
    equal(interpretReadQuery(text, c), undefined);
  }
});
Deno.test("totals and counts cannot collapse into existence or latest; contextual unsupported domains clarify", () => {
  for (
    const [text, operation] of [
      ["How much milk in the last two hours?", "total"],
      ["How many times has she fed today?", "count"],
      ["How many naps today?", "count"],
      ["今日飲咗幾多次奶？", "count"],
    ] as const
  ) {
    const q = interpretReadQuery(text, c);
    assert(q, text);
    equal(q.operation, operation);
  }
  for (
    const text of [
      "How much milk today? Victoria drank 80 mL just now.",
      "How much medicine did she have?",
      "What is her temperature?",
      "When was she born?",
    ]
  ) equal(interpretReadQuery(text, c, "feeding"), undefined);
});
Deno.test("specific milestone subjects remain grounded while generic milestone reads stay generic", () => {
  for (
    const [text, topic] of [
      ["When did she first wave hello?", "wave hello"],
      ["Did she smile today?", "smile"],
      ["佢第一次揮手係幾時？", "揮手"],
      ["今日有冇笑？", "笑"],
      ["Victoria幾時first wave hello？", "wave hello"],
    ] as const
  ) {
    const q = interpretReadQuery(text, c);
    assert(q, text);
    equal(q.domain, "milestone");
    equal(q.topic, topic);
  }
  equal(interpretReadQuery("When did she first clap?", c)?.topic, "clap");
  equal(interpretReadQuery("What milestones today?", c)?.topic, undefined);
});
Deno.test("exact presentation never authorizes unsupported windows; weekday dates remain supported", () => {
  for (
    const text of [
      "How much milk last week, exact date please?",
      "How much milk next month with year?",
      "How much milk tomorrow, full date?",
      "How much milk last year?",
    ]
  ) equal(interpretReadQuery(text, c), undefined);
  assert(interpretReadQuery("What was her last weight, include the year?", c)?.exact);
  equal(interpretReadQuery("上星期一飲咗幾多奶？", c)?.day, "2026-11-09");
  equal(interpretReadQuery("上個星期一飲咗幾多奶？", c)?.day, "2026-11-09");
});
Deno.test("relative nap anchors retain daytime subtype in English and Cantonese", () => {
  for (
    const text of [
      "How much milk after her nap?",
      "How much milk before her nap?",
      "午睡之後飲咗幾多奶？",
      "午睡之前飲咗幾多奶？",
    ]
  ) {
    const q = interpretReadQuery(text, c);
    assert(q, text);
    equal(q.anchor_subtype, "nap");
  }
});
Deno.test("unsupported milestone subject modifiers clarify rather than broaden to all milestones", () => {
  for (
    const text of [
      "What was her first milestone about clapping?",
      "When was her clapping milestone?",
      "What was her first milestone of sitting?",
    ]
  ) equal(interpretReadQuery(text, c), undefined);
});

Deno.test("first milestone subjects preserve arbitrary contiguous words without semantic guessing", () => {
  for (
    const [text, topic] of [["When did she first say papa?", "say papa"], ["佢第一次講爸爸係幾時？", "講爸爸"], [
      "When did she first wave goodbye?",
      "wave goodbye",
    ]] as const
  ) {
    const q = interpretReadQuery(text, c);
    assert(q, text);
    equal(q.topic, topic);
  }
});
Deno.test("awake and asleep elapsed time is distinct from completed sleep; unsupported scopes never broaden", () => {
  for (
    const [text, subtype] of [["How long has she been awake?", "wake"], [
      "How long has she been asleep?",
      "start",
    ]] as const
  ) {
    const q = interpretReadQuery(text, c);
    assert(q);
    equal(q.operation, "elapsed");
    equal(q.subtype, subtype);
  }
  equal(interpretReadQuery("How much milk this evening?", c)?.period, "tonight");
  for (
    const text of [
      "How many wet diapers last night?",
      "How much milk since her first feeding?",
      "How long since feeding at 8?",
      "How much milk recently?",
    ]
  ) equal(interpretReadQuery(text, c), undefined);
});
Deno.test("abbreviated and missing date anchors cannot default silently to today", () => {
  equal(interpretReadQuery("How much milk the last three hours?", c)?.minutes, 180);
  equal(interpretReadQuery("How much milk past two hours?", c)?.period, "rolling");
  for (const text of ["How much milk on November?", "How much milk on 11/1?", "How much milk three hours ago?"]) {
    equal(interpretReadQuery(text, c), undefined);
  }
});
Deno.test("latest feeding can project timing and amount in either conversational order without accepting mixed actions", () => {
  for (const text of ["When and how much was Victoria’s last feeding?", "How much and when did Victoria last eat?"]) {
    const q = interpretReadQuery(text, c);
    assert(q, text);
    equal(q.operation, "latest");
    equal(q.domain, "feeding");
    equal(q.focus, undefined);
  }
  equal(interpretReadQuery("When and how much was Victoria’s last feeding and log 80 ml?", c), undefined);
});
Deno.test("explicit metric unit requests carry presentation overrides just like US units", () => {
  for (
    const [text, unit] of [["How many mL has she drunk today?", "ml"], ["How much milk in millilitres today?", "ml"], [
      "What is her last weight in kg?",
      "kg",
    ], ["佢最近體重幾多公斤？", "kg"]] as const
  ) {
    const q = interpretReadQuery(text, c);
    assert(q, text);
    equal(q.unit, unit);
  }
});
