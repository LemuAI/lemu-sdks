// The small part of react-native and AsyncStorage this package uses. The app's
// own packages provide the real modules (and their full types) at build time.
declare module "react-native" {
  export type AppStateStatus = "active" | "background" | "inactive" | "unknown" | "extension";
  export const AppState: {
    currentState: AppStateStatus | string | null;
    addEventListener(type: "change", listener: (state: AppStateStatus) => void): { remove(): void };
  };
  export const Linking: {
    getInitialURL(): Promise<string | null>;
    addEventListener(type: "url", handler: (event: { url: string }) => void): { remove(): void };
  };
  export const Platform: {
    OS: string;
    Version: number | string;
    isPad?: boolean;
    isTV?: boolean;
  };
  export const Dimensions: {
    get(dim: "window" | "screen"): { width: number; height: number; scale: number; fontScale: number };
  };
}

declare module "@react-native-async-storage/async-storage" {
  const AsyncStorage: {
    getItem(key: string): Promise<string | null>;
    setItem(key: string, value: string): Promise<void>;
    removeItem(key: string): Promise<void>;
  };
  export default AsyncStorage;
}
