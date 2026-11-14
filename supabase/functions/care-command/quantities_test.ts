import { amountIsGrounded, describesLeftover, quantities, spokenNumber } from "./quantities.ts";
import { assert, babies, command, equal, extracted, now } from "./test_helpers.ts";
import { interpret, parse } from "./domain.ts";
Deno.test("English quantities distinguish twenty from two hundred and support decimal weights", () => {
  for (
    const [words, value] of [
      ["twenty", 20],
      ["two hundred", 200],
      ["one hundred and eighty", 180],
      ["twenty-five", 25],
      ["seven point five", 7.5],
      ["zero", 0],
      ["one thousand two hundred", 1200],
    ] as const
  ) equal(spokenNumber(words), value);
  equal(quantities("Victoria left twenty millilitres.", "ml"), [20]);
  equal(quantities("Victoria left 200mL.", "ml"), [200]);
  equal(quantities("She weighs seven point five kilograms.", "kg"), [7.5]);
  assert(amountIsGrounded("She drank 180 mL fifteen minutes ago.", "ml", 180));
  assert(!amountIsGrounded("She left 20 mL.", "ml", 200));
  assert(!amountIsGrounded("She left twenty millilitres.", "ml", 200));
  assert(!amountIsGrounded("A 200 mL bottle had 20 mL left.", "ml", 200));
  equal(spokenNumber("twenty twenty"), undefined);
  equal(quantities("She left negative twenty millilitres.", "ml"), []);
  equal(quantities("She left -20 mL.", "ml"), []);
  assert(describesLeftover("Victoria had twenty millilitres still left in the bottle."));
  assert(!describesLeftover("Victoria drank 180 mL after we left daycare."));
});
Deno.test("model quantity substitution cannot reach a correction proposal", () => {
  for (
    const text of [
      "Victoria left 20 millilitres from her last bottle.",
      "Victoria left twenty millilitres from her last bottle.",
    ]
  ) {
    for (const value of [0, 200]) {
      const r = interpret(
        extracted({
          action: "feeding_correction",
          volume_ml: null,
          time_kind: null,
          correction_kind: "leftover",
          correction_ml: value,
        }),
        babies,
        parse({ ...command, text }, now),
        now,
      );
      assert("status" in r);
      equal(r.status, "needs_clarification");
      assert(r.message.includes("Nothing changed"));
    }
  }
});
Deno.test("grounded leftover and corrected total stay distinct, with wrong action kinds blocked", () => {
  const text = "Victoria left twenty millilitres from her last bottle.";
  const c = parse({ ...command, text }, now);
  const data = extracted({
    action: "feeding_correction",
    volume_ml: null,
    time_kind: null,
    correction_kind: "leftover",
    correction_ml: 20,
  });
  const good = interpret(data, babies, c, now);
  assert("action" in good);
  equal(good.payload.amount_ml, 20);
  const wrong = interpret({ ...data, correction_kind: "total" }, babies, c, now);
  assert("status" in wrong);
  equal(wrong.status, "needs_clarification");
  const creation = interpret(extracted({ volume_ml: 20 }), babies, c, now);
  assert("status" in creation);
  equal(creation.status, "needs_clarification");
  const zero = interpret(
    { ...data, correction_kind: "total", correction_ml: 0 },
    babies,
    parse({ ...command, text: "Correct Victoria’s last feeding to zero millilitres." }, now),
    now,
  );
  assert("action" in zero);
  equal(zero.payload.amount_ml, 0);
});
Deno.test("feeding and weight extraction must use the stated quantity and unit", () => {
  for (
    const [text, action, value] of [["Victoria drank 180 mL.", "feeding", 200], [
      "Victoria weighs 7.5 kg.",
      "weight",
      75,
    ]] as const
  ) {
    const r = interpret(
      extracted({
        action,
        volume_ml: action === "feeding" ? value : null,
        weight_kg: action === "weight" ? value : null,
      }),
      babies,
      parse({ ...command, text }, now),
      now,
    );
    assert("status" in r);
    equal(r.status, "needs_clarification");
  }
});

Deno.test("mL abbreviations and spoken letters preserve milk and leftover quantities", () => {
  for (const unit of ["ml", "mL", "ML", "m l", "M L", "m.l.", "m-l", "em el", "mLs"]) {
    const text = `Victoria drank 180 ${unit}.`;
    equal(quantities(text, "ml"), [180]);
    const result = interpret(extracted(), babies, parse({ ...command, text }, now), now);
    assert("action" in result);
    equal(result.payload.volume_ml, 180);
    const leftover = `Victoria left 20 ${unit} in the bottle.`;
    assert(describesLeftover(leftover));
    assert(amountIsGrounded(leftover, "ml", 20));
    assert(!amountIsGrounded(leftover, "ml", 200));
  }
  for (const text of ["Victoria drank 180 milk.", "Victoria drank 180 mlong.", "Victoria drank 180 litres."]) {
    equal(quantities(text, "ml"), []);
  }
});
