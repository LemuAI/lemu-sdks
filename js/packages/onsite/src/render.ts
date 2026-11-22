import { submitContext } from "./context";
import { seen, persist, visitor } from "./state";
import { CSS, themeVars } from "./styles";
import type { Block, Bundle, Context, Dict, Env, Experience, Step, Variant } from "./types";
import { d, esc, fill, getJSON, md, postJSON, safe, w } from "./util";

/*
 * One experience on the page: a host element with a shadow root (the site's
 * CSS can't reach in, ours can't leak out), the variant's steps of blocks,
 * forms that post to /pixel/onsite/submit, and the success step with the
 * offer code. Code variants render their own HTML with their parameters.
 */

const COUNTRY_CODES = ["+91", "+1", "+44", "+971", "+61", "+65", "+60", "+966", "+974", "+880", "+94", "+977", "+49", "+33"];

export interface ViewHooks {
  closed(view: View, byUser: boolean): void;
  submitted(view: View): void;
  show(key: string): void;
}

let openModal: View | null = null;

export class View {
  host: HTMLElement | null = null;
  root: ShadowRoot | null = null;
  panel: HTMLElement | null = null;
  stepIndex = 0;
  answers: Dict = {};
  offer: Dict | null = null;
  prize: Dict | null = null;
  replaced: HTMLElement | null = null;
  timers: Array<ReturnType<typeof setInterval>> = [];
  lastFocus: Element | null = null;
  expanded = false;
  busy = false;
  otpPending = false;

  constructor(
    public exp: Experience,
    public variant: Variant,
    public bundle: Bundle,
    public ctx: Context,
    public env: Env,
    public hooks: ViewHooks
  ) {}

  get content(): Dict {
    return this.variant.content || {};
  }

  get layout(): Dict {
    return this.content.layout || {};
  }

  get steps(): Step[] {
    return (this.content.steps || []) as Step[];
  }

  // ── Mounting ──────────────────────────────────────────────────────────────

  mount(): boolean {
    const host = d.createElement("div");
    host.setAttribute("data-lemu-experience", this.exp.key);
    if (this.exp.format === "inline" || this.exp.format === "widget") {
      if (!this.place(host)) return false;
    } else {
      d.body.appendChild(host);
    }
    this.host = host;
    const root: ShadowRoot = host.attachShadow ? host.attachShadow({ mode: "open" }) : (host as unknown as ShadowRoot);
    this.root = root;
    const style = d.createElement("style");
    style.textContent = `:host{${themeVars(this.bundle.theme || {}, this.content.style || {})}}${CSS}${this.content.css || ""}`;
    root.appendChild(style);
    this.fonts();
    root.addEventListener("click", (e: Event) => this.onClick(e));
    root.addEventListener("submit", (e: Event) => this.onSubmit(e));
    root.addEventListener("change", (e: Event) => this.onChange(e));
    root.addEventListener("keydown", (e: Event) => this.onKey(e as KeyboardEvent));
    this.frame();
    return true;
  }

  private fonts(): void {
    const fonts = (this.bundle.theme || {}).google_fonts || [];
    if (!fonts.length || d.getElementById("lemu-fonts")) return;
    const link = d.createElement("link");
    link.id = "lemu-fonts";
    link.rel = "stylesheet";
    link.href = "https://fonts.googleapis.com/css2?" + fonts.map((f: string) => "family=" + f.replace(/ /g, "+") + ":wght@400;600;700").join("&") + "&display=swap";
    d.head.appendChild(link);
  }

  private place(host: HTMLElement): boolean {
    const placement = this.exp.where.placement || {};
    let selector = placement.selector;
    let position = placement.position || "after";
    if (placement.zone) {
      const zone = (this.bundle.zones || []).filter((z) => z.name === placement.zone)[0];
      if (zone) {
        selector = zone.selector;
        position = placement.position || zone.position || "after";
      }
    }
    if (!selector) return false;
    const parts = selector.split(",").map((s) => s.trim());
    let target: HTMLElement | null = null;
    for (const s of parts) {
      target = safe(() => d.querySelector(s)) || null;
      if (target) break;
    }
    if (!target) return false;
    if (position === "before") target.parentNode!.insertBefore(host, target);
    else if (position === "prepend") target.insertBefore(host, target.firstChild);
    else if (position === "append") target.appendChild(host);
    else if (position === "replace") {
      target.parentNode!.insertBefore(host, target.nextSibling);
      this.replaced = target;
      target.style.display = "none";
    } else target.parentNode!.insertBefore(host, target.nextSibling);
    return true;
  }

