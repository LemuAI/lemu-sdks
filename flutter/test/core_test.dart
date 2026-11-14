// ignore_for_file: avoid_dynamic_calls
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lemu_analytics/core.dart';

import 'support/harness.dart';

class _FakeBridge implements LemuIdBridge {
  _FakeBridge({this.id, this.optedOut = false});

  String? id;
  final List<String> writes = [];

  @override
  bool optedOut;

  @override
  String? readAnonymousId() => id;

  @override
  void writeAnonymousId(String value) {
    writes.add(value);
    id = value;
  }
}

class _ThrowingStorage implements LemuStorage {
  @override
  Future<String?> read(String key) => throw StateError('read');
  @override
  Future<void> write(String key, String value) => throw StateError('write');
  @override
  Future<void> remove(String key) => throw StateError('remove');
}

void main() {
  late RecordingClient http_;

  setUp(() => http_ = RecordingClient());
  tearDown(() async {
    await closeCores();
    http_.expectValidBodies();
  });

  group('helpers', () {
    test('uuidV4 produces version 4 ids', () {
      final random = Random(1);
      final ids = {for (var i = 0; i < 500; i++) uuidV4(random)};
      expect(ids, hasLength(500));
      for (final id in ids) {
        expect(id, matches(uuidV4Pattern));
      }
    });

    test('isoTimestamp always has three fraction digits and Z', () {
      expect(isoTimestamp(DateTime.utc(2026, 1, 2, 3, 4, 5)),
          '2026-01-02T03:04:05.000Z');
      expect(isoTimestamp(DateTime.utc(2026, 1, 2, 3, 4, 5, 7, 999)),
          '2026-01-02T03:04:05.007Z');
    });

    test('campaignFromUri maps utm_ and click ids', () {
      final uri = Uri.parse('brand://p/1?utm_source=google&utm_medium=cpc'
          '&utm_campaign=diwali&gclid=abc&fbclid=&other=1');
      expect(campaignFromUri(uri), {
        'source': 'google',
        'medium': 'cpc',
        'campaign': 'diwali',
        'gclid': 'abc',
      });
      expect(campaignFromUri(Uri.parse('https://x.co/')), isEmpty);
    });
  });

  group('flush policy', () {
    test('app defaults are 20 messages and 30 seconds', () {
      final core = makeCore(client: http_.client);
      expect(core.flushAt, 20);
      expect(core.flushInterval, const Duration(seconds: 30));
    });

    test('web defaults are 10 messages and 1 second, text/plain, no UA',
        () async {
      final core = makeCore(
        client: http_.client,
        isWeb: true,
        info: testPlatformInfo(userAgent: null),
      );
      expect(core.flushAt, 10);
      expect(core.flushInterval, const Duration(seconds: 1));
      for (var i = 0; i < 10; i++) {
        core.track('E$i');
      }
      await eventually(() => http_.requests.isNotEmpty);
      expect(http_.requests, hasLength(1));
      final headers = http_.requests.single.headers;
      expect(headers['Content-Type'], startsWith('text/plain'));
      expect(headers.containsKey('User-Agent'), isFalse);
    });

    test('the interval timer sends without flush()', () async {
      final core = makeCore(
        client: http_.client,
        options: const LemuOptions(flushInterval: Duration(milliseconds: 50)),
      );
      core.track('A');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(http_.messages.single['event'], 'A');
    });

    test('custom flushAt', () async {
      final core = makeCore(
        client: http_.client,
        options: const LemuOptions(flushAt: 3),
      );
      core.track('A');
      core.track('B');
      await settle(20);
      expect(http_.requests, isEmpty);
      core.track('C');
      await eventually(() => http_.requests.isNotEmpty);
      expect(http_.requests, hasLength(1));
    });

    test('a track named Purchase also flushes at once', () async {
      final core = makeCore(client: http_.client);
      core.track(LemuEvent.purchase, {'value': 1, 'currency': 'INR'});
      await eventually(() => http_.requests.isNotEmpty);
      expect(http_.requests, hasLength(1));
    });
  });

  group('responses', () {
    for (final status in [401, 403, 404]) {
      test('HTTP $status drops the batch', () async {
        final logs = <String>[];
        final core = makeCore(
          client: http_.client,
          logs: logs,
          options: const LemuOptions(debug: true),
        );
        http_.statuses.add(status);
        core.track('A');
        await core.flush();
        expect(core.queueLength, 0);
        expect(core.currentBackoff, isNull);
        expect(logs.any((l) => l.contains('HTTP $status')), isTrue);
      });
    }

    test('429 and 5xx back off 1 s, 2 s, 4 s ... with jitter, capped at 5 min',
        () async {
      final core = makeCore(client: http_.client);
      http_.defaultStatus = 503;
      core.track('A');
      final delays = <Duration>[];
      for (var i = 0; i < 12; i++) {
        await core.flush();
        delays.add(core.currentBackoff!);
      }
      for (var i = 0; i < delays.length; i++) {
        final base = min(1000 * pow(2, i), 300000);
        expect(
            delays[i].inMilliseconds, inInclusiveRange(base * 0.8, base * 1.2),
            reason: 'attempt ${i + 1}');
      }
      expect(core.queueLength, 1);

      http_.statuses.add(429);
      await core.flush();
      expect(core.queueLength, 1);
      http_.defaultStatus = 204;
      await core.flush();
      expect(core.queueLength, 0);
      expect(core.currentBackoff, isNull);
    });

    test('automatic flushes wait for the backoff; flush() does not', () async {
      final core = makeCore(
        client: http_.client,
        options: const LemuOptions(flushAt: 1),
      );
      http_.statuses.add(500);
      core.track('A');
      await eventually(() => http_.requests.isNotEmpty);
      await settle(20);
      expect(http_.requests, hasLength(1));
      core.track('B'); // threshold reached again, but backing off
      await settle(20);
      expect(http_.requests, hasLength(1));
      await core.flush();
      expect(http_.requests, hasLength(2));
      expect(http_.acceptedMessages.map((m) => m['event']), ['A', 'B']);
    });

    test('the retry timer delivers after the backoff', () async {
      final core = makeCore(client: http_.client);
      http_.statuses.add(500);
      core.track('A');
      await core.flush();
      expect(core.currentBackoff!.inMilliseconds, lessThanOrEqualTo(1200));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(http_.requests, hasLength(2));
      expect(core.queueLength, 0);
    });

    test('413 on a single message drops it', () async {
      final core = makeCore(client: http_.client);
      http_.statuses.add(413);
      core.track('A');
      await core.flush();
      expect(http_.requests, hasLength(1));
      expect(core.queueLength, 0);
    });

    test('413 split where the second half fails keeps only that half',
        () async {
      final core = makeCore(client: http_.client);
      http_.statuses.addAll([413, 204, 500]);
      core.track('A');
      core.track('B');
      await core.flush();
      expect(core.queueLength, 1);
      await core.flush();
      expect(http_.acceptedMessages.map((m) => m['event']), ['A', 'B']);
    });

    test('gives up 20 hours after queueing when the server keeps failing',
        () async {
      final clock = TestClock();
      final core = makeCore(client: http_.client, clock: clock);
      http_.defaultStatus = 500;
      core.track('A');
      await core.flush();
      expect(core.queueLength, 1);
      clock.advance(const Duration(hours: 20, minutes: 1));
      await core.flush();
      expect(core.queueLength, 0);
    });

    test('does not give up at 20 hours while the network is down', () async {
      final clock = TestClock();
      final core = makeCore(client: http_.client, clock: clock);
      http_.online = false;
      core.track('A');
      await core.flush();
      clock.advance(const Duration(hours: 30));
      await core.flush();
      expect(core.queueLength, 1);
      http_.online = true;
      await core.flush();
      expect(http_.messages.single['event'], 'A');
    });

    test('messages older than 7 days are dropped before sending', () async {
      final clock = TestClock();
      final core = makeCore(client: http_.client, clock: clock);
      http_.online = false;
      core.track('old');
      await core.flush();
      clock.advance(const Duration(days: 6));
      core.track('recent');
      await core.flush();
      clock.advance(const Duration(days: 1, hours: 1));
      http_.online = true;
      await core.flush();
      expect(http_.messages.map((m) => m['event']), ['recent']);
    });

    test('a client that throws synchronously is handled', () async {
      final core = makeCore(
        client: MockClient((_) => throw StateError('boom')),
      );
      core.track('A');
      await expectLater(core.flush(), completes);
      expect(core.queueLength, 1);
    });

    test('a request that never answers times out and is retried', () async {
      var calls = 0;
      final core = makeCore(
        client: MockClient((request) async {
          calls++;
          if (calls == 1) {
            await Future<void>.delayed(const Duration(seconds: 5));
          }
          return http.Response('', 204);
        }),
      );
      core.track('A');
      await core.flush();
      expect(core.queueLength, 1);
      await core.flush();
      expect(core.queueLength, 0);
    });
  });

  group('queue', () {
    test('maxQueueSize keeps purchases and drops the oldest other message',
        () async {
      final core = makeCore(
        client: http_.client,
        options: const LemuOptions(maxQueueSize: 3, flushAt: 100),
      );
      http_.online = false;
      core.track('A');
      core.purchase(value: 1, currency: 'INR', orderId: 'o1');
      core.track('B');
      core.track('C');
      await core.flush();
      http_.online = true;
      await core.flush();
      expect(http_.messages.map((m) => m['event']), ['Purchase', 'B', 'C']);
    });

    test('maxQueueSize is capped at 1,000', () async {
      final core = makeCore(
        client: http_.client,
        options: const LemuOptions(maxQueueSize: 5000, flushAt: 5000),
      );
      http_.online = false;
      for (var i = 0; i < 1005; i++) {
        core.track('E$i');
      }
      await core.flush();
      expect(core.queueLength, 1000);
    });

    test('an unreadable stored queue is discarded', () async {
      final storage = InMemoryLemuStorage({LemuStorageKeys.queue: '{not json'});
      final core = makeCore(client: http_.client, storage: storage);
      await core.ready;
      expect(core.queueLength, 0);
      expect(storage.values.containsKey(LemuStorageKeys.queue), isFalse);
    });

    test('the persisted queue is removed once delivered', () async {
      final storage = InMemoryLemuStorage();
      final core = makeCore(client: http_.client, storage: storage);
      http_.online = false;
      core.track('A');
      await core.flush();
      expect(storage.values[LemuStorageKeys.queue], contains('"event":"A"'));
      http_.online = true;
      await core.flush();
      await settle();
      expect(storage.values.containsKey(LemuStorageKeys.queue), isFalse);
    });
  });

  group('identity', () {
    test('anonymousId and userId persist across instances', () async {
      final storage = InMemoryLemuStorage();
      final first = makeCore(client: http_.client, storage: storage);
      first.identify(userId: 'u1');
      await first.flush();
      final anonymousId = first.anonymousId;
      await first.close();

      final second = makeCore(client: http_.client, storage: storage);
      second.track('X');
      await second.flush();
      final m = http_.messages.last;
      expect(m['anonymousId'], anonymousId);
      expect(m['userId'], 'u1');
    });

    test('reset clears the stored userId', () async {
      final storage = InMemoryLemuStorage();
      final core = makeCore(client: http_.client, storage: storage);
      core.identify(userId: 'u1');
      core.reset();
      await core.flush();
      expect(storage.values.containsKey(LemuStorageKeys.userId), isFalse);
      expect(storage.values[LemuStorageKeys.anonymousId], core.anonymousId);
    });

    test('identify with traits only keeps the userId unset', () async {
      final core = makeCore(client: http_.client);
      core.identify(traits: {'email': 'a@b.co', 'phone': '+919999999999'});
      await core.flush();
      final m = http_.messages.single;
      expect(m['type'], 'identify');
      expect(m.containsKey('userId'), isFalse);
      expect(m['traits'], {'email': 'a@b.co', 'phone': '+919999999999'});
    });

    test('the website id is reused on the web', () async {
      final bridge = _FakeBridge(id: 'web-visitor-1');
      final core =
          makeCore(client: http_.client, idBridge: bridge, isWeb: true);
      core.track('X');
      await core.flush();
      expect(http_.messages.single['anonymousId'], 'web-visitor-1');
      expect(bridge.writes, isEmpty);
    });

    test('a new id is shared with the website, and reset updates it', () async {
      final bridge = _FakeBridge();
      final core =
          makeCore(client: http_.client, idBridge: bridge, isWeb: true);
      await core.ready;
      expect(bridge.writes, [core.anonymousId]);
      core.reset();
      await core.flush();
      expect(bridge.writes.last, core.anonymousId);
    });

    test('a website opt-out is respected', () async {
      final bridge = _FakeBridge(optedOut: true);
      final core =
          makeCore(client: http_.client, idBridge: bridge, isWeb: true);
      core.track('X');
      await core.flush();
      expect(http_.requests, isEmpty);
    });

    test('nothing goes to the website cookie before consent', () async {
      final bridge = _FakeBridge();
      final core = makeCore(
        client: http_.client,
        idBridge: bridge,
        isWeb: true,
        options: const LemuOptions(requireConsent: true),
      );
      await core.ready;
      expect(bridge.writes, isEmpty);
      core.setConsent(true);
      await core.flush();
      expect(bridge.writes, [core.anonymousId]);
    });
  });

  group('consent', () {
    test('at most 50 messages are held before consent', () async {
      final core = makeCore(
        client: http_.client,
        options: const LemuOptions(requireConsent: true, flushAt: 1000),
      );
      for (var i = 0; i < 60; i++) {
        core.track('E$i');
      }
      await core.flush();
      expect(core.heldLength, 50);
      core.setConsent(true);
      await core.flush();
      final events = http_.messages.map((m) => m['event']).toList();
      expect(events, hasLength(50));
      expect(events.first, 'E10');
    });

    test('granted consent is remembered across launches', () async {
      final storage = InMemoryLemuStorage();
      const options = LemuOptions(requireConsent: true);
      final first =
          makeCore(client: http_.client, storage: storage, options: options);
      first.setConsent(true);
      await first.flush();
      await first.close();

      final second =
          makeCore(client: http_.client, storage: storage, options: options);
      second.track('X');
      await second.flush();
      expect(http_.messages.single['event'], 'X');
    });

    test('withdrawing consent clears the queue and stops sending', () async {
      final storage = InMemoryLemuStorage();
      final core = makeCore(client: http_.client, storage: storage);
      http_.online = false;
      core.track('A');
      await core.flush();
      core.setConsent(false);
      core.track('B');
      http_.online = true;
      await core.flush();
      expect(http_.requests, isEmpty);
      expect(storage.values.containsKey(LemuStorageKeys.queue), isFalse);
    });

    test('app version is stored only after consent', () async {
      final storage = InMemoryLemuStorage();
      final core = makeCore(
        client: http_.client,
        storage: storage,
        options: const LemuOptions(requireConsent: true),
      );
      core.recordAppLaunch();
      await core.flush();
      expect(storage.values, isEmpty);
      core.setConsent(true);
      await core.flush();
      expect(storage.values[LemuStorageKeys.appVersion], '1.0.0');
      expect(http_.messages.single['event'], 'app_installed');
    });
  });

  group('lifecycle and deep links', () {
    test('app_opened and app_backgrounded; backgrounding flushes', () async {
      final core = makeCore(client: http_.client);
      core.appOpened();
      core.appBackgrounded();
      await eventually(() => http_.requests.isNotEmpty);
      expect(http_.messages.map((m) => m['event']),
          ['app_opened', 'app_backgrounded']);
      expect(http_.messages[0]['properties'], {'from_background': false});
      core.appOpened(fromBackground: true, url: 'brand://home');
      await core.flush();
      expect(http_.messages.last['properties'],
          {'from_background': true, 'url': 'brand://home'});
    });

    test('trackLifecycle: false sends no lifecycle events but still flushes',
        () async {
      final core = makeCore(
        client: http_.client,
        options: const LemuOptions(trackLifecycle: false),
      );
      core.recordAppLaunch();
      core.appOpened();
      core.track('A');
      core.appBackgrounded();
      await eventually(() => http_.requests.isNotEmpty);
      expect(http_.messages.map((m) => m['event']), ['A']);
    });

    test('deep link UTM parameters go into context.campaign', () async {
      final core = makeCore(client: http_.client);
      core.track('before');
      core.trackDeepLink(
        Uri.parse('https://brand.com/p/1?utm_source=meta&utm_campaign=sale'),
        referrer: 'com.instagram.android',
      );
      core.track('after');
      await core.flush();
      final ms = http_.messages;
      expect(ms[0]['context'].containsKey('campaign'), isFalse);
      expect(ms[1]['event'], 'deep_link_opened');
      expect(ms[1]['properties'], {
        'url': 'https://brand.com/p/1?utm_source=meta&utm_campaign=sale',
        'referrer': 'com.instagram.android',
      });
      expect(
          ms[1]['context']['campaign'], {'source': 'meta', 'campaign': 'sale'});
      expect(
          ms[2]['context']['campaign'], {'source': 'meta', 'campaign': 'sale'});
    });

    test('trackDeepLinks: false keeps the campaign without the event',
        () async {
      final core = makeCore(
        client: http_.client,
        options: const LemuOptions(trackDeepLinks: false),
      );
      core.trackDeepLink(Uri.parse('brand://x?utm_source=sms'));
      core.track('A');
      await core.flush();
      expect(http_.messages.single['event'], 'A');
      expect(http_.messages.single['context']['campaign'], {'source': 'sms'});
    });
  });

  group('messages', () {
    test('purchase fills contents, content_ids and num_items', () async {
      final core = makeCore(client: http_.client);
      core.purchase(
        value: 2998,
        currency: 'inr',
        orderId: ' 1043 ',
        contents: const [
          LemuContent(id: 'SKU1', quantity: 2, itemPrice: 999, title: 'Tee'),
          LemuContent(id: 'SKU2', itemPrice: 1000),
        ],
        properties: {'coupon': 'DIWALI', 'value': 1},
      );
      await eventually(() => http_.requests.isNotEmpty);
      final p = http_.messages.single['properties'] as Map;
      expect(p, {
        'coupon': 'DIWALI',
        'value': 2998,
        'currency': 'INR',
        'order_id': '1043',
        'contents': [
          {'id': 'SKU1', 'quantity': 2, 'item_price': 999, 'title': 'Tee'},
          {'id': 'SKU2', 'quantity': 1, 'item_price': 1000},
        ],
        'content_ids': ['SKU1', 'SKU2'],
        'num_items': 3,
      });
    });

    test('properties are made JSON safe', () async {
      final core = makeCore(client: http_.client);
      core.track('X', {
        'when': DateTime.utc(2026, 1, 1),
        'link': Uri.parse('https://a.co'),
        'nested': {
          'list': [1, double.infinity, 'a'],
        },
        'content': const LemuContent(id: 'S'),
      });
      await core.flush();
      expect(http_.messages.single['properties'], {
        'when': '2026-01-01T00:00:00.000Z',
        'link': 'https://a.co',
        'nested': {
          'list': [1, 'a'],
        },
        'content': {'id': 'S', 'quantity': 1},
      });
    });

    test('properties are copied at call time', () async {
      final core = makeCore(client: http_.client);
      final props = <String, Object?>{'n': 1};
      core.track('X', props);
      props['n'] = 2;
      await core.flush();
      expect(http_.messages.single['properties'], {'n': 1});
    });

    test('context carries the platform info and no advertising ids', () async {
      final core = makeCore(client: http_.client);
      core.track('X');
      await core.flush();
      final context = http_.messages.single['context'] as Map;
      expect(context['app']['namespace'], 'com.brand.app');
      expect(context['device']['type'], 'phone');
      expect(context['os'], {'name': 'Android', 'version': '14'});
      expect(context['locale'], 'en-IN');
      expect(context['timezone'], 'Asia/Kolkata');
      for (final key in ['advertisingId', 'idfa', 'gaid', 'deviceId']) {
        expect(context.containsKey(key), isFalse);
      }
    });

    test('apiHost with a trailing slash still posts to the batch path',
        () async {
      final core = makeCore(
        client: http_.client,
        options: const LemuOptions(apiHost: 'https://collect.brand.com/'),
      );
      core.track('X');
      await core.flush();
      expect(http_.requests.single.url.toString(),
          'https://collect.brand.com/api/v1/pixel/batch');
    });
  });

  group('never throws', () {
    test('storage that always throws', () async {
      final core = makeCore(client: http_.client, storage: _ThrowingStorage());
      expect(() {
        core.track('A');
        core.identify(userId: 'u');
        core.reset();
        core.optOut();
        core.optIn();
        core.setConsent(true);
        core.recordAppLaunch();
      }, returnsNormally);
      await expectLater(core.flush(), completes);
      // optOut() cleared A and the identify; app_installed came after optIn().
      expect(http_.messages.map((m) => m['event']), ['app_installed']);
    });

    test('a platform info loader that throws', () async {
      final core = LemuCore(
        writeKey: testWriteKey,
        httpClient: http_.client,
        platformInfo: () => throw StateError('no plugin'),
      );
      core.track('X');
      await core.flush();
      await core.close();
      final m = http_.messages.single;
      expect(m['context']['platform'], 'flutter');
    });

    test('an empty write key sends nothing', () async {
      final core = makeCore(client: http_.client, writeKey: ' ');
      core.track('X');
      await core.flush();
      expect(http_.requests, isEmpty);
    });

    test('debug logs calls, requests and responses', () async {
      final logs = <String>[];
      final core = makeCore(
        client: http_.client,
        logs: logs,
        options: const LemuOptions(debug: true),
      );
      core.track('X', {'a': 1});
      await core.flush();
      expect(logs.any((l) => l.contains('track {"event":"X"')), isTrue);
      expect(logs.any((l) => l.contains('POST ')), isTrue);
      expect(logs.any((l) => l.contains('response: HTTP 204')), isTrue);
      expect(logs.every((l) => l.startsWith('[Lemu] ')), isTrue);
    });

    test('no logs without debug', () async {
      final logs = <String>[];
      final core = makeCore(client: http_.client, logs: logs);
      core.track('');
      await core.flush();
      expect(logs, isEmpty);
    });
  });

  test('request bodies are valid JSON with writeKey and sentAt', () async {
    final core = makeCore(client: http_.client);
    core.track('X');
    await core.flush();
    final body = jsonDecode(http_.requests.single.body) as Map;
    expect(body.keys, containsAll(['writeKey', 'sentAt', 'batch']));
  });
}
