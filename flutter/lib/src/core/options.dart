/// Settings for `Lemu.instance.setup()`.
class LemuOptions {
  const LemuOptions({
    this.apiHost = defaultApiHost,
    this.debug = false,
    this.requireConsent = false,
    this.flushAt,
    this.flushInterval,
    this.maxQueueSize = 1000,
    this.trackLifecycle = true,
    this.trackDeepLinks = true,
    this.inAppMessages = true,
  });

  static const String defaultApiHost = 'https://app.lemuai.com';

  /// Where events are sent. Change it only for testing or a custom
  /// collection domain.
  final String apiHost;

  /// Logs every call, request and response (through `debugPrint`).
  final bool debug;

  /// When true, nothing is sent or written to storage until
  /// `setConsent(true)`. Up to 50 events are held in memory meanwhile.
  final bool requireConsent;

  /// Send once this many events are queued. Defaults to 20 in apps and 10
  /// on the web.
  final int? flushAt;

  /// Send queued events this often. Defaults to 30 seconds in apps and
  /// 1 second on the web.
  final Duration? flushInterval;

  /// Most events kept on the device while offline. When full, the oldest
  /// event that is not a `Purchase` is dropped. At most 1,000.
  final int maxQueueSize;

  /// Send `app_installed`, `app_updated`, `app_opened` and
  /// `app_backgrounded` automatically.
  final bool trackLifecycle;

  /// Send `deep_link_opened` from `trackDeepLink()`. Campaign parameters
  /// are kept either way.
  final bool trackDeepLinks;

  /// Show in-app messages (experiences built in Lemu for apps). When false
  /// the SDK never fetches them. Ignored on the web, where the website
  /// script shows experiences.
  final bool inAppMessages;

  /// Hard upper bound on [maxQueueSize].
  static const int queueLimit = 1000;

  LemuOptions copyWith({
    String? apiHost,
    bool? debug,
    bool? requireConsent,
    int? flushAt,
    Duration? flushInterval,
    int? maxQueueSize,
    bool? trackLifecycle,
    bool? trackDeepLinks,
    bool? inAppMessages,
  }) =>
      LemuOptions(
        apiHost: apiHost ?? this.apiHost,
        debug: debug ?? this.debug,
        requireConsent: requireConsent ?? this.requireConsent,
        flushAt: flushAt ?? this.flushAt,
        flushInterval: flushInterval ?? this.flushInterval,
        maxQueueSize: maxQueueSize ?? this.maxQueueSize,
        trackLifecycle: trackLifecycle ?? this.trackLifecycle,
        trackDeepLinks: trackDeepLinks ?? this.trackDeepLinks,
        inAppMessages: inAppMessages ?? this.inAppMessages,
      );
}
