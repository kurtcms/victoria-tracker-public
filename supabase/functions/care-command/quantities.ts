// Ground numeric extraction in the submitted words, independently of the model.
// Ambiguous or unsupported forms ask for clarification instead of guessing.
const small: Record<string, number> = {
  zero: 0,
  one: 1,
  two: 2,
  three: 3,
  four: 4,
  five: 5,
  six: 6,
  seven: 7,
  eight: 8,
  nine: 9,
  ten: 10,
  eleven: 11,
  twelve: 12,
  thirteen: 13,
  fourteen: 14,
  fifteen: 15,
  sixteen: 16,
  seventeen: 17,
  eighteen: 18,
  nineteen: 19,
};
const tens: Record<string, number> = {
  twenty: 20,
  thirty: 30,
  forty: 40,
  fifty: 50,
  sixty: 60,
  seventy: 70,
  eighty: 80,
  ninety: 90,
};
const words = [...Object.keys(small), ...Object.keys(tens), "a", "hundred", "thousand", "and", "point"];
export const mlUnit = "(?:millilitres?|milliliters?|mil|m[ .-]*ls?\\.?|em[ -]+el|毫升)";
const chineseDigits: Record<string, number> = {
  零: 0,
  〇: 0,
  一: 1,
  二: 2,
  兩: 2,
  两: 2,
  三: 3,
  四: 4,
  五: 5,
  六: 6,
  七: 7,
  八: 8,
  九: 9,
};
const chinesePattern = "[零〇一二兩两三四五六七八九十百千萬万廿卅點点]+";
function chineseNumber(text: string): number | undefined {
  const parts = text.replace(/^廿/, "二十").replace(/^卅/, "三十").split(/[點点]/);
  if (parts.length > 2) return undefined;
  const whole = parts[0];
  let result = 0;
  if (/^[零〇一二兩两三四五六七八九]+$/.test(whole)) {
    result = Number([...whole].map((c) => chineseDigits[c]).join(""));
  } else {
    let digit: number | undefined, previous = Infinity, zeroAfterMagnitude = false;
    for (const c of whole) {
      if (c in chineseDigits) {
        if (digit !== undefined && digit !== 0) return undefined;
        digit = chineseDigits[c];
        if (digit === 0) zeroAfterMagnitude = true;
      } else {
        const magnitude = ({ 十: 10, 百: 100, 千: 1000 } as Record<string, number>)[c];
        if (
          !magnitude || magnitude >= previous || digit === 0 || digit === undefined && !(c === "十" && result === 0)
        ) return undefined;
        result += (digit ?? 1) * magnitude;
        previous = magnitude;
        digit = undefined;
        zeroAfterMagnitude = false;
      }
    }
    // Cantonese 一百八 may mean 180; never silently interpret it as 108.
    if (digit !== undefined && digit !== 0 && previous > 10 && !zeroAfterMagnitude) return undefined;
    result += digit ?? 0;
  }
  if (parts.length === 1) return Number.isFinite(result) ? result : undefined;
  if (!parts[1] || [...parts[1]].some((c) => !(c in chineseDigits))) return undefined;
  return Number(String(result) + "." + [...parts[1]].map((c) => chineseDigits[c]).join(""));
}
function under100(tokens: string[]): number | undefined {
  if (tokens.length === 1) return small[tokens[0]] ?? tens[tokens[0]];
  if (tokens.length === 2 && tens[tokens[0]] !== undefined && small[tokens[1]] >= 1 && small[tokens[1]] <= 9) {
    return tens[tokens[0]] + small[tokens[1]];
  }
  return undefined;
}
function under1000(tokens: string[]): number | undefined {
  const i = tokens.indexOf("hundred");
  if (i < 0) return under100(tokens);
  const head = tokens[0] === "a" ? 1 : small[tokens[0]];
  if (i !== 1 || head === undefined || head < 1 || head > 9) return undefined;
  let tail = tokens.slice(2);
  if (tail[0] === "and") tail = tail.slice(1);
  const remainder = tail.length ? under100(tail) : 0;
  return remainder === undefined ? undefined : head * 100 + remainder;
}
function integer(tokens: string[]): number | undefined {
  const i = tokens.indexOf("thousand");
  if (i < 0) return under1000(tokens);
  if (tokens.lastIndexOf("thousand") !== i) return undefined;
  const head = under1000(tokens.slice(0, i));
  let tail = tokens.slice(i + 1);
  if (tail[0] === "and") tail = tail.slice(1);
  const remainder = tail.length ? under1000(tail) : 0;
  return head === undefined || head < 1 || remainder === undefined ? undefined : head * 1000 + remainder;
}
export function spokenNumber(text: string): number | undefined {
  text = text.normalize("NFKC").trim();
  if (new RegExp("^" + chinesePattern + "$", "u").test(text)) return chineseNumber(text);
  if (/^(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?$/.test(text)) return Number(text.replaceAll(",", ""));
  const tokens = text.toLowerCase().trim().split(/[\s-]+/);
  const point = tokens.indexOf("point");
  if (point < 0) return integer(tokens);
  if (point !== tokens.lastIndexOf("point")) return undefined;
  const whole = point === 0 ? 0 : integer(tokens.slice(0, point));
  const fraction = tokens.slice(point + 1);
  if (whole === undefined || !fraction.length || fraction.some((t) => small[t] === undefined || small[t] > 9)) {
    return undefined;
  }
  return Number(String(whole) + "." + fraction.map((t) => small[t]).join(""));
}
export function quantityMentions(text: string, unit: "ml" | "kg"): number[] {
  if (/\b(?:minus|negative|subtract)\b|負|负/i.test(text)) return [];
  const token = "(?:" + words.join("|") + ")";
  const number = "(?:(?:\\d{1,3}(?:,\\d{3})+|\\d+)(?:\\.\\d+)?|" + chinesePattern + "|" + token + "(?:[ -]+" + token +
    ")*)";
  const suffix = unit === "ml" ? mlUnit : "(?:kilograms?|kg|公斤|千克)";
  // CJK words have no spaces; retain Latin word boundaries for milk/million.
  const pattern = new RegExp(
    "(?<![\\p{Script=Latin}\\p{N}零〇一二兩两三四五六七八九十百千萬万廿卅點点.,+\\-])(" + number + ")\\s*" + suffix +
      "(?![\\p{Script=Latin}\\p{N}_])",
    "giu",
  );
  const values: number[] = [];
  for (const match of text.normalize("NFKC").matchAll(pattern)) {
    const n = spokenNumber(match[1]);
    if (n !== undefined && Number.isFinite(n)) values.push(n);
  }
  return values;
}
export function quantities(text: string, unit: "ml" | "kg"): number[] {
  return [...new Set(quantityMentions(text, unit))];
}
export function amountIsGrounded(text: string, unit: "ml" | "kg", value: unknown): boolean {
  const values = quantities(text, unit);
  return typeof value === "number" && values.length === 1 && Math.abs(values[0] - value) < 1e-7;
}
export function describesLeftover(text: string): boolean {
  if (/剩(?:返|低|餘|余)?|餘下|余下|未飲完|未喝完/i.test(text)) return true;
  if (/\b(?:leftover|remaining|remained|remains|unfinished)\b/i.test(text)) return true;
  const token = "(?:" + words.join("|") + ")";
  const number = "(?:(?:\\d{1,3}(?:,\\d{3})+|\\d+)(?:\\.\\d+)?|" + token + "(?:[ -]+" + token + ")*)";
  const unit = mlUnit;
  return new RegExp("\\bleft\\s+" + number + "\\s*" + unit + "\\b", "i").test(text) ||
    new RegExp(unit + "\\s+(?:(?:was|were|is|are|still)\\s+)*left\\b", "i").test(text) ||
    /\bleft\s+(?:over|(?:in\s+)?(?:the\s+)?bottle|(?:some\s+)?milk)\b/i.test(text);
}
