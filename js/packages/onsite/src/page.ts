import { context, submitContext } from "./context";
import { visitor } from "./state";
import type { Bundle, Dict, Env } from "./types";
import { d, esc, getJSON, postJSON, safe, w } from "./util";

/*
 * Landing pages: the server renders static HTML; this wires up the live
 * parts (forms, countdowns, offers, product rows). Pages published by SDK
 * embed are drawn into the brand's own page here too, in a shadow root so
 * their styles stay inside.
 */

type Root = Document | ShadowRoot;

export function hydratePage(root: Root, env: Env, bundle: Bundle | null, pageId?: number): void {
  root.querySelectorAll("form[data-lemu-page-form]").forEach((f) => form(f as HTMLFormElement, env, bundle, pageId));
  root.querySelectorAll("lemu-countdown").forEach((el) => countdown(el as HTMLElement));
  root.querySelectorAll("lemu-offer").forEach((el) => offer(el as HTMLElement, env));
  root.querySelectorAll("lemu-products").forEach((el) => products(el as HTMLElement, env));
}

function form(el: HTMLFormElement, env: Env, bundle: Bundle | null, pageId?: number): void {
  if ((el as Dict)._lemu) return;
  (el as Dict)._lemu = true;
  const id = el.getAttribute("data-lemu-page-form") || "";
  const page = Number(el.getAttribute("data-page") || pageId || 0);
  let otp = false;
  el.addEventListener("submit", (e) => {
    e.preventDefault();
    const error = el.querySelector(".lp-error") as HTMLElement | null;
    const say = (m: string) => {
      if (error) {
        error.textContent = m;
        error.hidden = !m;
      }
    };
    const fields: Dict = {};
    let missing = false;
    Array.from(el.elements).forEach((x: Dict) => {
      if (!x.name || x.name === "_otp") return;
      if (x.required && ((x.type === "checkbox" && !x.checked) || (x.type === "radio" ? !el.querySelector(`[name="${x.name}"]:checked`) : !String(x.value || "").trim()))) missing = true;
      if (x.type === "checkbox") fields[x.name] = !!x.checked;
      else if (x.type === "radio") {
        if (x.checked) fields[x.name] = x.value;
      } else fields[x.name] = x.value;
    });
    if (missing) return say("Please fill in the required fields.");
    if (fields._hp) return;
    say("");
    const button = el.querySelector('button[type="submit"]') as HTMLButtonElement | null;
    if (button) button.disabled = true;
    const ctx = bundle ? submitContext(context(bundle)) : { url: w.location.href, path: w.location.pathname, referrer: d.referrer, title: d.title };
    postJSON(`${env.host}/api/v1/pixel/onsite/submit`, {
      writeKey: env.key,
      page,
      form: id,
      anonymousId: env.anonymousId(),
      userId: env.userId(),
      fields,
      otp: otp ? (el.querySelector('[name="_otp"]') as HTMLInputElement | null)?.value : undefined,
      context: ctx,
    })
      .then(({ data }) => {
        if (button) button.disabled = false;
        if (data && data.verify) {
          otp = true;
          if (!el.querySelector('[name="_otp"]')) {
            const box = d.createElement("label");
            box.className = "lp-field";
            box.innerHTML = '<span>Enter the code we sent on WhatsApp</span><input name="_otp" inputmode="numeric" maxlength="6" autocomplete="one-time-code" required>';
            el.insertBefore(box, button);
          }
          return say((data.errors && data.errors._otp) || "");
        }
        if (!data || !data.ok) {
          const errors = (data && data.errors) || {};
          return say(errors._form || Object.keys(errors).map((k) => errors[k])[0] || "Something went wrong. Please try again.");
        }
        env.track("page_form_submitted", { lemu_page: page, form: id });
        const redirect = el.getAttribute("data-redirect");
        if (redirect && /^(https?:\/\/|\/)/.test(redirect)) {
          w.location.href = redirect;
          return;
        }
        const success = (el.parentNode as HTMLElement).querySelector(`[data-success-for="${id}"]`) as HTMLElement | null;
        el.hidden = true;
        if (success) {
          success.hidden = false;
          const slot = success.querySelector(".lp-offer-slot");
          if (slot && data.offer && data.offer.code) {
            slot.innerHTML = `<p class="lp-code">${esc(data.offer.code)}</p>${data.offer.terms ? `<p class="lp-small">${esc(data.offer.terms)}</p>` : ""}`;
          }
        }
      })
      .catch(() => {
        if (button) button.disabled = false;
        say("Couldn't send. Check your connection and try again.");
      });
  });
}

