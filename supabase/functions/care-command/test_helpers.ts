export { assert, equal, throws } from "../record-event/test_helpers.ts";
import { schema } from "./domain.ts";
export const now = new Date("2026-11-13T20:00:00.000Z");
export const child = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
export const second = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
export const parent = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
export const command = {
  request_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
  reference_at: now.toISOString(),
  time_zone: "America/Vancouver",
  utc_offset_seconds: -25200,
  zone_offsets: [{ from: "2025-11-12T20:00:00.000Z", seconds: -25200 }],
  source: "siri",
  mode: "text",
  text: "Victoria drank 180 millilitres.",
};
export const babies = [{ id: child, name: "Victoria" }, { id: second, name: "Oliver" }];
export function extracted(patch: Record<string, unknown> = {}) {
  return {
    ...Object.fromEntries(schema.required.map((k) => [k, null])),
    decision: "record",
    action: "feeding",
    child_name: "Victoria",
    volume_ml: 180,
    time_kind: "now",
    ...patch,
  };
}
