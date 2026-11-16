import type { RequestCommand } from "./domain.ts";
export type QueryDomain = "feeding" | "diaper" | "sleep" | "weight" | "milestone" | "care";
export type QueryOperation =
  | "latest"
  | "first"
  | "exists"
  | "count"
  | "total"
  | "state"
  | "elapsed"
  | "duration"
  | "report";
export type QuerySpec = {
  domain: QueryDomain;
  operation: QueryOperation;
  subtype: "all" | "wet" | "dirty" | "nap" | "wake" | "start";
  quantity: "consumed" | "offered" | "remaining";
  day: string | null;
  period:
    | "day"
    | "morning"
    | "afternoon"
    | "tonight"
    | "rolling"
    | "since_feeding"
    | "before_sleep"
    | "after_sleep"
    | "all";
  minutes: number | null;
  detailed: boolean;
  exact: boolean;
  target_id?: string;
  explicit_time?: boolean;
  focus?: "time" | "amount";
  unit?: "ml" | "oz" | "kg" | "lb";
  topic?: string;
  anchor_subtype?: "nap" | "all";
};
export type QueryRecord = {
  domain?: QueryDomain;
  id: string;
  at?: string;
  end?: string | null;
  date?: string;
  precision?: "day" | "month";
  value?: number;
  offered?: number;
  remaining?: number;
  diaper?: "wet" | "dirty" | "mixed";
  title?: string;
};
export type QueryFacts = {
  version: 2;
  query: QuerySpec;
  child_id: string;
  child_name: string;
  evidence: "positive" | "negative" | "unknown" | "incomplete" | "stale";
  issues: string[];
  records: QueryRecord[];
  count: number;
  value?: number;
  completed_minutes: number;
  open_minutes: number;
  wet_count: number;
  dirty_count: number;
  diaper_count: number;
  feeding_count: number;
  feeding_ml: number;
  sleep_state: "asleep" | "awake" | "unknown";
  last_feeding?: QueryRecord;
  last_sleep?: QueryRecord;
};
export type Presentation = { milk: "ml" | "oz"; weight: "kg" | "lb"; surface: "spoken" | "visual" };
export type QueryContext = { child_id: string; domain: QueryDomain; record_id?: string; at: string };
export type FormatContext = { command: RequestCommand; language: "en" | "yue"; presentation: Presentation };
