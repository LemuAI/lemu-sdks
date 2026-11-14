import 'dart:async';

import 'package:http/http.dart' as http;

/// Outcome of one POST to the batch endpoint.
class SendResult {
  const SendResult.status(int this.statusCode)
      : timedOut = false,
        error = null;
  const SendResult.timeout()
      : statusCode = null,
        timedOut = true,
        error = null;
  const SendResult.failed(Object this.error)
      : statusCode = null,
        timedOut = false;

  /// HTTP status, or null when no response arrived.
  final int? statusCode;
  final bool timedOut;
  final Object? error;

  /// True when the server (probably) saw the request, so the 20-hour
  /// give-up window applies.
  bool get reachedServer => statusCode != null || timedOut;

  @override
  String toString() {
    if (statusCode != null) return 'HTTP $statusCode';
    if (timedOut) return 'timeout';
    return 'network error: $error';
  }
}

/// Sends request bodies to `{apiHost}/api/v1/pixel/batch`.
class LemuTransport {
  LemuTransport({
    required String apiHost,
    required this.client,
    required this.isWeb,
    this.userAgent,
    this.timeout = const Duration(seconds: 15),
  }) : endpoint = _endpoint(apiHost);

  final Uri endpoint;
  final http.Client client;
  final bool isWeb;
  final String? userAgent;
  final Duration timeout;

  static Uri _endpoint(String apiHost) {
    var host = apiHost.trim();
    while (host.endsWith('/')) {
      host = host.substring(0, host.length - 1);
    }
    return Uri.parse('$host/api/v1/pixel/batch');
  }

  Future<SendResult> post(String body) async {
    final headers = <String, String>{
      // Browsers: text/plain avoids a CORS preflight. The server reads the
      // body as JSON either way.
      'Content-Type': isWeb
          ? 'text/plain;charset=UTF-8'
          : 'application/json; charset=utf-8',
      if (!isWeb && userAgent != null) 'User-Agent': userAgent!,
    };
    try {
      final response = await client
          .post(endpoint, headers: headers, body: body)
          .timeout(timeout);
      return SendResult.status(response.statusCode);
    } on TimeoutException {
      return const SendResult.timeout();
    } catch (e) {
      return SendResult.failed(e);
    }
  }
}
