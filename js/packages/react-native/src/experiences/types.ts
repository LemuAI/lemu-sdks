/* Shapes of the onsite config bundle (api/services/onsite/service.py
 * build_bundle), the parts in-app messages use. Mirrors
 * packages/onsite/src/types.ts. */

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type Dict = Record<string, any>;

export interface Condition {
  kind: string;
  op?: string;
  value?: unknown;
  [key: string]: unknown;
}

export interface ScreenRule {
  type: string;
  value?: string;
}

export interface Block extends Dict {
  type: string;
}

export interface Step {
  id: string;
  blocks: Block[];
}

export interface Variant {
  key: string;
  weight: number;
  kind: string;
  content: Dict;
}

export interface Experience {
  id: number;
  key: string;
  format: string;
  platform: string;
  priority: number;
  version: number;
  schedule: Dict;
  where: { include?: ScreenRule[]; exclude?: ScreenRule[] };
  who: { match?: "all" | "any"; conditions?: Condition[]; server?: boolean; server_conditions?: number };
  trigger: { on?: string; seconds?: number; event?: string };
  frequency: {
    show?: string;
    days?: number;
    stop_after_submit?: boolean;
    max_closes?: number | null;
    cooldown_hours_after_close?: number | null;
  };
  holdout_pct: number;
  capture?: Dict;
  variants: Variant[];
}

export interface Bundle {
  live: boolean;
  v?: string;
  theme: Dict;
  caps: { popups_per_page?: number | null; popups_per_session?: number | null };
  experiences: Experience[];
  decide: boolean;
}

export interface Decision {
  known: boolean;
  experiences: Record<string, { match: boolean | null; hidden: boolean }>;
}

/** What one experience remembers on this device. */
export interface Seen {
  n: number;
  last: number;
  closes: number;
  lastClose: number;
  submitted: number;
  variant?: string;
  sessionShown?: string;
}

/** Visits, the current session and per-experience history. */
export interface ExperienceState {
  visits: number;
  first: number;
  last: number;
  session: string;
  sessionStart: number;
  popupsThisSession: number;
  seen: Record<string, Seen>;
}