  /** The format's frame around the content. */
  private frame(): void {
    const root = this.root!;
    const f = this.exp.format;
    const lay = this.layout;
    const wrap = d.createElement("div");
    const close = lay.close_button === false ? "" : '<button class="lx-close" data-lx="close" aria-label="Close">×</button>';
    if (f === "popup" || f === "teaser") {
      if (f === "teaser" && !this.expanded) return this.teaser(true);
      wrap.className = "lx-overlay" + (lay.mobile_sheet === false ? "" : " lx-sheet");
      if (lay.overlay === false) wrap.style.background = "transparent";
      const media = lay.image && lay.image.url ? lay.image : null;
      const side = media ? media.side || "left" : "";
      wrap.innerHTML = `<div class="lx-box lx-${esc(lay.size || "m")} ${side ? "lx-media-" + esc(side) : ""}" role="dialog" aria-modal="true">${
        media && side !== "background" ? `<div class="lx-media" style="background-image:url('${esc(media.url)}')"></div>` : ""
      }<div class="lx-body" data-lx="body"></div>${close}</div>`;
      if (media && side === "background") (wrap.firstChild as HTMLElement).style.backgroundImage = `url('${media.url}')`;
      wrap.addEventListener("click", (e: Event) => {
        if (e.target === wrap && lay.close_on_overlay !== false) this.close(true);
      });
      this.lastFocus = d.activeElement;
      openModal = this;
    } else if (f === "slide_in") {
      wrap.className = `lx-float lx-${esc(lay.position || "bottom_right")}`;
      wrap.innerHTML = `<div class="lx-box" role="dialog"><div class="lx-body" data-lx="body"></div>${close}</div>`;
    } else if (f === "bar") {
      wrap.className = `lx-bar lx-${esc(lay.position || "top")}${lay.sticky === false ? " lx-static" : ""}`;
      wrap.setAttribute("role", "region");
      wrap.innerHTML = `<div data-lx="body"></div>${close}`;
    } else if (f === "toast") {
      wrap.className = `lx-toast lx-${esc(lay.position || "bottom_left")}`;
      wrap.style.cssText = positionCss(lay.position || "bottom_left");
      wrap.setAttribute("role", "status");
      wrap.innerHTML = `<div data-lx="body"></div>${close}`;
      const secs = Number(lay.auto_hide_seconds || 8);
      if (secs > 0) this.timers.push(setTimeout(() => this.close(false), secs * 1000) as unknown as ReturnType<typeof setInterval>);
    } else if (f === "floating_button") {
      if (!this.expanded) return this.fab();
      wrap.className = `lx-float lx-${esc(lay.position || "bottom_right")}`;
      wrap.style.bottom = "80px";
      wrap.innerHTML = `<div class="lx-box" role="dialog"><div class="lx-body" data-lx="body"></div><button class="lx-close" data-lx="collapse" aria-label="Close">×</button></div>`;
    } else {
      // inline, widget
      wrap.className = "lx-inline" + (lay.border ? " lx-border" : "");
      if (lay.collapsed && !this.expanded) {
        wrap.innerHTML = `<button class="lx-collapsed" data-lx="expand">${esc(lay.collapsed_text || "Show")}</button>`;
        this.setPanel(wrap);
        return;
      }
      wrap.innerHTML = `<div data-lx="body"></div>${lay.close_button ? close : ""}`;
    }
    this.setPanel(wrap);
    this.renderStep();
    if (f === "popup" || f === "teaser") {
      const first = this.root!.querySelector("input,select,textarea,button:not(.lx-close)") as HTMLElement | null;
      if (first) setTimeout(() => safe(() => first.focus()), 50);
      const heading = this.root!.querySelector("h1,h2,h3");
      if (heading) wrap.firstElementChild!.setAttribute("aria-label", heading.textContent || "");
    }
    root.host && (root.host as HTMLElement).setAttribute("data-step", this.currentStep()?.id || "");
  }

  private setPanel(el: HTMLElement): void {
    if (this.panel) this.panel.remove();
    this.panel = el;
    this.root!.appendChild(el);
  }

  private teaser(initial: boolean): void {
    const t = this.content.teaser || {};
    const el = d.createElement("button");
    el.className = `lx-teaser lx-${t.position === "right" ? "right" : "left"}`;
    el.setAttribute("data-lx", "expand");
    el.textContent = t.text || "Open";
    this.setPanel(el);
    if (!initial) this.track("onsite_closed", {});
  }

  private fab(): void {
    const el = d.createElement("button");
    el.className = `lx-fab lx-${esc(this.layout.position || "bottom_right")}`;
    el.setAttribute("data-lx", "expand");
    const icon =
      this.layout.button_icon === "whatsapp"
        ? '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M20 3.9A10.9 10.9 0 0 0 3 17.1L2 22l5-1.3A10.9 10.9 0 0 0 20 3.9zM12 20a9 9 0 0 1-4.6-1.3l-.3-.2-3 .8.8-2.9-.2-.3A9 9 0 1 1 12 20z"/></svg>'
        : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1.9.4 1.8.7 2.7a2 2 0 0 1-.5 2.1L8 9.8a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.5c.9.3 1.8.6 2.7.7a2 2 0 0 1 1.7 2z"/></svg>';
    el.innerHTML = `${icon}<span>${esc(this.layout.button_text || "Talk to us")}</span>`;
    this.setPanel(el);
  }

