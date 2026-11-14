// Runs in a browser: flutter test --platform chrome test/web_bridge_test.dart
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lemu_analytics/src/web/web_bridge_web.dart';
import 'package:web/web.dart' as web;

void _clear() {
  web.document.cookie = '_lemu_aid=; path=/; max-age=0';
  web.document.cookie = '_lemu_optout=; path=/; max-age=0';
  web.window.localStorage.removeItem('_lemu_aid');
  web.window.localStorage.removeItem('_lemu_optout');
}

void main() {
  setUp(_clear);
  tearDown(_clear);

  test('reads the website pixel cookie first', () {
    web.window.localStorage.setItem('_lemu_aid', 'from-storage');
    web.document.cookie = '_lemu_aid=from-cookie; path=/';
    expect(createWebIdBridge()!.readAnonymousId(), 'from-cookie');
  });

  test('falls back to localStorage', () {
    web.window.localStorage.setItem('_lemu_aid', 'from-storage');
    expect(createWebIdBridge()!.readAnonymousId(), 'from-storage');
  });

  test('writes the cookie and localStorage', () {
    final bridge = createWebIdBridge()!;
    expect(bridge.readAnonymousId(), isNull);
    bridge.writeAnonymousId('abc-123');
    expect(web.document.cookie, contains('_lemu_aid=abc-123'));
    expect(web.window.localStorage.getItem('_lemu_aid'), 'abc-123');
  });

  test('sees the website opt-out', () {
    final bridge = createWebIdBridge()!;
    expect(bridge.optedOut, isFalse);
    web.document.cookie = '_lemu_optout=1; path=/';
    expect(bridge.optedOut, isTrue);
  });

  test('reads the IANA time zone', () {
    // An IANA name such as Asia/Kolkata, or UTC on a machine set to UTC.
    expect(browserTimeZone(),
        matches(RegExp(r'^[A-Za-z_]+(/[A-Za-z0-9_+\-]+)*$')));
  });
}
