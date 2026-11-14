/// What the host platform tells the SDK about the app and device. The
/// Flutter layer fills it from package_info_plus and device_info_plus;
/// tests pass a fixed value.
class LemuPlatformInfo {
  const LemuPlatformInfo({
    this.context = const {},
    this.userAgent,
    this.appVersion,
    this.appBuild,
  });

  /// Merged into every message's `context` (`app`, `device`, `os`,
  /// `screen`, `locale`, `timezone`, `userAgent`).
  final Map<String, Object?> context;

  /// `User-Agent` request header. Null on the web, where the browser sets
  /// its own.
  final String? userAgent;

  /// App version and build, used for `app_installed` / `app_updated`.
  final String? appVersion;
  final String? appBuild;
}

/// Shares the anonymous id with the brand's website on Flutter web (the
/// `_lemu_aid` cookie and localStorage key the Lemu website pixel uses).
abstract class LemuIdBridge {
  /// The website's anonymous id, if the browser has one.
  String? readAnonymousId();

  /// Stores [id] where the website pixel will find it.
  void writeAnonymousId(String id);

  /// True when the visitor opted out through the website pixel.
  bool get optedOut;
}
