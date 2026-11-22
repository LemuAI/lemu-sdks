import { createElement as h, type ReactElement, type ReactNode, useEffect, useState } from "react";
import { Image, Keyboard, KeyboardAvoidingView, Modal, Platform, Pressable, SafeAreaView, ScrollView, StatusBar, Text, TextInput, View } from "react-native";
import type { ExperienceManager } from "./manager";
import type { Theme } from "./rules";
import type { Block, Dict } from "./types";
import { ExperienceView, MESSAGES } from "./view";

/*
 * Draws the in-app message on screen with plain React Native components:
 * popup in a transparent Modal over a dimmed overlay, slide_in and toast as a
 * card at the bottom, bar as a banner at the top.
 */

const ERROR = "#dc2626";

type Style = Dict;

function useKeyboardHeight(): number {
  const [height, setHeight] = useState(0);
  useEffect(() => {
    if (Platform.OS !== "ios" || !Keyboard || typeof Keyboard.addListener !== "function") return undefined;
    const show = Keyboard.addListener("keyboardWillShow", (e) => setHeight((e && e.endCoordinates && e.endCoordinates.height) || 0));
    const hide = Keyboard.addListener("keyboardWillHide", () => setHeight(0));
    return () => {
      show.remove();
      hide.remove();
    };
  }, []);
  return height;
}

function ImageBlock(props: { url: string; radius: number }): ReactElement | null {
  const [failed, setFailed] = useState(false);
  if (failed) return null;
  return h(Image, {
    source: { uri: props.url },
    accessibilityIgnoresInvertColors: true,
    resizeMode: "contain",
    onError: () => setFailed(true),
    style: { width: "100%", height: 160, borderRadius: props.radius, marginBottom: 12 },
  });
}

function input(view: ExperienceView, b: Block, t: Theme, invalid: boolean): ReactNode {
  const name = String(b.name);
  const border = { borderWidth: 1, borderColor: invalid ? ERROR : "#d1d5db", borderRadius: 8, paddingHorizontal: 12, paddingVertical: 10, color: t.text, fontSize: 15, backgroundColor: "#ffffff" };
  const value = view.value(name);
  const label = b.label ? h(Text, { style: { color: t.text, fontSize: 14, marginBottom: 6, fontWeight: "600" } }, view.text(b.label) + (b.required ? " *" : "")) : null;
  const wrap = (child: ReactNode) => h(View, { key: name, style: { marginBottom: 12 } }, label, child);
  switch (b.input) {
    case "hidden":
      return null;
    case "consent":
    case "checkbox": {
      const checked = value === true;
      return h(
        Pressable,
        {
          key: name,
          accessibilityRole: "checkbox",
          accessibilityState: { checked },
          onPress: () => view.setValue(name, !checked),
          style: { flexDirection: "row", alignItems: "flex-start", marginBottom: 12 },
        },
        h(
          View,
          { style: { width: 22, height: 22, borderRadius: 4, borderWidth: 2, borderColor: invalid ? ERROR : checked ? t.primary : "#9ca3af", backgroundColor: checked ? t.primary : "transparent", alignItems: "center", justifyContent: "center", marginRight: 10, marginTop: 1 } },
          checked ? h(Text, { style: { color: t.buttonText, fontSize: 14, fontWeight: "700", lineHeight: 16 } }, "✓") : null,
        ),
        h(Text, { style: { flex: 1, color: t.text, fontSize: 14, lineHeight: 20 } }, view.text(b.label) + (b.required ? " *" : "")),
      );
    }
    case "select":
    case "size":
    case "chips":
    case "rating":
    case "nps":
      return wrap(
        h(
          View,
          { style: { flexDirection: "row", flexWrap: "wrap" }, accessibilityRole: "radiogroup" },
          view.choices(b).map((o) => {
            const on = String(value) === o.value;
            return h(
              Pressable,
              {
                key: o.value,
                accessibilityRole: "radio",
                accessibilityState: { selected: on },
                onPress: () => view.setValue(name, o.value),
                style: { paddingHorizontal: 14, paddingVertical: 8, borderRadius: 999, borderWidth: 1, borderColor: invalid ? ERROR : on ? t.primary : "#d1d5db", backgroundColor: on ? t.primary : "transparent", marginRight: 8, marginBottom: 8 },
              },
              h(Text, { style: { color: on ? t.buttonText : t.text, fontSize: 14 } }, o.label),
            );
          }),
        ),
      );
    case "phone":
      return wrap(
        h(
          View,
          { style: { flexDirection: "row", alignItems: "center" } },
          h(Text, { style: { color: t.text, fontSize: 15, marginRight: 8 } }, view.countryCode(b)),
          h(TextInput, {
            style: { ...border, flex: 1 },
            value: String(value == null ? "" : value),
            onChangeText: (s: string) => view.setValue(name, s),
            placeholder: b.placeholder ? String(b.placeholder) : undefined,
            placeholderTextColor: t.muted,
            keyboardType: "phone-pad",
            textContentType: "telephoneNumber",
            autoComplete: "tel",
            accessibilityLabel: b.label ? view.text(b.label) : "Phone",
          }),
        ),
      );
    default: {
      const email = b.input === "email";
      const numeric = b.input === "number" || b.input === "pincode";
      return wrap(
        h(TextInput, {
          style: { ...border, minHeight: b.input === "textarea" ? 72 : undefined },
          value: String(value == null ? "" : value),
          onChangeText: (s: string) => view.setValue(name, s),
          placeholder: b.placeholder ? String(b.placeholder) : undefined,
          placeholderTextColor: t.muted,
          keyboardType: email ? "email-address" : numeric ? "number-pad" : "default",
          autoCapitalize: email ? "none" : "sentences",
          autoCorrect: !email,
          autoComplete: email ? "email" : undefined,
          multiline: b.input === "textarea",
          accessibilityLabel: b.label ? view.text(b.label) : String(b.placeholder || name),
        }),
      );
    }
  }
}

