import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lemu_analytics/core.dart';

import 'schema.dart';

const testWriteKey = 'pk_test_123';
const testUserAgent = 'lemu-flutter/1.0.0 (Android 14; Pixel 8)';

/// A clock the test moves by hand.
class TestClock {
  TestClock([DateTime? start])
      : now = start ?? DateTime.utc(2026, 11, 14, 10, 0, 0, 123);

  DateTime now;

  DateTime call() => now;

  void advance(Duration d) => now = now.add(d);
}

/// A package:http MockClient that records requests and answers with
/// statuses the test chooses, or fails like a dead network.
class RecordingClient {
  RecordingClient() {
    client = MockClient((request) async {
      if (!online) throw http.ClientException('offline', request.url);
      final status = statuses.isNotEmpty ? statuses.removeAt(0) : defaultStatus;
      requests.add(request);
      responses.add(status);
      return http.Response('', status);
    });
  }

  late final MockClient client;
  final List<http.Request> requests = [];
  final List<int> responses = [];
  final List<int> statuses = [];
  int defaultStatus = 204;
  bool online = true;

  List<Map<String, dynamic>> bodies() => [
        for (final r in requests) jsonDecode(r.body) as Map<String, dynamic>,
      ];

  List<Map<String, dynamic>> get messages => [
        for (final b in bodies())
          ...(b['batch'] as List).cast<Map<String, dynamic>>(),
      ];

  List<Map<String, dynamic>> get acceptedMessages => [
        for (var i = 0; i < requests.length; i++)
          if (responses[i] >= 200 && responses[i] < 300)
            ...((jsonDecode(requests[i].body) as Map)['batch'] as List)
                .cast<Map<String, dynamic>>(),
      ];

  /// Every recorded body must validate against batch.schema.json.
  void expectValidBodies() {
    for (final r in requests) {
      expect(validateBody(r.body), isEmpty, reason: r.body);
    }
  }
}

LemuPlatformInfo testPlatformInfo({
  String version = '1.0.0',
  String build = '1',
  String? userAgent = testUserAgent,
}) =>
    LemuPlatformInfo(
      context: {
        'app': {
          'name': 'Brand',
          'version': version,
          'build': build,
          'namespace': 'com.brand.app',
        },
        'device': {
          'manufacturer': 'Google',
          'model': 'Pixel 8',
          'type': 'phone'
        },
        'os': {'name': 'Android', 'version': '14'},
        'screen': {'width': 1080, 'height': 2400, 'density': 2.625},
        'locale': 'en-IN',
        'timezone': 'Asia/Kolkata',
        if (userAgent != null) 'userAgent': userAgent,
      },
      userAgent: userAgent,
      appVersion: version,
      appBuild: build,
    );

final List<LemuCore> _open = [];

/// Builds a core for tests and closes it after the test.
LemuCore makeCore({
  http.Client? client,
  String? apiHost,
  LemuStorage? storage,
  LemuOptions options = const LemuOptions(),
  TestClock? clock,
  LemuPlatformInfo? info,
  LemuIdBridge? idBridge,
  bool isWeb = false,
  List<String>? logs,
  String writeKey = testWriteKey,
}) {
  final core = LemuCore(
    writeKey: writeKey,
    options: apiHost == null ? options : options.copyWith(apiHost: apiHost),
    storage: storage ?? InMemoryLemuStorage(),
    httpClient: client,
    clock: clock?.call,
    platformInfo: () => info ?? testPlatformInfo(),
    idBridge: idBridge,
    isWeb: isWeb,
    logSink: logs == null ? (_) {} : logs.add,
    requestTimeout: const Duration(seconds: 2),
  );
  _open.add(core);
  return core;
}

/// Call from tearDown.
Future<void> closeCores() async {
  for (final core in List.of(_open)) {
    await core.close();
  }
  _open.clear();
}

/// Lets the internal chain and pending sends run.
Future<void> settle([int rounds = 5]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final uuidV4Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// Polls [check] until it is true or [timeout] passes.
Future<void> eventually(
  bool Function() check, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!check()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
