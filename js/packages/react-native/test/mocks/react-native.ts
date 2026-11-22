import { createElement } from "react";

/** Test doubles for the parts of react-native the SDK uses. */
type Listener<T> = (value: T) => void;

const appStateListeners: Array<Listener<string>> = [];
const urlListeners: Array<Listener<{ url: string }>> = [];
let initialURL: string | null = null;

export const AppState = {
  currentState: "active" as string,
  addEventListener(_type: "change", listener: Listener<string>) {
    appStateListeners.push(listener);
    return { remove: () => appStateListeners.splice(appStateListeners.indexOf(listener) >>> 0, 1) };
  },
};

export const opened: string[] = [];

export const Linking = {
  getInitialURL: () => Promise.resolve(initialURL),
  openURL: (url: string) => {
    opened.push(url);
    return Promise.resolve(true);
  },
  addEventListener(_type: "url", listener: Listener<{ url: string }>) {
    urlListeners.push(listener);
    return { remove: () => urlListeners.splice(urlListeners.indexOf(listener) >>> 0, 1) };
  },
};

export const Platform = { OS: "ios", Version: "17.2", isPad: false, isTV: false };

export const Dimensions = {
  get: () => ({ width: 393, height: 852, scale: 3, fontScale: 1 }),
};

export const Keyboard = {
  addListener: () => ({ remove() {} }),
};

export const StatusBar = { currentHeight: 0 };

/** Components render as plain host elements named after the component, so
 * react-dom/server can turn a tree into markup in tests. */
function host(tag: string) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const C = (props: any) => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const out: any = {};
    for (const k in props) {
      const v = props[k];
      if (k === "children") continue;
      if (typeof v === "string" || typeof v === "number" || typeof v === "boolean") out["data-" + k.toLowerCase()] = String(v);
    }
    if (tag === "lemu-textinput") out["data-value"] = String(props.value == null ? "" : props.value);
    if (tag === "lemu-image") out["data-uri"] = props.source && props.source.uri;
    return createElement(tag, out, props.children);
  };
  return C;
}

export const View = host("lemu-view");
export const Text = host("lemu-text");
export const TextInput = host("lemu-textinput");
export const Image = host("lemu-image");
export const Modal = host("lemu-modal");
export const Pressable = host("lemu-pressable");
export const ScrollView = host("lemu-scrollview");
export const SafeAreaView = host("lemu-safeareaview");
export const KeyboardAvoidingView = host("lemu-keyboardavoidingview");

/** Test controls. */
export const mock = {
  setAppState(state: string) {
    AppState.currentState = state;
    for (const l of appStateListeners.slice()) l(state);
  },
  openURL(url: string) {
    for (const l of urlListeners.slice()) l({ url });
  },
  setInitialURL(url: string | null) {
    initialURL = url;
  },
  reset() {
    opened.length = 0;
    appStateListeners.length = 0;
    urlListeners.length = 0;
    initialURL = null;
    AppState.currentState = "active";
  },
};
