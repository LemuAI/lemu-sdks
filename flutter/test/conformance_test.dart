// Conformance scenarios C01-C20 from ../conformance/README.md, run against a
// fake ingest server on 127.0.0.1. Every recorded body is validated against
// ../conformance/batch.schema.json.
// ignore_for_file: avoid_dynamic_calls
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lemu_analytics/core.dart';

import 'support/fake_ingest_server.dart';
import 'support/harness.dart';
import 'support/schema.dart';

void main() {
  late FakeIngestServer server;
  late http.Client client;

  setUp(() async {
    server = await FakeIngestServer.start();
    client = http.Client();
  });

  tearDown(() async {
    await closeCores();
    for (final r in server.requests) {
      expect(validateBody(r.rawBody), isEmpty, reason: r.rawBody);
    }
    client.close();
    await server.close();
  });

  LemuCore core({
    LemuStorage? storage,
    LemuOptions options = const LemuOptions(),
    LemuPlatformInfo? info,
    TestClock? clock,
    String? apiHost,
  }) =>
      makeCore(
        client: client,
        apiHost: apiHost ?? server.apiHost,
        storage: storage,
        options: options,
        info: info,
        clock: clock,
      );

  test('C01 track then flush sends one valid request', () async {
    final lemu = core();
    lemu.track('AddToCart', {'value': 999, 'currency': 'INR'});
    await lemu.flush();

    expect(server.requests, hasLength(1));
    final request = server.requests.single;
    expect(request.body['writeKey'], testWriteKey);
    final m = request.messages.single;
    expect(m['type'], 'track');
    expect(m['event'], 'AddToCart');
    expect(m['properties'], {'value': 999, 'currency': 'INR'});
    expect(m['context']['platform'], 'flutter');
    expect(m['context']['library'],
        {'name': 'lemu-flutter', 'version': lemuSdkVersion});
    expect(request.headers['user-agent'], startsWith('lemu-'));
    expect(request.headers['user-agent'], testUserAgent);
    expect(request.headers['content-type'], startsWith('application/json'));
  });

  test('C02 two tracks share anonymousId, have distinct v4 messageIds',
      () async {
    final lemu = core();
    lemu.track('A');
    lemu.track('B');
    await lemu.flush();

    final ms = server.messages;
    expect(ms, hasLength(2));
    expect(ms[0]['anonymousId'], ms[1]['anonymousId']);
    expect(ms[0]['anonymousId'], matches(uuidV4Pattern));
    expect(ms[0]['messageId'], isNot(ms[1]['messageId']));
    expect(ms[0]['messageId'], matches(uuidV4Pattern));
    expect(ms[1]['messageId'], matches(uuidV4Pattern));
  });

  test('C03 identify sets userId on identify and later messages', () async {
    final lemu = core();
    lemu.identify(userId: 'u1', traits: {'email': 'a@b.co'});
    lemu.track('X');
    await lemu.flush();

    final ms = server.messages;
    expect(ms[0]['type'], 'identify');
    expect(ms[0]['userId'], 'u1');
    expect(ms[0]['traits'], {'email': 'a@b.co'});
    expect(ms[1]['type'], 'track');
    expect(ms[1]['userId'], 'u1');
  });

  test('C04 reset gives a new anonymousId and no userId', () async {
    final lemu = core();
    lemu.identify(userId: 'u1', traits: {'email': 'a@b.co'});
    lemu.track('X');
    lemu.reset();
    lemu.track('X');
    await lemu.flush();

    final ms = server.messages;
    expect(ms, hasLength(3));
    expect(ms[2]['anonymousId'], isNot(ms[1]['anonymousId']));
    expect(ms[2]['anonymousId'], matches(uuidV4Pattern));
    expect(ms[2].containsKey('userId'), isFalse);
  });

  test('C05 purchase is sent at once with typed fields', () async {
    final lemu = core();
    lemu.purchase(value: 1499.5, currency: 'INR', orderId: '1042');
    await server.waitForRequests(1);

    final m = server.messages.single;
    expect(m['event'], 'Purchase');
    expect(m['properties']['value'], 1499.5);
    expect(m['properties']['currency'], 'INR');
    expect(m['properties']['order_id'], '1042');
  });

  test('C06 the 20th track triggers a request without flush()', () async {
    final lemu = core();
    for (var i = 0; i < 19; i++) {
      lemu.track('E$i');
    }
    await settle(20);
    expect(server.requests, isEmpty);
    lemu.track('E19');
    await server.waitForRequests(1);
    expect(server.requests.single.messages, hasLength(20));
  });

  test('C07 requireConsent holds messages and writes nothing until consent',
      () async {
    final storage = InMemoryLemuStorage();
    final lemu = core(
      storage: storage,
      options: const LemuOptions(requireConsent: true),
    );
    lemu.track('X');
    await lemu.flush();
    await settle();
    expect(server.requests, isEmpty);
    expect(storage.values, isEmpty);

    lemu.setConsent(true);
    await server.waitForRequests(1);
    expect(server.messages.single['event'], 'X');
    expect(storage.values[LemuStorageKeys.anonymousId], lemu.anonymousId);
  });

  test('C08 setConsent(false) discards held messages', () async {
    final lemu = core(options: const LemuOptions(requireConsent: true));
    lemu.track('X');
    lemu.setConsent(false);
    lemu.setConsent(true);
    await lemu.flush();
    await settle(20);
    expect(server.requests, isEmpty);
  });

  test('C09 optOut stops sending and survives a new instance; optIn resumes',
      () async {
    final storage = InMemoryLemuStorage();
    final first = core(storage: storage);
    first.optOut();
    first.track('X');
    await first.flush();
    expect(server.requests, isEmpty);
    await first.close();

    final second = core(storage: storage);
    await second.ready;
    expect(second.isOptedOut, isTrue);
    second.track('X');
    await second.flush();
    expect(server.requests, isEmpty);

    second.optIn();
    second.track('Y');
    await second.flush();
    expect(server.messages.single['event'], 'Y');
  });

  test('C10 a 500 is retried and delivered once with the same messageIds',
      () async {
    final lemu = core();
    server.respondWith([500]);
    lemu.track('A');
    lemu.track('B');
    await lemu.flush();
    expect(server.requests, hasLength(1));
    expect(lemu.queueLength, 2);
    expect(lemu.currentBackoff, isNotNull);

    await lemu.flush();
    expect(server.requests, hasLength(2));
    final firstIds = server.requests[0].messages.map((m) => m['messageId']);
    final secondIds = server.requests[1].messages.map((m) => m['messageId']);
    expect(secondIds, firstIds.toList());
    expect(server.acceptedMessages, hasLength(2));
    expect(lemu.queueLength, 0);

    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(server.requests, hasLength(2), reason: 'no duplicate delivery');
  });

  test('C11 a 400 drops the batch without retrying', () async {
    final lemu = core();
    server.respondWith([400]);
    lemu.track('A');
    await lemu.flush();
    expect(lemu.queueLength, 0);
    await lemu.flush();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(server.requests, hasLength(1));
  });

  test('C12 a 413 on a 2-message batch is split into two requests', () async {
    final lemu = core();
    server.respondWith([413]);
    lemu.track('A');
    lemu.track('B');
    await lemu.flush();

    expect(server.requests, hasLength(3));
    expect(server.requests[0].messages, hasLength(2));
    expect(server.requests[1].messages.single['event'], 'A');
    expect(server.requests[2].messages.single['event'], 'B');
    expect(lemu.queueLength, 0);
  });

  test('C13 the queue survives a restart while the server is down', () async {
    final storage = InMemoryLemuStorage();
    final offline = core(storage: storage, apiHost: await deadApiHost());
    offline.track('A');
    offline.track('B');
    offline.track('C');
    await offline.flush();
    expect(offline.queueLength, 3);
    await offline.close();

    final online = core(storage: storage);
    await online.flush();
    expect(server.messages.map((m) => m['event']), ['A', 'B', 'C']);
  });

  test('C14 1,001 queued offline keeps 1,000 including the Purchase', () async {
    final storage = InMemoryLemuStorage();
    final offline = core(
      storage: storage,
      apiHost: await deadApiHost(),
      options: const LemuOptions(flushAt: 5000),
    );
    offline.purchase(value: 10, currency: 'INR', orderId: 'o-1');
    for (var i = 0; i < 1000; i++) {
      offline.track('E$i');
    }
    await offline.flush();
    expect(offline.queueLength, 1000);
    await offline.close();

    final stored = jsonDecode(storage.values[LemuStorageKeys.queue]!) as List;
    expect(stored, hasLength(1000));

    final online = core(storage: storage);
    await online.flush();
    final events = server.messages.map((m) => m['event']).toList();
    expect(events, hasLength(1000));
    expect(events, contains('Purchase'));
    expect(events, isNot(contains('E0')),
        reason: 'oldest non-Purchase dropped');
    expect(server.requests.every((r) => r.messages.length <= 50), isTrue);
  });

  test('C15 app_installed on first launch, app_updated after an upgrade',
      () async {
    final storage = InMemoryLemuStorage();
    final first = core(storage: storage, info: testPlatformInfo());
    first.recordAppLaunch();
    await first.flush();
    final installed = server.messages.single;
    expect(installed['event'], 'app_installed');
    expect(installed['properties'], {'version': '1.0.0', 'build': '1'});
    await first.close();

    final same = core(storage: storage, info: testPlatformInfo());
    same.recordAppLaunch();
    await same.flush();
    expect(server.messages, hasLength(1), reason: 'same version: no event');
    await same.close();

    final upgraded = core(
        storage: storage, info: testPlatformInfo(version: '1.1.0', build: '2'));
    upgraded.recordAppLaunch();
    await upgraded.flush();
    final updated = server.messages.last;
    expect(updated['event'], 'app_updated');
    expect(updated['properties'], {
      'version': '1.1.0',
      'build': '2',
      'previous_version': '1.0.0',
      'previous_build': '1',
    });
  });

  test('C16 screen sends a screen message', () async {
    final lemu = core();
    lemu.screen('Checkout', {'step': 2});
    await lemu.flush();
    final m = server.messages.single;
    expect(m['type'], 'screen');
    expect(m['name'], 'Checkout');
    expect(m['properties'], {'step': 2});
  });

  test('C17 invalid arguments never throw and empty names send nothing',
      () async {
    final lemu = core();
    expect(() => lemu.track(''), returnsNormally);
    expect(() => lemu.track('   ', null), returnsNormally);
    expect(() => lemu.screen(''), returnsNormally);
    expect(() => lemu.identify(), returnsNormally);
    expect(() => lemu.track('X', null), returnsNormally);
    expect(
      () => lemu.track('Y', {'nan': double.nan, 'obj': Object()}),
      returnsNormally,
    );
    await lemu.flush();
    final events = server.messages.map((m) => m['event']).toList();
    expect(events, ['X', 'Y']);
    expect(server.messages[0]['properties'], <String, dynamic>{});
    expect(server.messages[1]['properties'].containsKey('nan'), isFalse);
    expect(server.messages[1]['properties']['obj'], isA<String>());
  });

  test('C18 sentAt is set at send time, timestamp at call time', () async {
    final clock = TestClock();
    final lemu = core(clock: clock);
    lemu.track('A');
    clock.advance(const Duration(seconds: 3));
    lemu.track('B');
    clock.advance(const Duration(seconds: 5));
    await lemu.flush();

    final body = server.requests.single.body;
    final sentAt = DateTime.parse(body['sentAt'] as String);
    expect(body['sentAt'], '2026-11-14T10:00:08.123Z');
    for (final m in server.messages) {
      expect(
          sentAt.isBefore(DateTime.parse(m['timestamp'] as String)), isFalse);
    }
    expect(server.messages[0]['timestamp'], '2026-11-14T10:00:00.123Z');
    expect(server.messages[1]['timestamp'], '2026-11-14T10:00:03.123Z');
  });

  test('C19 more than 50 queued go out in requests of at most 50', () async {
    final lemu = core(options: const LemuOptions(flushAt: 500));
    for (var i = 0; i < 120; i++) {
      lemu.track('E$i');
    }
    await lemu.flush();
    expect(server.requests.map((r) => r.messages.length), [50, 50, 20]);
    expect(
      server.messages.map((m) => m['event']),
      [for (var i = 0; i < 120; i++) 'E$i'],
    );
  });

  test('C20 every name in events.json is exposed, spelled exactly', () {
    final spec = jsonDecode(File('../spec/events.json').readAsStringSync())
        as Map<String, dynamic>;
    final meta = [
      for (final e in spec['meta_events'] as List) (e as Map)['name'] as String,
    ];
    final lifecycle = [
      for (final e in spec['lifecycle_events'] as List)
        (e as Map)['name'] as String,
    ];
    expect(LemuEvent.metaEvents, meta);
    expect(LemuEvent.lifecycleEvents, lifecycle);
    for (final name in [...meta, ...lifecycle]) {
      expect(LemuEvent.all, contains(name));
    }
    expect(LemuEvent.purchase, 'Purchase');
    expect(LemuEvent.addToCart, 'AddToCart');
    expect(LemuEvent.appInstalled, 'app_installed');
    expect(LemuEvent.screenViewed, 'screen_viewed');
  });
}
