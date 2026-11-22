import type { Dict } from "./types";

/* CSS inside each experience's shadow root. Theme tokens arrive as custom
 * properties (same names as landing pages: api/services/onsite/theme.py). */

const SHADOWS: Dict = {
  none: "none",
  soft: "0 10px 30px rgba(0,0,0,.14)",
  strong: "0 20px 50px rgba(0,0,0,.3)",
};

export function themeVars(theme: Dict, style: Dict): string {
  const pick = (k: string, fallback: string) => {
    const v = style[k] != null && style[k] !== "" ? style[k] : theme[k];
    return v != null && v !== "" ? String(v).replace(/[;{}<>]/g, "") : fallback;
  };
  const font = pick("font_family", "site");
  const radius = style.radius != null ? style.radius : theme.radius != null ? theme.radius : 12;
  return [
    `--lemu-primary:${pick("primary_color", "#111827")}`,
    `--lemu-text:${style.text_color || theme.text_color || "#111827"}`,
    `--lemu-bg:${style.background || theme.background_color || "#ffffff"}`,
    `--lemu-muted:${pick("muted_color", "#6b7280")}`,
    `--lemu-button-text:${pick("button_text_color", "#ffffff")}`,
    `--lemu-overlay:${pick("overlay_color", "rgba(17,24,39,.55)")}`,
    `--lemu-font:${font === "site" ? "inherit" : font}`,
    `--lemu-heading-font:${theme.heading_font_family ? String(theme.heading_font_family).replace(/[;{}<>]/g, "") : "var(--lemu-font)"}`,
    `--lemu-font-size:${theme.base_font_size || 15}px`,
    `--lemu-radius:${Number(radius) || 0}px`,
    `--lemu-button-radius:${theme.button_style === "pill" ? 999 : theme.button_radius != null ? theme.button_radius : 8}px`,
    `--lemu-shadow:${SHADOWS[theme.shadow] || SHADOWS.soft}`,
  ].join(";");
}

