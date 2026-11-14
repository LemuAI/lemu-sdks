# @lemuai/react

Lemu tracking for React and Next.js: a provider, a hook for the client, and page tracking for React Router and the Next.js app router. Built on [`@lemuai/analytics`](../analytics).

Safe with server-side rendering: nothing touches `window` during render, and calls made on the server do nothing.

## Install

```bash
npm install @lemuai/react
```

## Quick start

Wrap your app once:

```tsx
import { LemuProvider } from "@lemuai/react";

export function App() {
  return (
    <LemuProvider writeKey="YOUR_WRITE_KEY" options={{ debug: false }}>
      <Routes />
    </LemuProvider>
  );
}
```

Send events from any component:

```tsx
import { LemuEvent, useLemu } from "@lemuai/react";

function AddToCartButton({ product }) {
  const lemu = useLemu();
  return (
    <button
      onClick={() =>
        lemu.track(LemuEvent.AddToCart, {
          value: product.price,
          currency: "INR",
          content_ids: [product.sku],
        })
      }
    >
      Add to cart
    </button>
  );
}
```

## Page views

`usePageTracking(pathname)` sends `page()` whenever the path changes.

React Router:

```tsx
import { useLocation } from "react-router-dom";
import { usePageTracking } from "@lemuai/react";

function PageTracker() {
  usePageTracking(useLocation().pathname);
  return null;
}
```

Next.js app router (`app/layout.tsx`):

```tsx
// app/lemu.tsx
"use client";
import { usePathname } from "next/navigation";
import { LemuProvider, usePageTracking } from "@lemuai/react";

function PageTracker() {
  usePageTracking(usePathname());
  return null;
}

export function Lemu({ children }: { children: React.ReactNode }) {
  return (
    <LemuProvider writeKey={process.env.NEXT_PUBLIC_LEMU_WRITE_KEY!}>
      <PageTracker />
      {children}
    </LemuProvider>
  );
}
```

```tsx
// app/layout.tsx
import { Lemu } from "./lemu";

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Lemu>{children}</Lemu>
      </body>
    </html>
  );
}
```

Next.js pages router: call `usePageTracking(useRouter().asPath)` in `_app.tsx`.

## Purchases

```tsx
const lemu = useLemu();
lemu.purchase({ value: 1499.5, currency: "INR", order_id: order.id });
```

`purchase()` is sent at once. `order_id` lets Lemu count one conversion per order however many sources report it (this page, a webhook, a reload of the thank-you page), so always pass your real order id.

## Identify, consent and opt-out

```tsx
const lemu = useLemu();

// after sign-up or login
lemu.identify(user.id, { email: user.email, phone: user.phone, first_name: user.firstName });

// on logout
lemu.reset();
```

To wait for consent, pass `options={{ requireConsent: true }}` to the provider and call `lemu.setConsent(true)` from your consent banner. Nothing is sent or stored until then. `lemu.optOut()` and `lemu.optIn()` turn tracking off and on, remembered in the browser.

## Debug mode

`<LemuProvider writeKey="..." options={{ debug: true }}>` logs every call, request and response to the console.

## API

| Export | |
|---|---|
| `LemuProvider` | Props: `writeKey`, `options` (see [@lemuai/analytics options](../analytics#options)), optional `client` from `createLemu()`. Starts tracking after mount |
| `useLemu()` | The client: `track`, `page`, `purchase`, `identify`, `reset`, `flush`, `setConsent`, `optOut`, `optIn`, `anonymousId` |
| `usePageTracking(pathname, properties?)` | `page()` on every path change |
| `LemuEvent` | Standard event names (Meta's names), see [the table](../analytics#standard-events) |
| `createLemu()` | A separate client |

`useLemu()` works outside a provider too. It returns the shared client; calls made before a provider starts it are kept and sent once it does.

## License

MIT