function button(view: ExperienceView, b: Block, t: Theme, i: number): ReactNode {
  const action = b.action || "submit";
  const secondary = b.variant === "secondary" || action === "close";
  const sending = view.busy && (action === "submit" || action === "call_me");
  return h(
    Pressable,
    {
      key: "b" + i,
      accessibilityRole: "button",
      accessibilityState: { disabled: sending },
      disabled: sending,
      onPress: () => view.press(b),
      style: {
        backgroundColor: secondary ? "transparent" : t.primary,
        borderWidth: secondary ? 1 : 0,
        borderColor: t.primary,
        borderRadius: t.buttonRadius,
        paddingVertical: 12,
        paddingHorizontal: 16,
        alignItems: "center",
        marginBottom: 8,
        opacity: sending ? 0.6 : 1,
      },
    },
    h(Text, { style: { color: secondary ? t.primary : t.buttonText, fontSize: 15, fontWeight: "600" } }, view.text(b.text || "Continue")),
  );
}

function offer(view: ExperienceView, b: Block, t: Theme, i: number): ReactNode {
  const o = view.offer;
  if (!o || (!o.code && !o.headline)) return null;
  const show = b.show || "code";
  return h(
    View,
    { key: "o" + i, style: { alignItems: "center", marginBottom: 12 } },
    o.headline && (show === "headline" || show === "both") ? h(Text, { style: { color: t.text, fontSize: 16, fontWeight: "700", marginBottom: 8, textAlign: "center" } }, String(o.headline)) : null,
    o.code && show !== "headline"
      ? h(
          View,
          { style: { flexDirection: "row", alignItems: "center", borderWidth: 1, borderStyle: "dashed", borderColor: t.primary, borderRadius: 8, paddingVertical: 8, paddingHorizontal: 12 } },
          h(Text, { selectable: true, style: { color: t.text, fontSize: 18, fontWeight: "700", letterSpacing: 1, marginRight: 12 } }, String(o.code)),
          h(
            Pressable,
            { accessibilityRole: "button", onPress: () => view.copyCode(), style: { paddingVertical: 6, paddingHorizontal: 12, borderRadius: t.buttonRadius, backgroundColor: t.primary } },
            h(Text, { style: { color: t.buttonText, fontSize: 14, fontWeight: "600" } }, view.copied ? "Copied" : String(b.copy_label || "Copy")),
          ),
        )
      : null,
    o.terms ? h(Text, { style: { color: t.muted, fontSize: 12, marginTop: 8, textAlign: "center" } }, String(o.terms)) : null,
  );
}

