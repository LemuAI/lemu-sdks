import { rememberProduct, setCart, visitor } from "./state";
import type { Bundle, Context, Dict, Product, UrlRule } from "./types";
import { d, getJSON, safe, w } from "./util";

/*
 * What the page is: URL, page type (sitemap rules, else Shopify paths or the
 * product on the page), the product being viewed (lemu("onsite.context"),
 * Shopify, JSON-LD, or the last ViewContent), and the cart.
 */

let explicit: Dict = {};
let lastViewed: Product | undefined;
const listeners: Array<() => void> = [];

export function onContextChange(fn: () => void): void {
  listeners.push(fn);
}

function changed(): void {
  for (const fn of listeners) safe(fn);
}

export function setContext(values: Dict): void {
  explicit = { ...explicit, ...(values || {}) };
  if (values && values.product) rememberProduct(values.product.sku || values.product.id);
  changed();
}

export function urlMatches(rule: UrlRule, pageType: string): boolean {
  const loc = w.location || {};
  const href = String(loc.href || "");
  const path = String(loc.pathname || "/");
  const v = String(rule.value || "");
  switch (rule.type) {
    case "any":
      return true;
    case "url_equals":
      return href.split("#")[0] === v || href.split("?")[0] === v;
    case "url_contains":
      return href.indexOf(v) >= 0;
    case "url_matches":
      return !!safe(() => new RegExp(v).test(href), false);
    case "path_equals":
      return path.replace(/\/+$/, "") === v.replace(/\/+$/, "") || (v === "/" && path === "/");
    case "path_prefix":
      return path.indexOf(v) === 0;
    case "page_type":
      return pageType === v;
    case "query_has":
      return new RegExp("[?&]" + v.replace(/[^\w-]/g, "") + "(=|&|$)").test(String(loc.search || ""));
    default:
      return false;
  }
}

function shopify(): boolean {
  return !!(w.Shopify && w.Shopify.shop) || !!w.ShopifyAnalytics;
}

