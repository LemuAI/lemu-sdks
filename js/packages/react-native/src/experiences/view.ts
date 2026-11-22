import { fill, options, plainText, type Theme } from "./rules";
import type { Block, Dict, Experience, Step, Variant } from "./types";

/*
 * One in-app message on screen: its steps, the answers typed so far, the
 * form's validation and submit, and the success step with the offer code.
 * The host component (host.ts) draws it and calls these methods; this file
 * has no React in it so it can be tested on its own.
 */

export const MESSAGES = {
  required: "Please fill in the highlighted fields.",
  email: "Enter a valid email address.",
  phone: "Enter a valid phone number.",
  rateLimited: "Please try again in a minute.",
  failed: "Something went wrong. Please try again.",
  offline: "Couldn't send. Check your connection and try again.",
  otpLabel: "Enter the code we sent on WhatsApp",
};

const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/;
const CHECKBOX_INPUTS = ["consent", "checkbox"];
const CHOICE_INPUTS = ["select", "size", "chips", "rating", "nps"];

export interface SubmitResult {
  status: number;
  data: Dict;
}

/** What a view needs from the manager. */
export interface ViewHooks {
  /** Posts the form. Resolves null when the request never got an answer. */
  submit(view: ExperienceView, fields: Dict, otp?: string): Promise<SubmitResult | null>;
  /** The message went away; `byUser` when the user closed it. */
  closed(view: ExperienceView, byUser: boolean): void;
  submitted(view: ExperienceView, fields: Dict): void;
  clicked(view: ExperienceView, target: string): void;
  openUrl(url: string): void;
  copy(text: string): void;
  changed(): void;
}

export class ExperienceView {
  stepIndex = 0;
  /** Answers kept from earlier steps (sent on submit). */
  answers: Dict = {};
  /** What is typed in the visible step. */
  values: Dict = {};
  invalid: string[] = [];
  error = "";
  busy = false;
  otpPending = false;
  otp = "";
  copied = false;
  offer: Dict | null = null;
  closed = false;

  constructor(
    public exp: Experience,
    public variant: Variant,
    public theme: Theme,
    private hooks: ViewHooks,
  ) {
    this.prefill();
  }

  get content(): Dict {
    return this.variant.content || {};
  }

  get layout(): Dict {
    const l = this.content.layout;
    return l && typeof l === "object" ? l : {};
  }

  get steps(): Step[] {
    return Array.isArray(this.content.steps) ? (this.content.steps as Step[]) : [];
  }

  get step(): Step | undefined {
    return this.steps[this.stepIndex];
  }

  get blocks(): Block[] {
    const s = this.step;
    return s && Array.isArray(s.blocks) ? s.blocks.filter((b) => b && typeof b === "object") : [];
  }

  /** Text with `{{answers.x}}` / `{{offer.code}}` filled and markdown removed. */
  text(value: unknown): string {
    return plainText(fill(value, { answers: this.answers, offer: this.offer || {} }));
  }

  fields(): Block[] {
    return this.blocks.filter((b) => b.type === "field" && b.name);
  }

  choices(b: Block): { value: string; label: string }[] {
    return options(b);
  }

  value(name: string): unknown {
    return this.values[name];
  }

  setValue(name: string, value: unknown): void {
    this.values[name] = value;
    this.invalid = this.invalid.filter((n) => n !== name);
    this.hooks.changed();
  }

  setOtp(value: string): void {
    this.otp = String(value || "").replace(/[^\d]/g, "").slice(0, 6);
    this.hooks.changed();
  }

  /** The country code shown before a phone field. */
  countryCode(b: Block): string {
    return String(b.default_country || "+91");
  }