function otpInput(view: ExperienceView, t: Theme): ReactNode {
  const invalid = view.invalid.indexOf("_otp") >= 0;
  return h(
    View,
    { key: "_otp", style: { marginBottom: 12 } },
    h(Text, { style: { color: t.text, fontSize: 14, marginBottom: 6, fontWeight: "600" } }, MESSAGES.otpLabel),
    h(TextInput, {
      style: { borderWidth: 1, borderColor: invalid ? ERROR : "#d1d5db", borderRadius: 8, paddingHorizontal: 12, paddingVertical: 10, color: t.text, fontSize: 18, letterSpacing: 4, backgroundColor: "#ffffff" },
      value: view.otp,
      onChangeText: (s: string) => view.setOtp(s),
      keyboardType: "number-pad",
      textContentType: "oneTimeCode",
      autoComplete: "sms-otp",
      maxLength: 6,
      accessibilityLabel: MESSAGES.otpLabel,
    }),
  );
}

/** The current step's blocks. */
export function renderBlocks(view: ExperienceView, compact = false): ReactNode[] {
  const t = view.theme;
  const out: ReactNode[] = [];
  let otpShown = false;
  view.blocks.forEach((b, i) => {
    const align = b.align === "center" ? "center" : b.align === "right" ? "right" : "left";
    switch (b.type) {
      case "heading": {
        const level = Math.min(3, Math.max(1, Number(b.level) || 2));
        const size = compact ? 15 : level === 1 ? 24 : level === 2 ? 20 : 17;
        out.push(h(Text, { key: "h" + i, accessibilityRole: "header", style: { color: t.text, fontSize: size, fontWeight: "700", marginBottom: compact ? 2 : 8, textAlign: align } }, view.text(b.text)));
        break;
      }
      case "text":
        out.push(h(Text, { key: "t" + i, style: { color: b.muted ? t.muted : t.text, fontSize: compact ? 14 : 15, lineHeight: compact ? 19 : 21, marginBottom: compact ? 4 : 12, textAlign: align } }, view.text(b.text)));
        break;
      case "image":
        if (b.url) out.push(h(ImageBlock, { key: "i" + i, url: String(b.url), radius: Math.min(t.radius, 12) }));
        break;
      case "button":
        out.push(button(view, b, t, i));
        break;
      case "close":
        out.push(
          h(
            Pressable,
            { key: "c" + i, accessibilityRole: "button", onPress: () => view.close(true), style: { alignItems: "center", paddingVertical: 8 } },
            h(Text, { style: { color: t.muted, fontSize: 14, textDecorationLine: "underline" } }, view.text(b.text || "No thanks")),
          ),
        );
        break;
      case "field":
        if (!b.name) break;
        if (view.otpPending) {
          if (!otpShown) out.push(otpInput(view, t));
          otpShown = true;
          break;
        }
        out.push(input(view, b, t, view.invalid.indexOf(String(b.name)) >= 0));
        break;
      case "offer":
        out.push(offer(view, b, t, i));
        break;
      default:
        break;
    }
  });
  if (view.otpPending && !otpShown) out.unshift(otpInput(view, t));
  if (view.error) out.push(h(Text, { key: "err", accessibilityRole: "alert", accessibilityLiveRegion: "polite", style: { color: ERROR, fontSize: 14, marginTop: 4 } }, view.error));
  return out;
}

function closeButton(view: ExperienceView, t: Theme): ReactNode {
  if (view.layout.close_button === false) return null;
  return h(
    Pressable,
    {
      key: "x",
      accessibilityRole: "button",
      accessibilityLabel: "Close",
      hitSlop: { top: 10, bottom: 10, left: 10, right: 10 },
      onPress: () => view.close(true),
      style: { position: "absolute", top: 6, right: 6, width: 32, height: 32, alignItems: "center", justifyContent: "center" },
    },
    h(Text, { style: { color: t.muted, fontSize: 24, lineHeight: 26 } }, "×"),
  );
}

