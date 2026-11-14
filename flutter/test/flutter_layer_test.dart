// ignore_for_file: avoid_dynamic_calls
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lemu_analytics/lemu_analytics.dart';
import 'package:lemu_analytics/src/flutter/platform_context.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';

PageRouteBuilder<void> _page(String? name) => PageRouteBuilder<void>(
      settings: RouteSettings(name: name),
      pageBuilder: (_, __, ___) => const SizedBox(),
    );

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late RecordingClient http_;

  setUp(() {
    http_ = RecordingClient();
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Brand',
      packageName: 'com.brand.app',
      version: '2.0.0',
      buildNumber: '20',
      buildSignature: '',
    );
  });

  tearDown(() async {
    await Lemu.instance.debugTearDown();
    http_.expectValidBodies();
  });

  test('calls before setup are ignored without throwing', () async {
    expect(Lemu.instance.isSetUp, isFalse);
    expect(() => Lemu.instance.track('X'), returnsNormally);
    expect(Lemu.instance.anonymousId, isNull);
    await expectLater(Lemu.instance.flush(), completes);
  });

  test('setup reads app info, sends app_installed and app_opened', () async {
    await Lemu.instance.setup(
      testWriteKey,
      storage: InMemoryLemuStorage(),
      httpClient: http_.client,
    );
    expect(Lemu.instance.anonymousId, matches(uuidV4Pattern));
    Lemu.instance.track(LemuEvent.viewContent, {
      'content_ids': ['SKU1']
    });
    await Lemu.instance.flush();

    final ms = http_.messages;
    expect(ms.map((m) => m['event']),
        ['app_installed', 'app_opened', 'ViewContent']);
    expect(ms[0]['properties'], {'version': '2.0.0', 'build': '20'});
    expect(ms[1]['properties'], {'from_background': false});
    final context = ms[2]['context'];
    expect(context['platform'], 'flutter');
    expect(context['app'], {
      'name': 'Brand',
      'version': '2.0.0',
      'build': '20',
      'namespace': 'com.brand.app',
    });
    expect(context['device']['type'], isIn(['phone', 'tablet']));
    expect(http_.requests.first.headers['User-Agent'],
        startsWith('lemu-flutter/'));
  });

  test('a second setup is ignored', () async {
    await Lemu.instance.setup(testWriteKey,
        storage: InMemoryLemuStorage(), httpClient: http_.client);
    final core = Lemu.instance.core;
    await Lemu.instance.setup('pk_other', httpClient: http_.client);
    expect(Lemu.instance.core, same(core));
  });

  test(
      'background sends app_backgrounded and flushes; resume sends '
      'app_opened from_background', () async {
    await Lemu.instance.setup(
      testWriteKey,
      storage: InMemoryLemuStorage(),
      httpClient: http_.client,
      options: const LemuOptions(trackLifecycle: true),
    );
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await eventually(() =>
        http_.messages.any((m) => m['event'] == LemuEvent.appBackgrounded));

    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await Lemu.instance.flush();

    final events = http_.messages.map((m) => m['event']).toList();
    expect(events, [
      'app_installed',
      'app_opened',
      'app_backgrounded',
      'app_opened',
    ]);
    expect(http_.messages.last['properties'], {'from_background': true});
  });

  test('purchase through Lemu.instance is sent at once', () async {
    await Lemu.instance.setup(
      testWriteKey,
      storage: InMemoryLemuStorage(),
      httpClient: http_.client,
      options: const LemuOptions(trackLifecycle: false),
    );
    Lemu.instance.purchase(value: 1499.5, currency: 'INR', orderId: '1042');
    await eventually(() => http_.requests.isNotEmpty);
    expect(http_.messages.single['properties']['order_id'], '1042');
  });

  test('deep links through Lemu.instance', () async {
    await Lemu.instance.setup(
      testWriteKey,
      storage: InMemoryLemuStorage(),
      httpClient: http_.client,
      options: const LemuOptions(trackLifecycle: false),
    );
    Lemu.instance.trackDeepLink(
      Uri.parse('https://brand.com/sale?utm_source=whatsapp'),
    );
    await Lemu.instance.flush();
    final m = http_.messages.single;
    expect(m['event'], 'deep_link_opened');
    expect(m['context']['campaign'], {'source': 'whatsapp'});
  });

  group('LemuNavigatorObserver', () {
    setUp(() async {
      await Lemu.instance.setup(
        testWriteKey,
        storage: InMemoryLemuStorage(),
        httpClient: http_.client,
        options: const LemuOptions(trackLifecycle: false),
      );
    });

    test('sends screens for named page routes only', () async {
      final observer = LemuNavigatorObserver();
      final home = _page('/home');
      final checkout = _page('/checkout');
      observer.didPush(home, null);
      observer.didPush(checkout, home);
      observer.didPush(_page(null), checkout); // unnamed: skipped
      observer.didPush(
        RawDialogRoute<void>(
          pageBuilder: (_, __, ___) => const SizedBox(),
          settings: const RouteSettings(name: 'dialog'),
        ),
        checkout,
      ); // not a page route: skipped
      observer.didPop(checkout, home);
      observer.didReplace(newRoute: _page('/done'), oldRoute: home);
      await Lemu.instance.flush();

      final ms = http_.messages;
      expect(ms.every((m) => m['type'] == 'screen'), isTrue);
      expect(
          ms.map((m) => m['name']), ['/home', '/checkout', '/home', '/done']);
    });

    test('custom name extractor', () async {
      final observer = LemuNavigatorObserver(
        nameExtractor: (route) => route.settings.name == null
            ? 'Unnamed'
            : 'Screen ${route.settings.name}',
      );
      observer.didPush(_page(null), null);
      await Lemu.instance.flush();
      expect(http_.messages.single['name'], 'Unnamed');
    });
  });

  test('SharedPreferencesLemuStorage reads, writes and removes', () async {
    final storage = SharedPreferencesLemuStorage();
    expect(await storage.read('k'), isNull);
    await storage.write('k', 'v');
    expect(await storage.read('k'), 'v');
    expect((await SharedPreferences.getInstance()).getString('k'), 'v');
    await storage.remove('k');
    expect(await storage.read('k'), isNull);
  });

  test('User-Agent format', () {
    expect(
      buildUserAgent(osName: 'Android', osVersion: '14', model: 'Pixel 8'),
      'lemu-flutter/$lemuSdkVersion (Android 14; Pixel 8)',
    );
    expect(
      buildUserAgent(osName: 'iOS', osVersion: '18.1', model: 'iPhone16,2'),
      'lemu-flutter/$lemuSdkVersion (iOS 18.1; iPhone16,2)',
    );
    expect(buildUserAgent(), 'lemu-flutter/$lemuSdkVersion');
    expect(buildUserAgent(osName: 'Linux', model: 'Café'),
        'lemu-flutter/$lemuSdkVersion (Linux; Caf?)');
  });

  test('web device type comes from the User-Agent', () {
    expect(
      webDeviceType('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0 Safari/537.36'),
      'desktop',
    );
    expect(
      webDeviceType(
          'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/157.0 Mobile Safari/537.36'),
      'phone',
    );
    expect(
      webDeviceType('Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148'),
      'phone',
    );
    expect(
      webDeviceType(
          'Mozilla/5.0 (Linux; Android 14; SM-X710) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/157.0 Safari/537.36'),
      'tablet',
    );
    expect(webDeviceType(null), 'desktop');
  });

  test('lemuSdkVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version =
        RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec)!;
    expect(lemuSdkVersion, version.group(1));
  });
}