  // ── Steps and blocks ──────────────────────────────────────────────────────

  currentStep(): Step | undefined {
    return this.steps[this.stepIndex];
  }

  renderStep(): void {
    const body = this.root!.querySelector('[data-lx="body"]') as HTMLElement | null;
    if (!body) return;
    if (this.variant.kind === "code") {
      body.innerHTML = this.codeHtml();
      this.runCode(body);
      return;
    }
    const step = this.currentStep();
    if (!step) return;
    const inForm = step.blocks.some((b) => b.type === "field" || (b.type === "button" && (b.action || "submit") === "submit"));
    const html = step.blocks.map((b) => this.block(b)).join("");
    const inputStyle = (this.bundle.theme || {}).input_style;
    const cls = `lx-step${inputStyle === "filled" ? " lx-filled" : inputStyle === "underline" ? " lx-underline" : ""}${this.content.style && this.content.style.align === "center" ? " lx-center" : ""}`;
    body.innerHTML = inForm
      ? `<form class="${cls}" novalidate data-step="${esc(step.id)}"><input class="lx-hp" name="_hp" tabindex="-1" autocomplete="off" aria-hidden="true">${html}<p class="lx-err" data-lx="error" role="alert" hidden></p></form>`
      : `<div class="${cls}">${html}</div>`;
    this.hydrate(body);
  }

  private scopes(): Dict {
    return {
      answers: this.answers,
      product: this.ctx.product || {},
      offer: this.offer || {},
      prize: this.prize || {},
      cart: this.ctx.cart,
    };
  }

  private block(b: Block): string {
    const t = (v: unknown) => fill(String(v == null ? "" : v), this.scopes());
    const align = b.align ? ` style="text-align:${esc(b.align)}"` : "";
    switch (b.type) {
      case "heading": {
        const level = Math.min(3, Math.max(1, Number(b.level) || 2));
        return `<h${level}${align}>${md(t(b.text))}</h${level}>`;
      }
      case "text":
        return `<p class="lx-text${b.muted ? " lx-muted" : ""}"${align}>${md(t(b.text))}</p>`;
      case "image":
        if (!b.url) return "";
        return `${b.link ? `<a href="${esc(b.link)}" target="_top">` : ""}<img class="lx-img" src="${esc(b.url)}" alt="${esc(b.alt || "")}" loading="lazy">${b.link ? "</a>" : ""}`;
      case "button": {
        const action = b.action || "submit";
        const kind = b.variant || (action === "close" ? "secondary" : "primary");
        const type = action === "submit" || action === "call_me" ? "submit" : "button";
        return `<button type="${type}" class="lx-btn lx-btn-${esc(kind)}" data-action="${esc(action)}" data-url="${esc(b.url || "")}" data-phone="${esc(b.phone || "")}" data-message="${esc(b.message || "")}" data-target="${esc(b.target || "")}">${esc(t(b.text || "Continue"))}</button>`;
      }
      case "close":
        return `<button type="button" class="lx-dismiss" data-lx="close">${esc(b.text || "No thanks")}</button>`;
      case "field":
        return this.field(b);
      case "offer":
        return this.offerBlock(b);
      case "countdown":
        return `<div class="lx-countdown${b.compact ? " lx-compact" : ""}" data-lx="countdown" data-until="${esc(this.countdownEnd(b))}" data-expired="${esc(b.expired_text || "")}"></div>`;
      case "product": {
        const p = this.ctx.product;
        if (!p) return "";
        return `<div class="lx-product-card">${p.image_url ? `<img src="${esc(p.image_url)}" alt="">` : ""}<div><b>${esc(p.title || "")}</b>${p.size ? `<div class="lx-text lx-muted">${esc(p.size)}</div>` : ""}</div></div>`;
      }
      case "products":
        return `<div class="lx-products" data-lx="products" data-strategy="${esc(b.strategy || "trending")}" data-limit="${esc(b.limit || 4)}" data-category="${esc(b.category || (b.category_from ? t("{{" + b.category_from + "}}") : ""))}" data-fallback="${esc(b.fallback || "")}"></div>`;
      case "social_proof":
        return `<p class="lx-text" data-lx="proof" data-metric="${esc(b.metric || "purchases_24h")}" data-text="${esc(b.text || "{count} people bought this today")}" data-min="${esc(b.min || 1)}" data-fallback-metric="${esc(b.fallback_metric || "")}" data-fallback-text="${esc(b.fallback_text || "")}"></p>`;
      case "progress": {
        const goal = Number(b.goal) || 0;
        const value = this.ctx.cart.value || 0;
        const left = Math.max(0, goal - value);
        const pct = goal ? Math.min(100, (value / goal) * 100) : 0;
        const msg = left > 0 ? String(b.text_before || "").replace("{remaining}", `${b.currency || ""}${Math.ceil(left)}`) : b.text_after || "";
        return `<div class="lx-progress"><span>${md(msg)}</span><div class="lx-track"><i style="width:${pct}%"></i></div></div>`;
      }
      case "wheel":
        return this.wheel(b);
      case "divider":
        return '<hr class="lx-divider">';
      case "spacer":
        return `<div style="height:${Math.min(80, Number(b.height) || 12)}px"></div>`;
      case "columns":
        return `<div class="lx-cols">${(b.columns || []).map((c: Dict) => `<div class="lx-step">${(c.blocks || []).map((x: Block) => this.block(x)).join("")}</div>`).join("")}</div>`;
      case "html":
        return ""; // only in code variants
      default:
        return "";
    }
  }

