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

export const Linking = {
  getInitialURL: () => Promise.resolve(initialURL),
  addEventListener(_type: "url", listener: Listener<{ url: string }>) {
    urlListeners.push(listener);
    return { remove: () => urlListeners.splice(urlListeners.indexOf(listener) >>> 0, 1) };
  },
};

export const Platform = { OS: "ios", Version: "17.2", isPad: false, isTV: false };

export const Dimensions = {
  get: () => ({ width: 393, height: 852, scale: 3, fontScale: 1 }),
};

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
    appStateListeners.length = 0;
    urlListeners.length = 0;
    initialURL = null;
    AppState.currentState = "active";
  },
};
