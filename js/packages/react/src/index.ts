/**
 * @lemuai/react: Lemu tracking for React and Next.js.
 *
 *   <LemuProvider writeKey="lpk_..." options={{ debug: true }}>
 *     <App />
 *   </LemuProvider>
 *
 *   const lemu = useLemu();
 *   lemu.track(LemuEvent.AddToCart, { value: 999, currency: "INR" });
 *
 * Server-side rendering is safe: nothing touches `window` during render, and
 * the client's methods do nothing on the server.
 */
import { lemu as sharedClient, type BrowserOptions, type LemuBrowser } from "@lemuai/analytics";
import { createContext, createElement, type ReactNode, useContext, useEffect, useRef } from "react";

export { LemuEvent, createLemu } from "@lemuai/analytics";
export type { BrowserOptions, LemuBrowser, LemuEventName, Properties, PurchaseProperties } from "@lemuai/analytics";

const LemuContext = createContext<LemuBrowser | null>(null);

export interface LemuProviderProps {
  /** Your source's public write key. */
  writeKey: string;
  options?: BrowserOptions;
  /** A client from `createLemu()`. Defaults to the shared `lemu` client. */
  client?: LemuBrowser;
  children?: ReactNode;
}

/** Starts Lemu in the browser (after mount) and makes the client available to `useLemu()`. */
export function LemuProvider(props: LemuProviderProps) {
  const client = props.client || sharedClient;
  const options = useRef(props.options);
  useEffect(() => {
    // Effects never run during server rendering; init ignores repeat calls.
    client.init(props.writeKey, options.current);
  }, [client, props.writeKey]);
  return createElement(LemuContext.Provider, { value: client }, props.children);
}

/** The Lemu client from the nearest `LemuProvider`, or the shared client. */
export function useLemu(): LemuBrowser {
  return useContext(LemuContext) || sharedClient;
}

/**
 * Sends `page()` whenever `pathname` changes.
 *
 *   React Router: usePageTracking(useLocation().pathname)
 *   Next.js app router: usePageTracking(usePathname())
 */
export function usePageTracking(pathname: string | null | undefined, properties?: Record<string, unknown>): void {
  const client = useLemu();
  const props = useRef(properties);
  props.current = properties;
  useEffect(() => {
    if (pathname == null) return;
    client.page(props.current);
  }, [client, pathname]);
}
