import 'dart:io';

/// Best-effort IANA time zone (`Asia/Kolkata`) on platforms with dart:io.
/// Reads `TZ` and the `/etc/localtime` link (macOS, Linux, iOS). Returns
/// null where neither is available (Android, Windows).
String? nativeTimeZone() {
  try {
    var tz = Platform.environment['TZ'];
    if (tz != null) {
      if (tz.startsWith(':')) tz = tz.substring(1);
      if (tz.contains('/') && !tz.startsWith('/')) return tz;
    }
  } catch (_) {}
  try {
    final target = Link('/etc/localtime').targetSync();
    const marker = 'zoneinfo/';
    final index = target.indexOf(marker);
    if (index >= 0) return target.substring(index + marker.length);
  } catch (_) {}
  try {
    final file = File('/etc/timezone');
    if (file.existsSync()) {
      final value = file.readAsStringSync().trim();
      if (value.contains('/')) return value;
    }
  } catch (_) {}
  return null;
}
