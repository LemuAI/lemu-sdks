/// Event names Lemu understands. Meta standard events are spelled exactly as
/// Meta defines them, so ads platforms receive them unchanged.
///
/// Any other name works with `track()` too; these constants only prevent
/// typos.
abstract final class LemuEvent {
  // Meta standard events.
  static const String pageView = 'PageView';
  static const String viewContent = 'ViewContent';
  static const String search = 'Search';
  static const String addToCart = 'AddToCart';
  static const String addToWishlist = 'AddToWishlist';
  static const String initiateCheckout = 'InitiateCheckout';
  static const String addPaymentInfo = 'AddPaymentInfo';
  static const String purchase = 'Purchase';
  static const String lead = 'Lead';
  static const String completeRegistration = 'CompleteRegistration';
  static const String subscribe = 'Subscribe';
  static const String startTrial = 'StartTrial';
  static const String schedule = 'Schedule';
  static const String submitApplication = 'SubmitApplication';
  static const String contact = 'Contact';
  static const String customizeProduct = 'CustomizeProduct';
  static const String donate = 'Donate';
  static const String findLocation = 'FindLocation';

  // App lifecycle events (sent by the SDK unless switched off).
  static const String appInstalled = 'app_installed';
  static const String appUpdated = 'app_updated';
  static const String appOpened = 'app_opened';
  static const String appBackgrounded = 'app_backgrounded';
  static const String deepLinkOpened = 'deep_link_opened';
  static const String screenViewed = 'screen_viewed';

  /// Every Meta standard event name.
  static const List<String> metaEvents = [
    pageView,
    viewContent,
    search,
    addToCart,
    addToWishlist,
    initiateCheckout,
    addPaymentInfo,
    purchase,
    lead,
    completeRegistration,
    subscribe,
    startTrial,
    schedule,
    submitApplication,
    contact,
    customizeProduct,
    donate,
    findLocation,
  ];

  /// Every app lifecycle event name.
  static const List<String> lifecycleEvents = [
    appInstalled,
    appUpdated,
    appOpened,
    appBackgrounded,
    deepLinkOpened,
    screenViewed,
  ];

  /// All names above.
  static const List<String> all = [...metaEvents, ...lifecycleEvents];
}

/// One line of an order or cart, sent in `properties.contents`.
class LemuContent {
  const LemuContent({
    required this.id,
    this.quantity = 1,
    this.itemPrice,
    this.title,
    this.brand,
    this.category,
  });

  /// Product id or SKU.
  final String id;
  final int quantity;

  /// Price of one item in major units (1499.5 means Rs 1,499.50).
  final num? itemPrice;
  final String? title;
  final String? brand;
  final String? category;

  Map<String, Object?> toJson() => {
        'id': id,
        'quantity': quantity,
        if (itemPrice != null) 'item_price': itemPrice,
        if (title != null) 'title': title,
        if (brand != null) 'brand': brand,
        if (category != null) 'category': category,
      };
}