function card(view: ExperienceView, extra: Style, maxHeight?: number | string): ReactElement {
  const t = view.theme;
  return h(
    View,
    {
      // Touches on the card are not taps on the overlay behind it.
      onStartShouldSetResponder: () => true,
      accessibilityViewIsModal: view.exp.format === "popup",
      style: {
        backgroundColor: t.background,
        borderRadius: t.radius,
        shadowColor: "#000",
        shadowOpacity: 0.18,
        shadowRadius: 16,
        shadowOffset: { width: 0, height: 6 },
        elevation: 8,
        overflow: "hidden",
        ...extra,
      },
    },
    h(
      ScrollView,
      { style: maxHeight != null ? { maxHeight } : undefined, keyboardShouldPersistTaps: "handled", contentContainerStyle: { padding: 20, paddingRight: view.layout.close_button === false ? 20 : 40 } },
      renderBlocks(view),
    ),
    closeButton(view, t),
  );
}

/** Draws one view. */
export function renderView(view: ExperienceView, keyboard = 0): ReactElement {
  const t = view.theme;
  const format = view.exp.format;
  if (format === "popup") {
    const lay = view.layout;
    return h(
      Modal,
      { visible: true, transparent: true, animationType: "fade", statusBarTranslucent: true, onRequestClose: () => view.close(true) },
      h(
        KeyboardAvoidingView,
        { behavior: Platform.OS === "ios" ? "padding" : undefined, style: { flex: 1 } },
        h(
          Pressable,
          {
            accessible: false,
            onPress: () => {
              if (lay.close_on_overlay !== false) view.close(true);
            },
            style: { flex: 1, backgroundColor: lay.overlay === false ? "transparent" : t.overlay, alignItems: "center", justifyContent: "center", padding: 16 },
          },
          card(view, { width: "100%", maxWidth: 520 }, "85%"),
        ),
      ),
    );
  }
  if (format === "bar") {
    const top = Platform.OS === "android" ? StatusBar.currentHeight || 0 : 0;
    return h(
      View,
      { pointerEvents: "box-none", style: { position: "absolute", top: 0, left: 0, right: 0, zIndex: 1000, elevation: 1000 } },
      h(
        SafeAreaView,
        { style: { backgroundColor: t.background, shadowColor: "#000", shadowOpacity: 0.12, shadowRadius: 8, shadowOffset: { width: 0, height: 2 }, elevation: 6 } },
        h(View, { accessibilityRole: "summary", style: { paddingTop: 10 + top, paddingBottom: 10, paddingLeft: 16, paddingRight: view.layout.close_button === false ? 16 : 44 } }, renderBlocks(view, true)),
        view.layout.close_button === false
          ? null
          : h(
              Pressable,
              {
                accessibilityRole: "button",
                accessibilityLabel: "Close",
                hitSlop: { top: 10, bottom: 10, left: 10, right: 10 },
                onPress: () => view.close(true),
                style: { position: "absolute", right: 8, bottom: 8, width: 32, height: 32, alignItems: "center", justifyContent: "center" },
              },
              h(Text, { style: { color: t.muted, fontSize: 22 } }, "×"),
            ),
      ),
    );
  }
  // slide_in and toast: a card at the bottom.
  const toast = format === "toast";
  return h(
    View,
    { pointerEvents: "box-none", style: { position: "absolute", left: 0, right: 0, bottom: keyboard, zIndex: 1000, elevation: 1000 } },
    h(
      SafeAreaView,
      { pointerEvents: "box-none" },
      h(View, { pointerEvents: "box-none", style: { padding: 12, alignItems: "center" } }, card(view, { width: "100%", maxWidth: toast ? 440 : 520 }, toast ? undefined : 480)),
    ),
  );
}

/** Renders the manager's current message. Mount once, as the last child of the app's root view. */
export function ExperiencesHost(props: { manager: ExperienceManager }): ReactElement | null {
  const manager = props.manager;
  const [, setTick] = useState(0);
  useEffect(() => manager.subscribe(() => setTick((n: number) => n + 1)), [manager]);
  const keyboard = useKeyboardHeight();
  const view = manager.getCurrent();
  if (!view || view.closed) return null;
  return renderView(view, view.exp.format === "popup" ? 0 : keyboard);
}