  private field(b: Block): string {
    const name = esc(b.name);
    const req = b.required ? " required" : "";
    const label = b.label ? `<span>${md(b.label)}${b.required ? " *" : ""}</span>` : "";
    const ph = esc(b.placeholder || "");
    const prior = this.answers[b.name];
    const options = this.options(b);
    switch (b.input) {
      case "hidden": {
        const v = b.from_context ? this.fromContext(b.from_context) : b.value;
        return `<input type="hidden" name="${name}" value="${esc(v || "")}">`;
      }
      case "consent":
      case "checkbox": {
        const checked = prior !== undefined ? prior : b.checked;
        return `<label class="lx-check"><input type="checkbox" name="${name}"${checked ? " checked" : ""}${req}><span>${md(b.label)}</span></label>`;
      }
      case "phone": {
        const cc = b.default_country || "+91";
        const codes = COUNTRY_CODES.indexOf(cc) >= 0 ? COUNTRY_CODES : [cc, ...COUNTRY_CODES];
        return `<label class="lx-field">${label}<div class="lx-phone"><select name="${name}__cc" aria-label="Country code">${codes.map((c) => `<option${c === cc ? " selected" : ""}>${c}</option>`).join("")}</select><input type="tel" name="${name}" inputmode="tel" autocomplete="tel-national" placeholder="${ph}" value="${esc(prior || "")}"${req}></div></label>`;
      }
      case "select":
      case "size": {
        const chosen = prior !== undefined ? prior : b.from_context ? this.fromContext(b.from_context) : "";
        return `<label class="lx-field">${label}<select name="${name}"${req}><option value="">${ph || "Choose"}</option>${options
          .map((o) => `<option value="${esc(o.value)}"${String(o.value) === String(chosen) ? " selected" : ""}>${esc(o.label)}</option>`)
          .join("")}</select></label>`;
      }
      case "chips":
      case "rating":
      case "nps": {
        const list =
          b.input === "chips"
            ? options
            : Array.from({ length: b.input === "nps" ? 11 : 5 }, (_, i) => ({ value: String(b.input === "nps" ? i : i + 1), label: String(b.input === "nps" ? i : i + 1) }));
        return `<fieldset class="lx-field">${b.label ? `<legend>${md(b.label)}</legend>` : ""}<div class="lx-chips">${list
          .map((o) => `<label class="lx-chip"><input type="radio" name="${name}" value="${esc(o.value)}"${String(prior) === String(o.value) ? " checked" : ""}${req}${b.auto_next ? ' data-auto-next="1"' : ""}><span>${esc(o.label)}</span></label>`)
          .join("")}</div></fieldset>`;
      }
      case "textarea":
        return `<label class="lx-field">${label}<textarea name="${name}" rows="3" placeholder="${ph}"${req}>${esc(prior || "")}</textarea></label>`;
      default: {
        const type = b.input === "email" ? "email" : b.input === "number" ? "number" : b.input === "date" ? "date" : "text";
        const extra = b.input === "email" ? ' autocomplete="email"' : b.input === "pincode" ? ' inputmode="numeric" maxlength="10"' : b.name === "name" || b.name === "first_name" ? ' autocomplete="given-name"' : "";
        return `<label class="lx-field">${label}<input type="${type}" name="${name}" placeholder="${ph}" value="${esc(prior || "")}"${extra}${req}></label>`;
      }
    }
  }

  private options(b: Block): { value: string; label: string }[] {
    let raw = b.options || [];
    if (b.input === "size" && !raw.length && this.ctx.product && this.ctx.product.variants) {
      raw = this.ctx.product.variants.map((v) => ({ value: v.title || v.id, label: (v.title || v.id) + (v.available === false ? " (sold out)" : "") }));
    }
    return raw.map((o: unknown) => (o && typeof o === "object" ? { value: String((o as Dict).value), label: String((o as Dict).label || (o as Dict).value) } : { value: String(o), label: String(o) }));
  }