function countdown(el: HTMLElement): void {
  const end = Date.parse(el.getAttribute("data-until") || "");
  if (!end) return;
  const tick = () => {
    const left = Math.max(0, end - Date.now());
    if (!left) {
      el.innerHTML = esc(el.getAttribute("data-expired") || "");
      return;
    }
    const s = Math.floor(left / 1000);
    el.innerHTML = [
      [Math.floor(s / 86400), "days"],
      [Math.floor((s % 86400) / 3600), "hours"],
      [Math.floor((s % 3600) / 60), "minutes"],
      [s % 60, "seconds"],
    ]
      .map(([v, l]) => `<span class="lp-unit"><strong>${String(v).padStart(2, "0")}</strong><small>${l}</small></span>`)
      .join("");
    setTimeout(tick, 1000);
  };
  tick();
}

function offer(el: HTMLElement, env: Env): void {
  const head = el.getAttribute("data-head");
  if (!head) return;
  getJSON(`${env.host}/api/v1/pixel/onsite/offer?k=${encodeURIComponent(env.key)}&head=${encodeURIComponent(head)}`)
    .then((o: Dict) => {
      if (!o || (!o.headline && !o.code)) return;
      const show = el.getAttribute("data-show") || "headline";
      el.innerHTML =
        (o.headline ? `<p><strong>${esc(o.headline)}</strong></p>` : "") +
        (show !== "headline" && o.code ? `<p class="lp-code">${esc(o.code)}</p>` : "") +
        (o.terms ? `<p class="lp-small">${esc(o.terms)}</p>` : "");
    })
    .catch(() => undefined);
}

function products(el: HTMLElement, env: Env): void {
  const strategy = el.getAttribute("data-strategy") || "trending";
  const q = [
    "k=" + encodeURIComponent(env.key),
    "strategy=" + encodeURIComponent(strategy),
    "limit=" + encodeURIComponent(el.getAttribute("data-limit") || "4"),
    el.getAttribute("data-category") ? "category=" + encodeURIComponent(el.getAttribute("data-category")!) : "",
    el.getAttribute("data-skus") ? "skus=" + encodeURIComponent(el.getAttribute("data-skus")!) : strategy === "recently_viewed" ? "skus=" + encodeURIComponent(visitor().recent.join(",")) : "",
  ].filter(Boolean);
  getJSON(`${env.host}/api/v1/pixel/onsite/products?${q.join("&")}`)
    .then((data: Dict) => {
      const items = (data && data.items) || [];
      if (!items.length) return;
      el.innerHTML = `<div class="lp-grid lp-cols-${Math.min(4, Math.max(2, items.length))}">${items
        .map(
          (i: Dict) =>
            `<a class="lp-product" href="${esc(i.url || "#")}">${i.image_url ? `<img src="${esc(i.image_url)}" alt="" loading="lazy">` : ""}<span class="lp-p-title">${esc(i.title)}</span><span class="lp-p-price">${i.price != null ? "₹" + esc(Number(i.price).toLocaleString("en-IN")) : ""}</span></a>`
        )
        .join("")}</div>`;
    })
    .catch(() => undefined);
}

/** Pages published by SDK embed: draw the one for this path. */
export function embedPages(bundle: Bundle, env: Env): void {
  const path = String((w.location || {}).pathname || "/").replace(/\/+$/, "") || "/";
  const match = (bundle.pages || []).filter((p) => p.path.replace(/\/+$/, "") === path)[0];
  const placeholder = d.querySelector("[data-lemu-page]") as HTMLElement | null;
  const wanted = placeholder ? placeholder.getAttribute("data-lemu-page") : null;
  const page = wanted ? (bundle.pages || []).filter((p) => p.slug === wanted)[0] || match : match;
  if (!page) return;
  const target = placeholder || (d.querySelector("main") as HTMLElement | null);
  if (!target) return;
  w.fetch(`${env.host}/api/v1/pages-origin/${encodeURIComponent(page.site)}/fragment/${encodeURIComponent(page.slug)}`, { credentials: "omit" })
    .then((r: Dict) => (r.ok ? r.text() : ""))
    .then((html: string) => {
      if (!html) return;
      const host = d.createElement("div");
      host.setAttribute("data-lemu-page-embed", page.slug);
      const root = host.attachShadow ? host.attachShadow({ mode: "open" }) : (host as unknown as ShadowRoot);
      // Scripts in the fragment don't run here; this runtime is already loaded.
      (root as unknown as HTMLElement).innerHTML = html.replace(/<script[\s\S]*?<\/script>/gi, "").replace(/:root\{/g, ":host{");
      if (placeholder) placeholder.replaceChildren(host);
      else {
        target.innerHTML = "";
        target.appendChild(host);
      }
      safe(() => env.track("PageView", { lemu_page: page.page, embedded: true }));
      hydratePage(root, env, bundle, page.page);
    })
    .catch(() => undefined);
}
