import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../core/platform_info.dart';

const String _idKey = '_lemu_aid';
const String _optOutKey = '_lemu_optout';

/// Shares the anonymous id with the Lemu website pixel through the same
/// `_lemu_aid` cookie and localStorage key, so a Flutter web app and the
/// brand's website count as one visitor.
LemuIdBridge? createWebIdBridge() => _WebIdBridge();

class _WebIdBridge implements LemuIdBridge {
  @override
  String? readAnonymousId() => _readCookie(_idKey) ?? _readStorage(_idKey);

  @override
  void writeAnonymousId(String id) {
    try {
      var cookie = '$_idKey=${Uri.encodeComponent(id)}; path=/; '
          'max-age=${365 * 86400}; SameSite=Lax';
      if (web.window.location.protocol == 'https:') cookie += '; Secure';
      web.document.cookie = cookie;
    } catch (_) {}
    try {
      web.window.localStorage.setItem(_idKey, id);
    } catch (_) {}
  }

  @override
  bool get optedOut =>
      _readCookie(_optOutKey) == '1' || _readStorage(_optOutKey) == '1';

  static String? _readCookie(String name) {
    try {
      final cookies = web.document.cookie;
      for (final part in cookies.split(';')) {
        final trimmed = part.trim();
        if (trimmed.startsWith('$name=')) {
          final value = Uri.decodeComponent(trimmed.substring(name.length + 1));
          return value.isEmpty ? null : value;
        }
      }
    } catch (_) {}
    return null;
  }

  static String? _readStorage(String key) {
    try {
      final value = web.window.localStorage.getItem(key);
      return (value == null || value.isEmpty) ? null : value;
    } catch (_) {
      return null;
    }
  }
}

@JS('Intl.DateTimeFormat')
external _DateTimeFormat _dateTimeFormat();

extension type _DateTimeFormat._(JSObject _) implements JSObject {
  external _ResolvedOptions resolvedOptions();
}

extension type _ResolvedOptions._(JSObject _) implements JSObject {
  external String? get timeZone;
}

/// IANA time zone from the browser, such as `Asia/Kolkata`.
String? browserTimeZone() {
  try {
    return _dateTimeFormat().resolvedOptions().timeZone;
  } catch (_) {
    return null;
  }
}