  private fromContext(path: string): string {
    const [scope, key] = String(path).split(".");
    const s = (this.scopes() as Dict)[scope];
    return s && s[key] != null ? String(s[key]) : "";
  }

  private offerBlock(b: Block): string {
    const o = this.offer || {};
    if (!o.code && !o.headline && !o.prize) return "";
    const showCode = (b.show || "code") !== "headline" && o.code;
    return `<div class="lx-step lx-center">${o.headline && (b.show === "headline" || b.show === "both") ? `<p class="lx-text"><strong>${esc(o.headline)}</strong></p>` : ""}${
      showCode
        ? `<div class="lx-code"><strong>${esc(o.code)}</strong><button type="button" class="lx-btn lx-btn-secondary" style="width:auto" data-action="copy_code">${esc(b.copy_label || "Copy")}</button></div>`
        : ""
    }${o.terms ? `<p class="lx-text lx-muted" style="font-size:.8em">${esc(o.terms)}</p>` : ""}</div>`;
  }

  private countdownEnd(b: Block): string {
    if (b.until) return String(b.until);
    if (b.minutes) {
      const h = seen(this.exp.key);
      h.started = h.started || Date.now();
      persist();
      return new Date(h.started + Number(b.minutes) * 60000).toISOString();
    }
    return "";
  }

  private wheel(b: Block): string {
    const slices = (b.slices || []) as Dict[];
    const n = Math.max(1, slices.length);
    const colors = ["var(--lemu-primary)", "#f59e0b", "#10b981", "#6366f1", "#ef4444", "#14b8a6", "#8b5cf6", "#f97316"];
    let paths = "";
    slices.forEach((s, i) => {
      const a0 = (i / n) * 2 * Math.PI - Math.PI / 2;
      const a1 = ((i + 1) / n) * 2 * Math.PI - Math.PI / 2;
      const x0 = 100 + 98 * Math.cos(a0);
      const y0 = 100 + 98 * Math.sin(a0);
      const x1 = 100 + 98 * Math.cos(a1);
      const y1 = 100 + 98 * Math.sin(a1);
      const mid = (a0 + a1) / 2;
      const tx = 100 + 62 * Math.cos(mid);
      const ty = 100 + 62 * Math.sin(mid);
      paths += `<path d="M100 100 L${x0} ${y0} A98 98 0 0 1 ${x1} ${y1} Z" fill="${esc(s.color || colors[i % colors.length])}"/><text x="${tx}" y="${ty}" fill="#fff" font-size="10" font-weight="700" text-anchor="middle" dominant-baseline="middle" transform="rotate(${(mid * 180) / Math.PI + 90} ${tx} ${ty})">${esc(s.label)}</text>`;
    });
    return `<div class="lx-wheel"><svg viewBox="0 0 200 200" data-lx="wheel">${paths}<circle cx="100" cy="100" r="14" fill="#fff"/></svg></div>`;
  }

  // ── Live parts ────────────────────────────────────────────────────────────

  private hydrate(body: HTMLElement): void {
    body.querySelectorAll('[data-lx="countdown"]').forEach((el) => this.countdown(el as HTMLElement));
    body.querySelectorAll('[data-lx="products"]').forEach((el) => this.products(el as HTMLElement));
    body.querySelectorAll('[data-lx="proof"]').forEach((el) => this.proof(el as HTMLElement));
  }

  private countdown(el: HTMLElement): void {
    const end = Date.parse(el.getAttribute("data-until") || "");
    if (!end) {
      el.remove();
      return;
    }
    const tick = () => {
      const left = Math.max(0, end - Date.now());
      if (!left) {
        el.innerHTML = esc(el.getAttribute("data-expired") || "");
        return;
      }
      const s = Math.floor(left / 1000);
      const parts = [
        [Math.floor(s / 86400), "days"],
        [Math.floor((s % 86400) / 3600), "hrs"],
        [Math.floor((s % 3600) / 60), "min"],
        [s % 60, "sec"],
      ].filter((p, i) => i > 0 || p[0]);
      el.innerHTML = parts.map(([v, l]) => `<span><b>${String(v).padStart(2, "0")}</b><small>${l}</small></span>`).join("");
    };
    tick();
    this.timers.push(setInterval(tick, 1000));
  }