export const CSS = `
:host{all:initial;font-family:var(--lemu-font);font-size:var(--lemu-font-size);color:var(--lemu-text);line-height:1.5}
*,*::before,*::after{box-sizing:border-box}
.lx-overlay{position:fixed;inset:0;background:var(--lemu-overlay);z-index:2147483000;display:flex;align-items:center;justify-content:center;padding:16px;animation:lxfade .2s ease}
.lx-box{position:relative;background:var(--lemu-bg);color:var(--lemu-text);border-radius:var(--lemu-radius);box-shadow:var(--lemu-shadow);width:100%;max-height:calc(100vh - 32px);overflow:auto;display:flex}
.lx-s{max-width:380px}.lx-m{max-width:520px}.lx-l{max-width:760px}.lx-full{max-width:none;height:calc(100vh - 32px)}
.lx-body{padding:28px;flex:1;min-width:0}
.lx-media{flex:0 0 42%;background-size:cover;background-position:center;min-height:200px}
.lx-media-top{flex-direction:column}.lx-media-top .lx-media{flex-basis:180px}
.lx-media-right{flex-direction:row-reverse}
.lx-media-background{background-size:cover;background-position:center}
.lx-float{position:fixed;z-index:2147483000;width:min(380px,calc(100vw - 32px));animation:lxup .25s ease}
.lx-bottom_right{right:16px;bottom:16px}.lx-bottom_left{left:16px;bottom:16px}.lx-top_right{right:16px;top:16px}.lx-top_left{left:16px;top:16px}
.lx-bar{position:fixed;left:0;right:0;z-index:2147482999;background:var(--lemu-primary);color:var(--lemu-button-text);display:flex;align-items:center;justify-content:center;gap:12px;padding:10px 44px 10px 16px;flex-wrap:wrap;text-align:center;animation:lxfade .2s}
.lx-bar.lx-top{top:0}.lx-bar.lx-bottom{bottom:0}.lx-bar.lx-static{position:relative}
.lx-bar .lx-step{display:flex;align-items:center;justify-content:center;gap:10px;flex-wrap:wrap}
.lx-bar .lx-text,.lx-bar h1,.lx-bar h2,.lx-bar h3{margin:0;color:inherit}
.lx-bar .lx-btn-primary{background:var(--lemu-button-text);color:var(--lemu-primary)}
.lx-bar .lx-field{min-width:180px}.lx-bar .lx-field>span{display:none}
.lx-bar .lx-close{color:inherit}
.lx-inline{display:block;margin:12px 0;color:var(--lemu-text);animation:lxfade .2s}
.lx-inline.lx-border{border:1px solid rgba(127,127,127,.3);border-radius:var(--lemu-radius);padding:16px;background:var(--lemu-bg)}
.lx-inline .lx-body{padding:0}
.lx-toast{position:fixed;z-index:2147483000;max-width:min(340px,calc(100vw - 32px));background:var(--lemu-bg);border-radius:var(--lemu-radius);box-shadow:var(--lemu-shadow);padding:12px 36px 12px 14px;font-size:.92em;animation:lxup .25s}
.lx-teaser{position:fixed;z-index:2147482998;bottom:24px;background:var(--lemu-primary);color:var(--lemu-button-text);border:0;font:inherit;font-weight:600;padding:10px 16px;cursor:pointer;box-shadow:var(--lemu-shadow)}
.lx-teaser.lx-left{left:0;border-radius:0 var(--lemu-button-radius) var(--lemu-button-radius) 0}
.lx-teaser.lx-right{right:0;border-radius:var(--lemu-button-radius) 0 0 var(--lemu-button-radius)}
.lx-fab{position:fixed;z-index:2147482998;bottom:20px;display:flex;align-items:center;gap:8px;background:var(--lemu-primary);color:var(--lemu-button-text);border:0;border-radius:999px;padding:12px 18px;font:inherit;font-weight:600;cursor:pointer;box-shadow:var(--lemu-shadow)}
.lx-fab.lx-bottom_right{right:20px}.lx-fab.lx-bottom_left{left:20px}
.lx-fab svg{width:18px;height:18px}
.lx-close{position:absolute;top:8px;right:8px;width:32px;height:32px;border:0;background:transparent;color:var(--lemu-muted);font-size:22px;line-height:1;cursor:pointer;border-radius:50%}
.lx-close:hover{background:rgba(127,127,127,.15)}
.lx-step{display:grid;gap:12px}
h1,h2,h3{font-family:var(--lemu-heading-font);margin:0;line-height:1.2;color:inherit}
h1{font-size:1.9em}h2{font-size:1.45em}h3{font-size:1.15em}
.lx-text{margin:0;color:inherit}.lx-text.lx-muted{color:var(--lemu-muted)}
.lx-center{text-align:center}
.lx-img{max-width:100%;border-radius:calc(var(--lemu-radius)/1.5);display:block}
.lx-btn{display:inline-flex;align-items:center;justify-content:center;min-height:44px;padding:0 20px;border-radius:var(--lemu-button-radius);border:2px solid var(--lemu-primary);font:inherit;font-weight:600;cursor:pointer;text-decoration:none;width:100%}
.lx-btn-primary{background:var(--lemu-primary);color:var(--lemu-button-text)}
.lx-btn-secondary{background:transparent;color:var(--lemu-primary)}
.lx-btn-link{background:none;border:0;color:var(--lemu-primary);text-decoration:underline;min-height:auto;padding:0;width:auto}
.lx-btn[disabled]{opacity:.6;cursor:wait}
.lx-dismiss{background:none;border:0;color:var(--lemu-muted);font:inherit;font-size:.9em;cursor:pointer;text-decoration:underline;justify-self:center}
.lx-field{display:grid;gap:4px;border:0;margin:0;padding:0;min-width:0}
.lx-field>span,.lx-field legend{font-size:.85em;font-weight:600}
.lx-field input,.lx-field select,.lx-field textarea{font:inherit;width:100%;min-height:44px;padding:9px 12px;border:1.5px solid rgba(127,127,127,.45);border-radius:calc(var(--lemu-radius)/1.5);background:#fff;color:#111}
.lx-filled input,.lx-filled select,.lx-filled textarea{background:rgba(127,127,127,.1);border-color:transparent}
.lx-underline input,.lx-underline select,.lx-underline textarea{border-width:0 0 1.5px;border-radius:0;background:transparent;color:inherit}
.lx-field input:focus,.lx-field select:focus,.lx-field textarea:focus{outline:2px solid var(--lemu-primary);outline-offset:1px}
.lx-phone{display:flex;gap:6px}.lx-phone select{flex:0 0 86px}
.lx-chips{display:flex;flex-wrap:wrap;gap:8px}
.lx-chip{position:relative}
.lx-chip input{position:absolute;opacity:0;pointer-events:none}
.lx-chip span{display:inline-flex;align-items:center;justify-content:center;min-width:42px;min-height:38px;padding:0 14px;border:1.5px solid rgba(127,127,127,.45);border-radius:999px;cursor:pointer;font-size:.92em}
.lx-chip input:checked+span{background:var(--lemu-primary);border-color:var(--lemu-primary);color:var(--lemu-button-text)}
.lx-chip input:focus-visible+span{outline:2px solid var(--lemu-primary);outline-offset:2px}
.lx-check{display:flex;gap:8px;align-items:flex-start;font-size:.85em;color:var(--lemu-muted)}
.lx-check input{width:18px;height:18px;margin-top:2px;accent-color:var(--lemu-primary)}
.lx-err{color:#b91c1c;font-size:.85em;margin:0}
.lx-hp{position:absolute!important;left:-9999px!important;width:1px;height:1px}
.lx-code{display:flex;align-items:center;justify-content:center;gap:10px;flex-wrap:wrap}
.lx-code strong{font-family:ui-monospace,Menlo,monospace;font-size:1.4em;letter-spacing:.06em;border:2px dashed var(--lemu-primary);padding:8px 14px;border-radius:8px}
.lx-countdown{display:flex;gap:8px;justify-content:center;font-variant-numeric:tabular-nums}
.lx-countdown span{display:grid;min-width:52px;padding:6px;border-radius:8px;background:rgba(127,127,127,.12);text-align:center}
.lx-countdown b{font-size:1.3em}.lx-countdown small{font-size:.7em;opacity:.8}
.lx-countdown.lx-compact span{min-width:0;padding:2px 6px;background:transparent}
.lx-progress{display:grid;gap:6px;width:min(520px,100%)}
.lx-track{height:6px;border-radius:99px;background:rgba(255,255,255,.35);overflow:hidden}
.lx-track i{display:block;height:100%;background:currentColor;transition:width .4s}
.lx-products{display:grid;grid-template-columns:repeat(auto-fill,minmax(130px,1fr));gap:12px}
.lx-product{text-decoration:none;color:inherit;display:grid;gap:4px;font-size:.9em}
.lx-product img{width:100%;aspect-ratio:1;object-fit:cover;border-radius:calc(var(--lemu-radius)/1.5);background:rgba(127,127,127,.1)}
.lx-product b{font-weight:600}.lx-product em{font-style:normal;color:var(--lemu-muted)}
.lx-cols{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px}
.lx-divider{border:0;border-top:1px solid rgba(127,127,127,.25);margin:4px 0}
.lx-wheel{width:240px;height:240px;margin:0 auto;position:relative}
.lx-wheel svg{width:100%;height:100%;transition:transform 4s cubic-bezier(.17,.67,.12,.99)}
.lx-wheel::after{content:"";position:absolute;top:-6px;left:50%;transform:translateX(-50%);border:10px solid transparent;border-top:16px solid var(--lemu-text)}
.lx-collapsed{background:none;border:0;padding:0;font:inherit;color:var(--lemu-primary);text-decoration:underline;cursor:pointer}
.lx-product-card{display:flex;gap:12px;align-items:center}.lx-product-card img{width:64px;height:64px;object-fit:cover;border-radius:8px}
@keyframes lxfade{from{opacity:0}to{opacity:1}}
@keyframes lxup{from{opacity:0;transform:translateY(12px)}to{opacity:1;transform:none}}
@media (max-width:640px){
 .lx-overlay.lx-sheet{align-items:flex-end;padding:0}
 .lx-sheet .lx-box{border-radius:var(--lemu-radius) var(--lemu-radius) 0 0;max-height:88vh;max-width:none;animation:lxup .25s}
 .lx-box{flex-direction:column}.lx-media{flex-basis:140px;min-height:140px}
 .lx-body{padding:22px 18px}
 .lx-float{left:8px;right:8px;width:auto}
}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
`;
