import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One request the fake server received.
class RecordedRequest {
  RecordedRequest(this.headers, this.rawBody, this.status);

  final Map<String, String> headers;
  final String rawBody;
  final int status;

  Map<String, dynamic> get body => jsonDecode(rawBody) as Map<String, dynamic>;

  List<Map<String, dynamic>> get messages =>
      (body['batch'] as List).cast<Map<String, dynamic>>();
}

/// A local stand-in for `POST /api/v1/pixel/batch` on 127.0.0.1 that
/// records request bodies and answers with statuses the test chooses.
class FakeIngestServer {
  FakeIngestServer._(this._server) {
    _server.listen(_handle);
  }

  static Future<FakeIngestServer> start() async => FakeIngestServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final List<RecordedRequest> requests = [];
  final List<int> _statuses = [];
  final StreamController<RecordedRequest> _events =
      StreamController.broadcast();

  /// Status used when no queued status is left.
  int defaultStatus = 204;

  String get apiHost => 'http://127.0.0.1:${_server.port}';

  /// Answer the next requests with these statuses, in order.
  void respondWith(List<int> statuses) => _statuses.addAll(statuses);

  List<Map<String, dynamic>> get messages =>
      [for (final r in requests) ...r.messages];

  /// Messages from requests the server accepted (2xx).
  List<Map<String, dynamic>> get acceptedMessages => [
        for (final r in requests)
          if (r.status >= 200 && r.status < 300) ...r.messages,
      ];

  Future<void> _handle(HttpRequest request) async {
    final raw = await utf8.decoder.bind(request).join();
    final headers = <String, String>{};
    request.headers.forEach((name, values) => headers[name] = values.join(','));
    final status = _statuses.isNotEmpty ? _statuses.removeAt(0) : defaultStatus;
    final recorded = RecordedRequest(headers, raw, status);
    requests.add(recorded);
    request.response.statusCode = status;
    await request.response.close();
    _events.add(recorded);
  }

  /// Waits until at least [count] requests have arrived.
  Future<void> waitForRequests(
    int count, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (requests.length < count) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
          'expected $count requests, got ${requests.length}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> close() async {
    await _server.close(force: true);
    await _events.close();
  }
}

/// A host:port where nothing listens, for "server down" tests.
Future<String> deadApiHost() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return 'http://127.0.0.1:$port';
}