  private products(el: HTMLElement): void {
    const strategy = el.getAttribute("data-strategy") || "trending";
    const p = this.ctx.product || {};
    const recent = visitor().recent.filter((s) => s !== p.sku).slice(0, 12);
    const q = [
      "k=" + encodeURIComponent(this.env.key),
      "strategy=" + encodeURIComponent(strategy),
      "limit=" + encodeURIComponent(el.getAttribute("data-limit") || "4"),
      p.sku ? "sku=" + encodeURIComponent(p.sku) : "",
      strategy === "recently_viewed" ? "skus=" + encodeURIComponent(recent.join(",")) : "",
      el.getAttribute("data-category") ? "category=" + encodeURIComponent(el.getAttribute("data-category")!) : "",
    ].filter(Boolean);
    getJSON(`${this.env.host}/api/v1/pixel/onsite/products?${q.join("&")}`)
      .then((data: Dict) => {
        const items = (data && data.items) || [];
        if (!items.length) {
          if (this.exp.inline && el.parentElement && el.parentElement.children.length <= 2) this.close(false);
          else el.remove();
          return;
        }
        el.innerHTML = items
          .map(
            (i: Dict) =>
              `<a class="lx-product" href="${esc(i.url || "#")}" target="_top" data-action="url" data-url="${esc(i.url || "")}">${i.image_url ? `<img src="${esc(i.image_url)}" alt="" loading="lazy">` : ""}<b>${esc(i.title)}</b><em>${esc(price(i))}</em></a>`
          )
          .join("");
      })
      .catch(() => el.remove());
  }

  private proof(el: HTMLElement): void {
    const p = this.ctx.product || {};
    if (!p.sku) {
      this.close(false);
      return;
    }
    const ask = (metric: string) =>
      getJSON(`${this.env.host}/api/v1/pixel/onsite/products?k=${encodeURIComponent(this.env.key)}&metric=${encodeURIComponent(metric)}&sku=${encodeURIComponent(p.sku!)}`).then((r: Dict) => Number((r && r.count) || 0));
    const min = Number(el.getAttribute("data-min") || 1);
    ask(el.getAttribute("data-metric") || "purchases_24h")
      .then((count) => {
        if (count >= min) return [count, el.getAttribute("data-text") || ""] as [number, string];
        const fb = el.getAttribute("data-fallback-metric");
        if (!fb) return null;
        return ask(fb).then((c) => (c >= min ? ([c, el.getAttribute("data-fallback-text") || ""] as [number, string]) : null));
      })
      .then((r) => {
        if (!r) return this.close(false);
        el.innerHTML = md(r[1].replace("{count}", String(r[0])));
      })
      .catch(() => this.close(false));
  }

  // ── Code variants ─────────────────────────────────────────────────────────

  private codeHtml(): string {
    const values: Dict = {};
    (this.content.params || []).forEach((p: Dict) => {
      values[p.name] = (this.content.values || {})[p.name] ?? p.default ?? "";
    });
    return String(this.content.html || "").replace(/\{\{\s*([a-z_][a-z0-9_]*)\s*\}\}/gi, (_m, k) => esc(values[k] ?? ""));
  }

  private runCode(body: HTMLElement): void {
    const js = String(this.content.js || "");
    if (!js.trim()) return;
    const api = {
      close: () => this.close(true),
      submit: (fields: Dict) => this.send(fields),
      track: (event: string, props: Dict) => this.env.track(event, props || {}),
      context: this.ctx,
    };
    // The brand's own code, saved by their admins (it runs with the page's rights).
    safe(() => new Function("root", "lemu", "params", js)(body, api, this.content.values || {}));
  }

  // ── Events ────────────────────────────────────────────────────────────────