  private prefill(): void {
    this.values = {};
    for (const b of this.fields()) {
      const prior = this.answers[b.name];
      if (prior !== undefined) this.values[b.name] = b.input === "phone" ? String(prior).replace(/^\+\d{1,3}/, "") : prior;
      else if (CHECKBOX_INPUTS.indexOf(b.input) >= 0) this.values[b.name] = !!b.checked;
      else if (b.input === "hidden") this.values[b.name] = b.value == null ? "" : String(b.value);
      else this.values[b.name] = "";
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  /** A button block was pressed. */
  press(b: Block): void {
    if (this.closed) return;
    const action = b.action || "submit";
    if (action === "submit" || action === "call_me") this.submit();
    else if (action === "next_step") {
      if (this.validate()) {
        this.collect();
        this.next();
      }
    } else if (action === "close") this.close(true);
    else if (action === "url") {
      const url = String(b.url || "");
      this.hooks.clicked(this, url);
      if (url) this.hooks.openUrl(url);
      this.close(false);
    } else if (action === "copy_code") this.copyCode();
  }

  copyCode(): void {
    const code = this.offer && this.offer.code ? String(this.offer.code) : "";
    if (!code) return;
    this.hooks.copy(code);
    this.copied = true;
    this.hooks.clicked(this, "copy_code");
    this.hooks.changed();
  }

  close(byUser: boolean): void {
    if (this.closed) return;
    this.closed = true;
    this.hooks.closed(this, byUser);
  }

  next(): void {
    if (this.stepIndex < this.steps.length - 1) {
      this.stepIndex++;
      this.error = "";
      this.invalid = [];
      this.prefill();
      this.hooks.changed();
    }
  }

  /** Checks the visible step. Sets `invalid` and `error`. */
  validate(): boolean {
    const missing: string[] = [];
    for (const b of this.fields()) {
      if (!b.required || b.input === "hidden") continue;
      const v = this.values[b.name];
      if (CHECKBOX_INPUTS.indexOf(b.input) >= 0 ? v !== true : !String(v == null ? "" : v).trim()) missing.push(b.name);
    }
    if (missing.length) return this.fail(MESSAGES.required, missing);
    for (const b of this.fields()) {
      const v = String(this.values[b.name] == null ? "" : this.values[b.name]).trim();
      if (!v) continue;
      if (b.input === "email" && !EMAIL.test(v)) return this.fail(MESSAGES.email, [b.name]);
      if (b.input === "phone" && v.replace(/[^\d]/g, "").length < 6) return this.fail(MESSAGES.phone, [b.name]);
    }
    this.error = "";
    this.invalid = [];
    this.hooks.changed();
    return true;
  }

  private fail(message: string, names: string[]): false {
    this.error = message;
    this.invalid = names;
    this.hooks.changed();
    return false;
  }

  /** The visible step's values into `answers`. */
  collect(): void {
    for (const b of this.fields()) {
      const v = this.values[b.name];
      if (CHECKBOX_INPUTS.indexOf(b.input) >= 0) this.answers[b.name] = v === true;
      else if (b.input === "phone") {
        const typed = String(v == null ? "" : v).trim();
        if (!typed) this.answers[b.name] = "";
        else if (typed.charAt(0) === "+") this.answers[b.name] = "+" + typed.replace(/[^\d]/g, "");
        else this.answers[b.name] = this.countryCode(b) + typed.replace(/[^\d]/g, "").replace(/^0+/, "");
      } else if (CHOICE_INPUTS.indexOf(b.input) >= 0 || b.input === "hidden") this.answers[b.name] = v == null ? "" : String(v);
      else this.answers[b.name] = String(v == null ? "" : v).trim();
    }
  }

  /** Country code of the first phone field, sent as `context.phone_country`. */
  phoneCountry(): string {
    for (const s of this.steps) {
      for (const b of s.blocks || []) if (b && b.type === "field" && b.input === "phone") return this.countryCode(b);
    }
    return "+91";
  }

  submit(): Promise<void> {
    if (this.busy || this.closed) return Promise.resolve();
    let otp: string | undefined;
    if (this.otpPending) {
      if (!this.otp) {
        this.fail(MESSAGES.required, ["_otp"]);
        return Promise.resolve();
      }
      otp = this.otp;
    } else {
      if (!this.validate()) return Promise.resolve();
      this.collect();
    }
    this.busy = true;
    this.error = "";
    this.hooks.changed();
    const fields: Dict = {};
    for (const k in this.answers) fields[k] = this.answers[k];
    return this.hooks.submit(this, fields, otp).then(
      (result) => this.answered(result, fields),
      () => this.answered(null, fields),
    );
  }

  private answered(result: SubmitResult | null, fields: Dict): void {
    this.busy = false;
    if (this.closed) return;
    if (!result) {
      this.error = MESSAGES.offline;
      return this.hooks.changed();
    }
    const data = result.data || {};
    if (data.verify) {
      this.otpPending = true;
      this.otp = "";
      this.error = data.errors && data.errors._otp ? String(data.errors._otp) : "";
      return this.hooks.changed();
    }
    if (!data.ok) {
      const errors = data.errors && typeof data.errors === "object" ? data.errors : {};
      const first = errors._form || Object.keys(errors).map((k) => errors[k])[0];
      this.error = first ? String(first) : result.status === 429 ? MESSAGES.rateLimited : MESSAGES.failed;
      return this.hooks.changed();
    }
    this.otpPending = false;
    this.offer = data.offer && typeof data.offer === "object" ? data.offer : null;
    this.hooks.submitted(this, fields);
    const after = this.steps.findIndex(
      (s, i) => i > this.stepIndex && (s.id === "success" || !(s.blocks || []).some((b) => b && b.type === "field")),
    );
    if (after > 0) {
      this.stepIndex = after;
      this.invalid = [];
      this.prefill();
      this.hooks.changed();
    } else this.close(false);
  }
}
