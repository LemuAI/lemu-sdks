/* Shapes of the config bundle (api/services/onsite/service.py build_bundle). */

export type Dict = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

export interface Condition {
  kind: string;
  op?: string;
  value?: unknown;
  [key: string]: unknown;
}

export interface UrlRule {
  type: string;
  value?: string;
}

export interface Placement {
  zone?: string;
  selector?: string;
  position?: "before" | "after" | "replace" | "prepend" | "append";
}

export interface Block extends Dict {
  type: string;
  id?: string;
}

export interface Step {
  id: string;
  blocks: Block[];
}

export interface Variant {
  key: string;
  weight: number;
  kind: "blocks" | "code";
  content: Dict;
}

export interface Experience {
  id: number;
  key: string;
  format: string;
  platform: string;
  priority: number;
  version: number;
  inline: boolean;
  schedule: Dict;
  where: { include?: UrlRule[]; exclude?: UrlRule[]; placement?: Placement };
  who: { match: "all" | "any"; conditions: Condition[]; server: boolean; server_conditions?: number };
  trigger: { on: string; seconds?: number; percent?: number; selector?: string; event?: string };
  frequency: {
    show: string;
    days?: number;
    stop_after_submit?: boolean;
    max_closes?: number | null;
    cooldown_hours_after_close?: number;
  };
  holdout_pct: number;
  capture: { fields: Record<string, { to: string }>; offer?: boolean; verify_phone?: boolean };
  variants: Variant[];
  preview?: boolean;
}

export interface PageType {
  name: string;
  rules: UrlRule[];
}

export interface Zone {
  name: string;
  page_type?: string;
  selector: string;
  position?: Placement["position"];
}

export interface Bundle {
  live: boolean;
  v?: string;
  source_id?: number;
  theme: Dict;
  page_types: PageType[];
  zones: Zone[];
  caps: { popups_per_page?: number; popups_per_session?: number };
  experiences: Experience[];
  pages: { path: string; page: number; site: string; slug: string }[];
  decide: boolean;
  preview?: { experience: string; name: string };
}

export interface Product {
  id?: string;
  variant_id?: string;
  sku?: string;
  title?: string;
  size?: string;
  price?: number;
  currency?: string;
  image_url?: string;
  url?: string;
  in_stock?: boolean;
  variants?: { id: string; sku?: string; title?: string; available?: boolean; options?: string[]; price?: number }[];
  options?: string[];
}

export interface Context {
  url: string;
  path: string;
  referrer: string;
  page_type: string;
  product?: Product;
  cart: { value: number; items: number };
  utm: Dict;
  locale: string;
}

export interface Decision {
  known: boolean;
  experiences: Record<string, { match: boolean | null; hidden: boolean }>;
}

export interface Env {
  host: string;
  key: string;
  anonymousId(): string | null;
  userId(): string | null;
  track(event: string, properties: Dict): void;
}