export function pageType(bundle: Bundle): string {
  if (explicit.page_type) return String(explicit.page_type);
  for (const t of bundle.page_types || []) {
    if ((t.rules || []).some((r) => urlMatches(r, ""))) return t.name;
  }
  const path = String((w.location || {}).pathname || "/");
  if (shopify()) {
    if (path === "/" ) return "home";
    if (/\/products\//.test(path)) return "product";
    if (/\/collections\//.test(path)) return "collection";
    if (/^\/cart/.test(path)) return "cart";
    if (/\/checkouts?\//.test(path)) return "checkout";
    if (/thank_you|orders\//.test(path)) return "thank_you";
  }
  if (product()) return "product";
  return path === "/" ? "home" : "other";
}

function jsonLdProduct(): Product | undefined {
  const scripts = d.querySelectorAll ? d.querySelectorAll('script[type="application/ld+json"]') : [];
  for (let i = 0; i < scripts.length; i++) {
    const data = safe(() => JSON.parse(scripts[i].textContent || ""));
    const items = Array.isArray(data) ? data : data && data["@graph"] ? data["@graph"] : [data];
    for (const item of items) {
      if (item && (item["@type"] === "Product" || (Array.isArray(item["@type"]) && item["@type"].indexOf("Product") >= 0))) {
        const offer = Array.isArray(item.offers) ? item.offers[0] : item.offers || {};
        return {
          id: item.productID || item.sku,
          sku: item.sku,
          title: item.name,
          price: Number(offer.price) || undefined,
          currency: offer.priceCurrency,
          image_url: Array.isArray(item.image) ? item.image[0] : item.image,
          url: w.location.href,
          in_stock: offer.availability ? !/OutOfStock|SoldOut/i.test(String(offer.availability)) : undefined,
        };
      }
    }
  }
  return undefined;
}

let shopifyProduct: Product | undefined;

/** Shopify: /products/<handle>.js gives variants with availability. */
export function loadShopifyProduct(): Promise<void> {
  const path = String((w.location || {}).pathname || "");
  const m = path.match(/^(.*\/products\/[^/?#]+)/);
  if (!shopify() || !m) return Promise.resolve();
  return getJSON(m[1] + ".js")
    .then((p: Dict) => {
      if (!p || !p.variants) return;
      shopifyProduct = {
        id: String(p.id),
        title: p.title,
        url: w.location.origin + m[1],
        image_url: p.featured_image ? (String(p.featured_image).indexOf("//") === 0 ? "https:" + p.featured_image : p.featured_image) : undefined,
        options: p.options && p.options.map((o: Dict) => (typeof o === "string" ? o : o.name)),
        variants: p.variants.map((v: Dict) => ({
          id: String(v.id),
          sku: v.sku || String(v.id),
          title: v.public_title || v.title,
          available: !!v.available,
          options: v.options,
          price: v.price / 100,
        })),
      };
      watchVariantPicker();
      changed();
    })
    .catch(() => undefined);
}

function selectedVariantId(): string | undefined {
  const fromUrl = String((w.location || {}).search || "").match(/[?&]variant=(\d+)/);
  if (fromUrl) return fromUrl[1];
  const input = d.querySelector && d.querySelector('form[action*="/cart/add"] [name="id"]');
  return input && input.value ? String(input.value) : undefined;
}

let watching = false;
function watchVariantPicker(): void {
  if (watching || !d.addEventListener) return;
  watching = true;
  // Themes change the hidden id input and the URL when a size is picked.
  const check = () => setTimeout(changed, 50);
  d.addEventListener("change", check, true);
  d.addEventListener("click", (e: Dict) => {
    const t = e.target;
    if (t && t.closest && t.closest("variant-selects, variant-radios, .product-form__input, [data-variant-picker], .swatch")) check();
  }, true);
  const push = w.history && w.history.replaceState;
  if (push) {
    w.history.replaceState = function () {
      // eslint-disable-next-line prefer-rest-params
      const out = push.apply(this, arguments);
      check();
      return out;
    };
  }
}

export function product(): Product | undefined {
  if (explicit.product) return explicit.product as Product;
  if (shopifyProduct) {
    const id = selectedVariantId();
    const variant =
      (shopifyProduct.variants || []).filter((v) => v.id === id)[0] || (shopifyProduct.variants || [])[0];
    if (!variant) return shopifyProduct;
    return {
      ...shopifyProduct,
      variant_id: variant.id,
      sku: variant.sku,
      size: variant.title,
      price: variant.price,
      in_stock: variant.available,
    };
  }
  return jsonLdProduct() || lastViewed;
}

/** ViewContent / AddToCart from the site's own lemu calls. */
export function onSiteEvent(detail: Dict): void {
  const name = String(detail.event || "");
  const props = (detail.properties || {}) as Dict;
  const ids: string[] = props.content_ids || (props.contents || []).map((c: Dict) => c.id);
  if (/^viewcontent$/i.test(name.replace(/[\s_-]/g, "")) && ids && ids[0]) {
    lastViewed = { sku: String(ids[0]), id: String(ids[0]), title: props.content_name, price: props.value, currency: props.currency };
    rememberProduct(lastViewed.sku);
    changed();
  }
  if (/^addtocart$/i.test(name.replace(/[\s_-]/g, ""))) {
    const s = visitor();
    setCart(s.cart.value + (Number(props.value) || 0), s.cart.items + (Number(props.num_items) || 1));
    refreshShopifyCart();
  }
  if (/^purchase$/i.test(name)) setCart(0, 0);
}

export function refreshShopifyCart(): Promise<void> {
  if (!shopify()) return Promise.resolve();
  return getJSON("/cart.js")
    .then((c: Dict) => {
      if (c && typeof c.total_price === "number") {
        setCart(c.total_price / 100, c.item_count || 0);
        changed();
      }
    })
    .catch(() => undefined);
}

function utm(): Dict {
  const out: Dict = {};
  const q = String((w.location || {}).search || "");
  ["utm_source", "utm_medium", "utm_campaign", "utm_content", "utm_term"].forEach((k) => {
    const m = q.match(new RegExp("[?&]" + k + "=([^&#]*)"));
    if (m) out[k.slice(4)] = decodeURIComponent(m[1].replace(/\+/g, " "));
  });
  const saved = safe(() => JSON.parse(w.sessionStorage.getItem("_lemu_utm") || "{}"), {}) as Dict;
  if (Object.keys(out).length) safe(() => w.sessionStorage.setItem("_lemu_utm", JSON.stringify(out)));
  return Object.keys(out).length ? out : saved || {};
}

export function context(bundle: Bundle): Context {
  const loc = w.location || {};
  const p = product();
  if (p && p.sku) rememberProduct(p.sku);
  return {
    url: String(loc.href || ""),
    path: String(loc.pathname || "/"),
    referrer: String(d.referrer || ""),
    page_type: pageType(bundle),
    product: p,
    cart: visitor().cart,
    utm: utm(),
    locale: String((w.navigator || {}).language || ""),
  };
}

/** What a submission says about the page (no personal data). */
export function submitContext(ctx: Context): Dict {
  const p = ctx.product;
  return {
    url: ctx.url,
    path: ctx.path,
    referrer: ctx.referrer,
    page_type: ctx.page_type,
    utm: ctx.utm,
    locale: ctx.locale,
    title: d.title,
    product: p
      ? { id: p.id, variant_id: p.variant_id, sku: p.sku, title: p.title, product_title: p.title, size: p.size, price: p.price, url: p.url || ctx.url }
      : undefined,
  };
}
