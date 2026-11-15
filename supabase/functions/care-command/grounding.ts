// Conservative checks against the text Siri submitted, not the original audio.
// These do not repair speech-recognition mistakes or replace interpretation.
const months = [
  ["january", "jan"],
  ["february", "feb"],
  ["march", "mar"],
  ["april", "apr"],
  ["may"],
  ["june", "jun"],
  ["july", "jul"],
  ["august", "aug"],
  ["september", "sept", "sep"],
  ["october", "oct"],
  ["november", "nov"],
  ["december", "dec"],
];
const ordinals = [
  "first",
  "second",
  "third",
  "fourth",
  "fifth",
  "sixth",
  "seventh",
  "eighth",
  "ninth",
  "tenth",
  "eleventh",
  "twelfth",
  "thirteenth",
  "fourteenth",
  "fifteenth",
  "sixteenth",
  "seventeenth",
  "eighteenth",
  "nineteenth",
  "twentieth",
  "twenty first",
  "twenty second",
  "twenty third",
  "twenty fourth",
  "twenty fifth",
  "twenty sixth",
  "twenty seventh",
  "twenty eighth",
  "twenty ninth",
  "thirtieth",
  "thirty first",
];
const monthPattern = "(?:" + months.flat().sort((a, b) => b.length - a.length).join("|") + ")\\.?";
const dayPattern = "(?:\\d{1,2}(?:st|nd|rd|th)?|" +
  [...ordinals].sort((a, b) => b.length - a.length).map((s) => s.replaceAll(" ", "[ -]")).join("|") + ")";
const yearPattern = "(?:(?:\\s*,\\s*|\\s+)(\\d{4})\\b)?";

// Guard common explicit English/ISO day dates. Other forms (e.g. yesterday,
// month-only memories) retain the existing strict interpretation/validation.
export function statedDates(text: string, referenceDate: string): string[] {
  const values = new Set<string>();
  const add = (month: string, day: string, year: string | undefined) => {
    const m = months.findIndex((names) => names.includes(month.toLowerCase().replace(/\.$/, ""))) + 1;
    const normalized = day.toLowerCase().replaceAll("-", " ");
    const d = /^\d/.test(day) ? parseInt(day, 10) : ordinals.indexOf(normalized) + 1;
    values.add(`${year ?? referenceDate.slice(0, 4)}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`);
  };
  for (
    const match of text.matchAll(
      new RegExp("\\b(" + monthPattern + ")\\s+(" + dayPattern + ")\\b" + yearPattern, "giu"),
    )
  ) {
    add(match[1], match[2], match[3]);
  }
  for (
    const match of text.matchAll(
      new RegExp("\\b(" + dayPattern + ")\\s+(?:of\\s+)?(" + monthPattern + ")" + yearPattern, "giu"),
    )
  ) {
    add(match[2], match[1], match[3]);
  }
  for (const match of text.matchAll(/\b\d{4}-\d{2}-\d{2}\b/g)) values.add(match[0]);
  for (
    const match of text.matchAll(
      /(?:(\d{4})年)?([零〇一二兩两三四五六七八九十廿卅\d]{1,3})月([零〇一二兩两三四五六七八九十廿卅\d]{1,3})(?:日|號|号)/gu,
    )
  ) {
    const number = (s: string): number => {
      if (/^\d+$/.test(s)) return Number(s);
      const digits: Record<string, number> = {
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
      s = s.replace(/^廿/, "二十").replace(/^卅/, "三十");
      if (s.includes("十")) {
        const [a, b] = s.split("十");
        return (a ? digits[a] : 1) * 10 + (b ? digits[b] : 0);
      }
      return digits[s] ?? NaN;
    };
    values.add(
      `${match[1] ?? referenceDate.slice(0, 4)}-${String(number(match[2])).padStart(2, "0")}-${
        String(number(match[3])).padStart(2, "0")
      }`,
    );
  }
  return [...values];
}
export function dateIsGrounded(text: string, date: string, referenceDate: string): boolean {
  const dates = statedDates(text, referenceDate);
  return dates.length === 0 || dates.length === 1 && dates[0] === date;
}
const words = (text: string): string[] => text.normalize("NFC").toLocaleLowerCase("en").match(/[\p{L}\p{N}]+/gu) ?? [];
export function phraseIsGrounded(text: string, phrase: unknown, title = false): boolean {
  if (typeof phrase !== "string") return false;
  if (/\p{Script=Han}/u.test(phrase)) {
    const compact = (value: string) => value.normalize("NFC").toLocaleLowerCase("en").replace(/[\p{P}\p{Z}\s]/gu, "");
    const candidate = compact(phrase);
    return candidate.length > 0 && compact(text).includes(candidate);
  }
  const source = words(text), candidate = words(phrase);
  // The optional title label "First" may move from "for the first time".
  if (title && candidate[0] === "first") {
    if (!source.includes("first")) return false;
    candidate.shift();
  }
  return candidate.length > 0 && source.some((_, i) => candidate.every((word, j) => source[i + j] === word));
}
