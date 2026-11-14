import '../core/platform_info.dart';

/// Non-web platforms have no website id to share.
LemuIdBridge? createWebIdBridge() => null;

/// IANA time zone from the browser. Not available here.
String? browserTimeZone() => null;