  private onKey(e: KeyboardEvent): void {
    if (e.key === "Escape" && (this.exp.format === "popup" || this.exp.format === "teaser")) this.close(true);
    if (e.key === "Tab" && openModal === this) {
      const items = Array.from(this.root!.querySelectorAll("button,input,select,textarea,a[href]")) as HTMLElement[];
      if (!items.length) return;
      const first = items[0];
      const last = items[items.length - 1];
      const active = (this.root as ShadowRoot).activeElement;
      if (e.shiftKey && active === first) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && active === last) {
        e.preventDefault();
        first.focus();
      }
    }
  }

  private onChange(e: Event): void {
    const el = e.target as HTMLInputElement;
    if (el && el.getAttribute && el.getAttribute("data-auto-next")) {
      this.collect();
      setTimeout(() => this.next(), 150);
    }
  }

  private onClick(e: Event): void {
    const el = (e.target as HTMLElement).closest ? ((e.target as HTMLElement).closest("[data-lx],[data-action],[data-lemu-close]") as HTMLElement | null) : null;
    if (!el) return;
    const lx = el.getAttribute("data-lx");
    if (lx === "close" || el.hasAttribute("data-lemu-close")) return this.close(true);
    if (lx === "expand") {
      this.expanded = true;
      this.frame();
      if (this.exp.format === "teaser" || this.exp.format === "floating_button") this.track("onsite_clicked", { target: "open" });
      return;
    }
    if (lx === "collapse") {
      this.expanded = false;
      this.frame();
      return;
    }
    const action = el.getAttribute("data-action");
    if (!action || action === "submit" || action === "call_me") return; // the form's submit
    e.preventDefault();
    if (action === "next_step") {
      if (this.validate()) {
        this.collect();
        this.next();
      }
    } else if (action === "close") this.close(true);
    else if (action === "url") {
      const url = el.getAttribute("data-url") || "";
      this.track("onsite_clicked", { target: url });
      if (/^(https?:\/\/|\/|#)/.test(url)) w.location.href = url;
    } else if (action === "copy_code") {
      const code = (this.offer || {}).code || "";
      safe(() => w.navigator.clipboard.writeText(code));
      el.textContent = "Copied";
      this.track("onsite_clicked", { target: "copy_code" });
    } else if (action === "whatsapp") {
      const phone = (el.getAttribute("data-phone") || "").replace(/[^\d]/g, "");
      const msg = fill(el.getAttribute("data-message") || "", this.scopes());
      this.track("onsite_clicked", { target: "whatsapp" });
      w.open(`https://wa.me/${phone}${msg ? "?text=" + encodeURIComponent(msg) : ""}`, "_blank", "noopener");
    } else if (action === "show_experience") {
      this.hooks.show(el.getAttribute("data-target") || "");
    }
  }

  private next(): void {
    if (this.stepIndex < this.steps.length - 1) {
      this.stepIndex++;
      this.renderStep();
      if (this.host) this.host.setAttribute("data-step", this.currentStep()?.id || "");
    }
  }

  private form(): HTMLFormElement | null {
    return this.root!.querySelector("form");
  }

  /** Answers from the visible step into ``this.answers``. */
  private collect(): void {
    const form = this.form();
    if (!form) return;
    const data: Dict = {};
    Array.from(form.elements).forEach((el: Dict) => {
      if (!el.name || el.name === "_hp" || /__cc$/.test(el.name)) return;
      if (el.type === "checkbox") data[el.name] = !!el.checked;
      else if (el.type === "radio") {
        if (el.checked) data[el.name] = el.value;
      } else data[el.name] = el.value;
    });
    Array.from(form.querySelectorAll("select[name$='__cc']")).forEach((cc: Dict) => {
      const name = cc.name.replace(/__cc$/, "");
      if (data[name]) data[name] = cc.value + String(data[name]).replace(/^0+/, "").replace(/[^\d]/g, "");
    });
    Object.assign(this.answers, data);
  }

  private error(message: string): void {
    const el = this.root!.querySelector('[data-lx="error"]') as HTMLElement | null;
    if (!el) return;
    el.textContent = message;
    el.hidden = !message;
  }

  private validate(): boolean {
    const form = this.form();
    if (!form) return true;
    const bad = Array.from(form.querySelectorAll("[required]")).filter((el: Dict) => {
      if (el.type === "checkbox") return !el.checked;
      if (el.type === "radio") return !form.querySelector(`[name="${el.name}"]:checked`);
      return !String(el.value || "").trim();
    }) as HTMLElement[];
    if (bad.length) {
      this.error("Please fill in the highlighted fields.");
      safe(() => bad[0].focus());
      return false;
    }
    const email = form.querySelector('input[type="email"]') as HTMLInputElement | null;
    if (email && email.value && !/^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/.test(email.value)) {
      this.error("Enter a valid email address.");
      return false;
    }
    const tel = form.querySelector('input[type="tel"]') as HTMLInputElement | null;
    if (tel && tel.value && tel.value.replace(/[^\d]/g, "").length < 6) {
      this.error("Enter a valid phone number.");
      return false;
    }
    this.error("");
    return true;
  }

  private onSubmit(e: Event): void {
    e.preventDefault();
    if (this.busy) return;
    const form = e.target as HTMLFormElement;
    if (form.getAttribute("data-lemu-form") !== null && this.variant.kind === "code") {
      const data: Dict = {};
      Array.from(form.elements).forEach((el: Dict) => {
        if (el.name) data[el.name] = el.type === "checkbox" ? !!el.checked : el.value;
      });
      this.send(data);
      return;
    }
    if (this.otpPending) {
      const otp = (form.querySelector('[name="_otp"]') as HTMLInputElement | null)?.value || "";
      this.send(this.answers, otp);
      return;
    }
    if (!this.validate()) return;
    this.collect();
    if ((form as Dict)._hp && (form as Dict)._hp.value) return; // bots
    this.send(this.answers);
  }

  private send(fields: Dict, otp?: string): void {
    this.busy = true;
    const button = this.root!.querySelector('button[type="submit"]') as HTMLButtonElement | null;
    if (button) button.disabled = true;
    const ctx = submitContext(this.ctx);
    const phoneCC = (this.root!.querySelector("select[name$='__cc']") as HTMLSelectElement | null)?.value;
    const request =
      this.env.key === "__preview__"
        ? Promise.resolve({ status: 200, data: { ok: true, offer: this.exp.capture.offer ? { code: "PREVIEW10", headline: "Your offer" } : null } })
        : postJSON(`${this.env.host}/api/v1/pixel/onsite/submit`, {
      writeKey: this.env.key,
      experience: this.exp.key,
      variant: this.variant.key,
      anonymousId: this.env.anonymousId(),
      userId: this.env.userId(),
      fields,
      otp,
      context: { ...ctx, phone_country: phoneCC || "+91" },
    });
    request
      .then(({ status, data }: { status: number; data: Dict }) => {
        this.busy = false;
        if (button) button.disabled = false;
        if (data && data.verify) return this.askOtp(data.errors && data.errors._otp);
        if (!data || !data.ok) {
          const errors = (data && data.errors) || {};
          const first = errors._form || Object.keys(errors).map((k) => errors[k])[0];
          this.error(first || (status === 429 ? "Please try again in a minute." : "Something went wrong. Please try again."));
          return;
        }
        this.otpPending = false;
        this.offer = data.offer || null;
        this.prize = data.offer && data.offer.prize ? { label: data.offer.prize } : null;
        const h = seen(this.exp.key);
        h.submitted = Date.now();
        persist();
        this.hooks.submitted(this);
        const after = () => {
          const successIndex = this.steps.findIndex((s, i) => i > this.stepIndex && (s.id === "success" || !s.blocks.some((b) => b.type === "field")));
          if (successIndex > 0) {
            this.stepIndex = successIndex;
            this.renderStep();
          } else this.close(false);
        };
        if (this.prize) this.spinTo(String(this.prize.label), after);
        else after();
      })
      .catch(() => {
        this.busy = false;
        if (button) button.disabled = false;
        this.error("Couldn't send. Check your connection and try again.");
      });
  }

  private askOtp(error?: string): void {
    this.otpPending = true;
    const form = this.form();
    if (!form) return;
    let box = form.querySelector('[data-lx="otp"]') as HTMLElement | null;
    if (!box) {
      const label: HTMLElement = d.createElement("label");
      label.className = "lx-field";
      label.setAttribute("data-lx", "otp");
      label.innerHTML = '<span>Enter the code we sent on WhatsApp</span><input name="_otp" inputmode="numeric" autocomplete="one-time-code" maxlength="6" required>';
      const submit = form.querySelector('button[type="submit"]');
      form.insertBefore(label, submit);
      box = label;
      Array.from(form.querySelectorAll(".lx-field:not([data-lx='otp']), .lx-check")).forEach((el) => ((el as HTMLElement).style.display = "none"));
    }
    this.error(error || "");
    safe(() => (box!.querySelector("input") as HTMLInputElement).focus());
  }

  private spinTo(label: string, done: () => void): void {
    const svg = this.root!.querySelector('[data-lx="wheel"]') as SVGElement | null;
    const slices = ((this.currentStep()?.blocks || []).filter((b) => b.type === "wheel")[0] || {}).slices || [];
    const i = Math.max(0, slices.findIndex((s: Dict) => s.label === label));
    if (!svg || !slices.length) return done();
    const per = 360 / slices.length;
    const target = 360 * 6 - (i * per + per / 2);
    svg.style.transform = `rotate(${target}deg)`;
    setTimeout(done, 4300);
  }

  // ── Closing ───────────────────────────────────────────────────────────────

  track(event: string, extra: Dict): void {
    this.env.track(event, {
      experience_id: this.exp.id,
      experience: this.exp.key,
      variant: this.variant.key,
      version: this.exp.version,
      format: this.exp.format,
      page_type: this.ctx.page_type,
      ...extra,
    });
  }

  close(byUser: boolean): void {
    if (byUser && this.content.teaser && this.content.teaser.show === "after_close" && this.exp.format === "popup") {
      this.recordClose();
      this.expanded = false;
      openModal = null;
      this.teaser(false);
      return;
    }
    if (byUser) this.recordClose();
    this.destroy();
    this.hooks.closed(this, byUser);
  }

  private recordClose(): void {
    const h = seen(this.exp.key);
    h.closes++;
    h.lastClose = Date.now();
    persist();
    this.track("onsite_closed", {});
  }

  destroy(): void {
    this.timers.forEach((t) => clearInterval(t));
    this.timers = [];
    if (this.replaced) this.replaced.style.display = "";
    if (this.host && this.host.parentNode) this.host.parentNode.removeChild(this.host);
    if (openModal === this) {
      openModal = null;
      safe(() => (this.lastFocus as HTMLElement | null)?.focus());
    }
    this.host = null;
  }
}

function price(i: Dict): string {
  if (i.price == null || i.price === "") return "";
  const symbol = i.currency === "INR" || !i.currency ? "₹" : i.currency + " ";
  return symbol + Number(i.price).toLocaleString("en-IN");
}

function positionCss(position: string): string {
  const [v, h] = String(position).split("_");
  return `${v === "top" ? "top" : "bottom"}:16px;${h === "right" ? "right" : "left"}:16px`;
}
