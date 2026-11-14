/**
 * Event names every Lemu SDK exposes, copied from sdks/spec/events.json
 * (test/events.test.ts checks they match). Standard events use Meta's names
 * exactly, so the same name works for the Meta pixel and for Lemu.
 */
export const LemuEvent = {
  // Meta standard events
  PageView: "PageView",
  ViewContent: "ViewContent",
  Search: "Search",
  AddToCart: "AddToCart",
  AddToWishlist: "AddToWishlist",
  InitiateCheckout: "InitiateCheckout",
  AddPaymentInfo: "AddPaymentInfo",
  Purchase: "Purchase",
  Lead: "Lead",
  CompleteRegistration: "CompleteRegistration",
  Subscribe: "Subscribe",
  StartTrial: "StartTrial",
  Schedule: "Schedule",
  SubmitApplication: "SubmitApplication",
  Contact: "Contact",
  CustomizeProduct: "CustomizeProduct",
  Donate: "Donate",
  FindLocation: "FindLocation",
  // App lifecycle events
  AppInstalled: "app_installed",
  AppUpdated: "app_updated",
  AppOpened: "app_opened",
  AppBackgrounded: "app_backgrounded",
  DeepLinkOpened: "deep_link_opened",
  ScreenViewed: "screen_viewed",
} as const;

export type LemuEventName = (typeof LemuEvent)[keyof typeof LemuEvent];
