import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../version.dart';
import 'events.dart';
import 'json_util.dart';
import 'options.dart';
import 'platform_info.dart';
import 'storage.dart';
import 'transport.dart';
import 'uuid.dart';

/// Returns the current time. Injected in tests.
typedef LemuClock = DateTime Function();

/// Receives debug log lines.
typedef LemuLogSink = void Function(String message);

/// Loads app and device context once, at start-up.
typedef LemuPlatformInfoLoader = FutureOr<LemuPlatformInfo> Function();

/// A message waiting in the queue, with the time it was queued.
class QueuedMessage {
  QueuedMessage(this.message, this.queuedAt) : encoded = jsonEncode(message) {
    bytes = utf8.encode(encoded).length;
  }

  final Map<String, Object?> message;
  final DateTime queuedAt;

  /// The message as JSON, encoded once.
  final String encoded;
  late final int bytes;

  String get messageId => message['messageId'] as String;

  bool get isPurchase =>
      message['type'] == 'track' && message['event'] == LemuEvent.purchase;

  DateTime get timestamp {
    final raw = message['timestamp'];
    return (raw is String ? DateTime.tryParse(raw) : null) ?? queuedAt;
  }

  String toStorageJson() =>
      '{"q":${queuedAt.millisecondsSinceEpoch},"m":$encoded}';

  static QueuedMessage? fromStorageJson(Object? json) {
    if (json is! Map) return null;
    final m = json['m'];
    final q = json['q'];
    if (m is! Map || q is! int) return null;
    final message = Map<String, Object?>.from(m);
    if (message['messageId'] is! String || message['type'] is! String) {
      return null;
    }
    return QueuedMessage(
      message,
      DateTime.fromMillisecondsSinceEpoch(q, isUtc: true),
    );
  }
}

class _Delivery {
  _Delivery({Set<String>? removed, this.retryBatch, this.retryResult})
      : removed = removed ?? <String>{};

  final Set<String> removed;
  final List<QueuedMessage>? retryBatch;
  final SendResult? retryResult;

  bool get needsRetry => retryResult != null;
}

/// The platform-independent SDK: message building, identity, consent,
/// the persisted queue, batching, flushing and retries. Pure Dart.
///
/// Public methods never throw. Calls are applied in order on an internal
/// chain, so they can be made before start-up has finished.
class LemuCore {
  LemuCore({
    required String writeKey,
    LemuOptions options = const LemuOptions(),
    LemuStorage? storage,
    http.Client? httpClient,
    LemuClock? clock,
    LemuPlatformInfoLoader? platformInfo,
    LemuIdBridge? idBridge,
    bool isWeb = false,
    String platform = 'flutter',
    Random? random,
    LemuLogSink? logSink,
    Duration requestTimeout = const Duration(seconds: 15),
  })  : _writeKey = writeKey.trim(),
        _options = options,
        _storage = storage ?? InMemoryLemuStorage(),
        _client = httpClient ?? http.Client(),
        _ownsClient = httpClient == null,
        _clock = clock ?? _systemClock,
        _idBridge = idBridge,
        _isWeb = isWeb,
        _platform = platform,
        _random = random ?? Random(),
        _logSink = logSink ?? _printSink,
        _requestTimeout = requestTimeout,
        _flushAt = max(1, options.flushAt ?? (isWeb ? 10 : 20)),
        _flushInterval = options.flushInterval ??
            (isWeb ? const Duration(seconds: 1) : const Duration(seconds: 30)),
        _maxQueue =
            options.maxQueueSize.clamp(1, LemuOptions.queueLimit).toInt(),
        _consent = !options.requireConsent {
    if (_writeKey.isEmpty) _log('setup: the write key is empty');
    _run('setup', () => _init(platformInfo));
  }

  static const int maxBatchSize = 50;
  static const int maxBatchBytes = 250 * 1024;
  static const int maxHeld = 50;
  static const Duration maxMessageAge = Duration(days: 7);
  static const Duration giveUpAfter = Duration(hours: 20);
  static const Duration maxBackoff = Duration(minutes: 5);

  final String _writeKey;
  final LemuOptions _options;
  final LemuStorage _storage;
  final http.Client _client;
  final bool _ownsClient;
  final LemuClock _clock;
  final LemuIdBridge? _idBridge;
  final bool _isWeb;
  final String _platform;
  final Random _random;
  final LemuLogSink _logSink;
  final Duration _requestTimeout;
  final int _flushAt;
  final Duration _flushInterval;
  final int _maxQueue;

  // Identity and consent.
  String? _anonymousId;
  String? _userId;
  bool _optedOut = false;
  bool _consent;
  Map<String, String> _campaign = const {};
  Map<String, Object?> _baseContext = const {};
  String? _appVersion;
  String? _appBuild;
  bool _appVersionPending = false;

  // Queue.
  final List<QueuedMessage> _queue = [];
  final List<Map<String, Object?>> _held = [];
  bool _queueDirty = false;
  bool _persistQueued = false;

  // Sending.
  LemuTransport? _transport;
  Future<void>? _inFlight;
  bool _again = false;
  bool _againForce = false;
  int _attempt = 0;
  DateTime? _nextAttemptAt;
  Duration? _lastBackoff;
  Timer? _flushTimer;
  Timer? _retryTimer;

  Future<void> _chain = Future<void>.value();
  final Completer<void> _ready = Completer<void>();
  bool _closed = false;

  static DateTime _systemClock() => DateTime.now().toUtc();

  static void _printSink(String message) {
    // ignore: avoid_print
    print(message);
  }

  // ---------------------------------------------------------------------
  // State for callers and tests.

  /// Completes once stored state has been loaded.
  Future<void> get ready => _ready.future;

  /// The anonymous id, or null before start-up has finished.
  String? get anonymousId => _anonymousId;

  /// The user id set by [identify], or null.
  String? get userId => _userId;

  bool get isOptedOut => _optedOut;
  bool get hasConsent => _consent;
  bool get isWeb => _isWeb;
  int get flushAt => _flushAt;
  Duration get flushInterval => _flushInterval;

  /// Messages queued for sending (not counting those held for consent).
  int get queueLength => _queue.length;

  /// Messages held in memory waiting for consent.
  int get heldLength => _held.length;

  /// Message ids currently queued, oldest first.
  List<String> get queuedMessageIds =>
      _queue.map((m) => m.messageId).toList(growable: false);

  /// Delay before the next automatic retry, or null when not backing off.
  Duration? get currentBackoff => _nextAttemptAt == null ? null : _lastBackoff;

  /// Session campaign (UTM) parameters.
  Map<String, String> get campaign => Map.unmodifiable(_campaign);

  bool get _storageAllowed => !_optedOut && _consent && !_closed;
  bool get _canSend =>
      !_optedOut && _consent && !_closed && _writeKey.isNotEmpty;

  // ---------------------------------------------------------------------
  // Public API. None of these throw.

  /// Records an event. Use [LemuEvent] constants for standard events.
  void track(String event, [Map<String, Object?>? properties]) {
    _guard('track', () {
      final name = event.trim();
      if (name.isEmpty) {
        _log('track: ignored, the event name is empty');
        return;
      }
      _record(
        'track',
        {'event': name, 'properties': sanitizeMap(properties)},
        flushNow: name == LemuEvent.purchase,
      );
    });
  }

  /// Records a screen view.
  void screen(String name, [Map<String, Object?>? properties]) {
    _guard('screen', () {
      final n = name.trim();
      if (n.isEmpty) {
        _log('screen: ignored, the screen name is empty');
        return;
      }
      _record('screen', {'name': n, 'properties': sanitizeMap(properties)});
    });
  }

  /// Tells Lemu who the user is. [userId] is kept and sent with every
  /// later message until [reset]. [traits] (email, phone in E.164,
  /// first_name, last_name, ...) are the only place contact details belong.
  void identify({String? userId, Map<String, Object?>? traits}) {
    _guard('identify', () {
      var id = userId?.trim();
      if (id != null && id.isEmpty) id = null;
      if (id != null && id.length > 255) {
        _log('identify: userId is longer than 255 characters, ignored');
        id = null;
      }
      final cleanTraits = sanitizeMap(traits);
      final newUserId = id;
      if (newUserId == null && cleanTraits.isEmpty) {
        _log('identify: ignored, no userId and no traits');
        return;
      }
      _record(
        'identify',
        {'traits': cleanTraits},
        before: newUserId == null
            ? null
            : () async {
                _userId = newUserId;
                if (_storageAllowed) {
                  await _write(LemuStorageKeys.userId, newUserId);
                }
              },
      );
    });
  }

  /// Records a `Purchase` and sends it right away.
  ///
  /// [orderId] lets Lemu count one conversion per order, however many
  /// sources (app, website, server, Shopify) report it.
  void purchase({
    required num value,
    required String currency,
    required String orderId,
    List<LemuContent>? contents,
    List<String>? contentIds,
    int? numItems,
    Map<String, Object?>? properties,
  }) {
    _guard('purchase', () {
      if (value is double && (value.isNaN || value.isInfinite)) {
        _log('purchase: value is not a finite number');
      }
      if (currency.trim().isEmpty) _log('purchase: currency is empty');
      if (orderId.trim().isEmpty) _log('purchase: orderId is empty');
      final props = sanitizeMap(properties);
      props['value'] = value;
      props['currency'] = currency.trim().toUpperCase();
      props['order_id'] = orderId.trim();
      if (contents != null && contents.isNotEmpty) {
        props['contents'] = contents.map((c) => c.toJson()).toList();
      }
      final ids = contentIds ?? contents?.map((c) => c.id).toList();
      if (ids != null && ids.isNotEmpty) props['content_ids'] = ids;
      final items = numItems ??
          (contents == null || contents.isEmpty
              ? null
              : contents.fold<int>(0, (sum, c) => sum + c.quantity));
      if (items != null) props['num_items'] = items;
      _record(
        'track',
        {'event': LemuEvent.purchase, 'properties': sanitizeMap(props)},
        flushNow: true,
      );
    });
  }

  /// Logout: a new anonymous id and no user id.
  void reset() {
    _guard('reset', () {
      _log('reset');
      _run('reset', () async {
        _anonymousId = uuidV4(_random);
        _userId = null;
        await _remove(LemuStorageKeys.userId);
        if (_storageAllowed) {
          await _write(LemuStorageKeys.anonymousId, _anonymousId!);
          _bridgeWrite(_anonymousId!);
        }
      });
    });
  }

  /// Sends everything queued now. Completes when the attempt is over.
  Future<void> flush() {
    try {
      _log('flush');
      return _run('flush', () {})
          .then((_) => _flushNow(force: true))
          .catchError((Object e) => _log('flush failed: $e'));
    } catch (e) {
      _log('flush failed: $e');
      return Future<void>.value();
    }
  }

  /// Grants or withdraws consent. Granting sends the held messages;
  /// withdrawing discards them and the queue.
  void setConsent(bool granted) {
    _guard('setConsent', () {
      _log('setConsent($granted)');
      _run('setConsent', () async {
        if (granted) {
          if (_consent) return;
          _consent = true;
          if (_optedOut) return;
          await _write(LemuStorageKeys.consent, '1');
          await _persistIdentity();
          final now = _now();
          final held = List.of(_held);
          _held.clear();
          for (final m in held) {
            _addToQueue(QueuedMessage(m, now));
          }
          _markDirty();
          if (_queue.isNotEmpty) _triggerFlush();
        } else {
          _consent = false;
          _held.clear();
          _clearQueue();
          await _remove(LemuStorageKeys.queue);
          await _remove(LemuStorageKeys.consent);
        }
      });
    });
  }

  /// Stops all tracking, clears the queue and remembers the choice across
  /// launches.
  void optOut() {
    _guard('optOut', () {
      _log('optOut');
      _run('optOut', () async {
        _optedOut = true;
        _held.clear();
        _clearQueue();
        await _write(LemuStorageKeys.optOut, '1');
        await _remove(LemuStorageKeys.queue);
      });
    });
  }

  /// Undoes [optOut].
  void optIn() {
    _guard('optIn', () {
      _log('optIn');
      _run('optIn', () async {
        if (!_optedOut) return;
        _optedOut = false;
        await _remove(LemuStorageKeys.optOut);
        await _persistIdentity();
      });
    });
  }

  /// Records `deep_link_opened` and keeps the link's UTM parameters (and
  /// gclid / fbclid) in `context.campaign` for the rest of the session.
  void trackDeepLink(Uri uri, {String? referrer}) {
    _guard('trackDeepLink', () {
      final timestamp = _now();
      final messageId = uuidV4(_random);
      final campaign = campaignFromUri(uri);
      _log('trackDeepLink $uri');
      _run('trackDeepLink', () {
        if (campaign.isNotEmpty) _campaign = campaign;
        if (!_options.trackDeepLinks) return;
        _enqueue(_build(
          'track',
          {
            'event': LemuEvent.deepLinkOpened,
            'properties': {
              'url': uri.toString(),
              if (referrer != null && referrer.isNotEmpty) 'referrer': referrer,
            },
          },
          timestamp,
          messageId,
        ));
      });
    });
  }

  /// Sends `app_installed` on the first launch or `app_updated` when the
  /// stored version differs, then stores the current version.
  void recordAppLaunch() {
    _guard('recordAppLaunch', () {
      if (!_options.trackLifecycle) return;
      final timestamp = _now();
      _run('recordAppLaunch', () async {
        final version = _appVersion;
        final build = _appBuild;
        if (version == null) return;
        final previousVersion = await _read(LemuStorageKeys.appVersion);
        final previousBuild = await _read(LemuStorageKeys.appBuild);
        if (previousVersion == null) {
          _enqueue(_build(
            'track',
            {
              'event': LemuEvent.appInstalled,
              'properties': {
                'version': version,
                if (build != null) 'build': build,
              },
            },
            timestamp,
            uuidV4(_random),
          ));
        } else if (previousVersion != version ||
            (build != null && previousBuild != build)) {
          _enqueue(_build(
            'track',
            {
              'event': LemuEvent.appUpdated,
              'properties': {
                'version': version,
                if (build != null) 'build': build,
                'previous_version': previousVersion,
                if (previousBuild != null) 'previous_build': previousBuild,
              },
            },
            timestamp,
            uuidV4(_random),
          ));
        }
        _appVersionPending = true;
        await _persistAppVersion();
      });
    });
  }

  /// Sends `app_opened`.
  void appOpened({bool fromBackground = false, String? url}) {
    _guard('appOpened', () {
      if (!_options.trackLifecycle) return;
      _record('track', {
        'event': LemuEvent.appOpened,
        'properties': {
          'from_background': fromBackground,
          if (url != null && url.isNotEmpty) 'url': url,
        },
      });
    });
  }

  /// Sends `app_backgrounded` and flushes.
  void appBackgrounded() {
    _guard('appBackgrounded', () {
      if (_options.trackLifecycle) {
        _record('track', {
          'event': LemuEvent.appBackgrounded,
          'properties': <String, Object?>{},
        });
      }
      _run('background flush', () {}).then((_) => _triggerFlush());
    });
  }

  /// Stops timers and closes the HTTP client if the SDK created it. Waits
  /// for pending calls to be applied first.
  Future<void> close() async {
    try {
      await _chain;
      _closed = true;
      _flushTimer?.cancel();
      _retryTimer?.cancel();
      if (_ownsClient) _client.close();
    } catch (_) {}
  }

  // ---------------------------------------------------------------------
  // Internals.

  DateTime _now() {
    try {
      return _clock().toUtc();
    } catch (_) {
      return DateTime.now().toUtc();
    }
  }

  void _log(String message) {
    if (!_options.debug) return;
    try {
      _logSink('[Lemu] $message');
    } catch (_) {}
  }

  void _guard(String what, void Function() body) {
    try {
      body();
    } catch (e) {
      _log('$what failed: $e');
    }
  }

  Future<void> _run(String what, FutureOr<void> Function() op) {
    final next = _chain.then((_) async {
      if (_closed) return;
      try {
        await op();
      } catch (e) {
        _log('$what failed: $e');
      }
    });
    _chain = next;
    return next;
  }

  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key);
    } catch (e) {
      _log('storage read $key failed: $e');
      return null;
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _storage.write(key, value);
    } catch (e) {
      _log('storage write $key failed: $e');
    }
  }

  Future<void> _remove(String key) async {
    try {
      await _storage.remove(key);
    } catch (e) {
      _log('storage remove $key failed: $e');
    }
  }

  static bool _validAnonymousId(String? id) =>
      id != null && id.trim().isNotEmpty && id.length <= 128;

  Future<void> _init(LemuPlatformInfoLoader? loader) async {
    try {
      var info = const LemuPlatformInfo();
      if (loader != null) {
        try {
          info = await loader();
        } catch (e) {
          _log('reading device and app info failed: $e');
        }
      }
      _baseContext = Map.of(info.context);
      _appVersion = info.appVersion;
      _appBuild = info.appBuild;
      _transport = LemuTransport(
        apiHost: _options.apiHost,
        client: _client,
        isWeb: _isWeb,
        userAgent: info.userAgent,
        timeout: _requestTimeout,
      );

      var bridgeOptedOut = false;
      try {
        bridgeOptedOut = _idBridge?.optedOut ?? false;
      } catch (_) {}
      _optedOut = bridgeOptedOut || await _read(LemuStorageKeys.optOut) == '1';
      if (_options.requireConsent) {
        _consent = await _read(LemuStorageKeys.consent) == '1';
      }

      final stored = await _read(LemuStorageKeys.anonymousId);
      String? fromWeb;
      try {
        fromWeb = _idBridge?.readAnonymousId();
      } catch (_) {}
      if (_validAnonymousId(fromWeb)) {
        _anonymousId = fromWeb;
      } else if (_validAnonymousId(stored)) {
        _anonymousId = stored;
      } else {
        _anonymousId = uuidV4(_random);
      }
      if (_storageAllowed) {
        if (_anonymousId != stored) {
          await _write(LemuStorageKeys.anonymousId, _anonymousId!);
        }
        if (_idBridge != null && _anonymousId != fromWeb) {
          _bridgeWrite(_anonymousId!);
        }
      }
      _userId = await _read(LemuStorageKeys.userId);

      if (_optedOut) {
        await _remove(LemuStorageKeys.queue);
      } else {
        await _loadQueue();
      }
      _log('ready: anonymousId=$_anonymousId userId=$_userId '
          'queued=${_queue.length} consent=$_consent optedOut=$_optedOut');
    } finally {
      if (!_ready.isCompleted) _ready.complete();
      _flushTimer = Timer.periodic(_flushInterval, (_) {
        if (_queue.isNotEmpty) _triggerFlush();
      });
      if (_queue.isNotEmpty) _triggerFlush();
    }
  }

  Future<void> _loadQueue() async {
    final raw = await _read(LemuStorageKeys.queue);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final item in decoded) {
        final m = QueuedMessage.fromStorageJson(item);
        if (m != null) _queue.add(m);
      }
      while (_queue.length > _maxQueue) {
        _dropOne();
      }
    } catch (e) {
      _log('stored queue is unreadable, discarded: $e');
      await _remove(LemuStorageKeys.queue);
    }
  }

  void _bridgeWrite(String id) {
    try {
      _idBridge?.writeAnonymousId(id);
    } catch (_) {}
  }

  Future<void> _persistIdentity() async {
    if (!_storageAllowed) return;
    final id = _anonymousId;
    if (id != null) {
      await _write(LemuStorageKeys.anonymousId, id);
      _bridgeWrite(id);
    }
    final user = _userId;
    if (user != null) await _write(LemuStorageKeys.userId, user);
    await _persistAppVersion();
  }

  Future<void> _persistAppVersion() async {
    if (!_appVersionPending || !_storageAllowed) return;
    final version = _appVersion;
    if (version == null) return;
    _appVersionPending = false;
    await _write(LemuStorageKeys.appVersion, version);
    final build = _appBuild;
    if (build != null) {
      await _write(LemuStorageKeys.appBuild, build);
    } else {
      await _remove(LemuStorageKeys.appBuild);
    }
  }

  /// Captures the call time now and queues the message in call order.
  void _record(
    String type,
    Map<String, Object?> fields, {
    bool flushNow = false,
    FutureOr<void> Function()? before,
  }) {
    final timestamp = _now();
    final messageId = uuidV4(_random);
    if (_options.debug) _log('$type ${jsonEncode(fields)}');
    _run(type, () async {
      if (before != null) await before();
      _enqueue(_build(type, fields, timestamp, messageId));
      if (flushNow) _triggerFlush(force: true);
    });
  }

  Map<String, Object?> _build(
    String type,
    Map<String, Object?> fields,
    DateTime timestamp,
    String messageId,
  ) {
    final user = _userId;
    return <String, Object?>{
      'type': type,
      'messageId': messageId,
      'anonymousId': _anonymousId ?? uuidV4(_random),
      'timestamp': isoTimestamp(timestamp),
      if (user != null) 'userId': user,
      ...fields,
      'context': _buildContext(),
    };
  }

  Map<String, Object?> _buildContext() => <String, Object?>{
        ..._baseContext,
        'platform': _platform,
        'library': const {'name': lemuLibraryName, 'version': lemuSdkVersion},
        if (_campaign.isNotEmpty) 'campaign': Map.of(_campaign),
      };

  void _enqueue(Map<String, Object?> message) {
    if (_optedOut) {
      _log('opted out, ${message['type']} not recorded');
      return;
    }
    if (!_consent) {
      _held.add(message);
      while (_held.length > maxHeld) {
        _held.removeAt(0);
      }
      _log('waiting for consent, ${_held.length} held in memory');
      return;
    }
    _addToQueue(QueuedMessage(message, _now()));
    _markDirty();
    if (_queue.length >= _flushAt) _triggerFlush();
  }

  void _addToQueue(QueuedMessage m) {
    _queue.add(m);
    while (_queue.length > _maxQueue) {
      _dropOne();
    }
  }

  /// Drops the oldest message that is not a Purchase (or the oldest
  /// message when all are purchases).
  void _dropOne() {
    var index = _queue.indexWhere((m) => !m.isPurchase);
    if (index < 0) index = 0;
    final dropped = _queue.removeAt(index);
    _log('queue full, dropped ${dropped.message['type']} '
        '${dropped.message['event'] ?? dropped.message['name'] ?? ''}');
  }

  void _clearQueue() {
    _queue.clear();
    _retryTimer?.cancel();
    _attempt = 0;
    _nextAttemptAt = null;
  }

  void _markDirty() {
    if (!_storageAllowed) return;
    _queueDirty = true;
    if (_persistQueued) return;
    _persistQueued = true;
    _run('persist queue', () async {
      _persistQueued = false;
      if (!_queueDirty || !_storageAllowed) return;
      _queueDirty = false;
      if (_queue.isEmpty) {
        await _remove(LemuStorageKeys.queue);
      } else {
        await _write(
          LemuStorageKeys.queue,
          '[${_queue.map((m) => m.toStorageJson()).join(',')}]',
        );
      }
    });
  }

  void _triggerFlush({bool force = false}) {
    unawaited(_flushNow(force: force));
  }

  Future<void> _flushNow({bool force = false}) {
    if (_closed) return Future<void>.value();
    final current = _inFlight;
    if (current != null) {
      _again = true;
      _againForce = _againForce || force;
      return current;
    }
    final run = _sendLoop(force).catchError((Object e) {
      _log('sending failed: $e');
    });
    final tracked = run.whenComplete(() => _inFlight = null);
    _inFlight = tracked;
    return tracked;
  }

  Future<void> _sendLoop(bool force) async {
    var f = force;
    while (true) {
      _again = false;
      _againForce = false;
      final ok = await _sendPass(f);
      if (!ok || !_again) break;
      f = _againForce;
    }
  }

  Future<bool> _sendPass(bool force) async {
    await ready;
    if (!_canSend || _transport == null) return false;
    final now = _now();
    final next = _nextAttemptAt;
    if (!force && next != null && now.isBefore(next)) return false;
    _dropExpired(now);
    while (_queue.isNotEmpty && _canSend) {
      final batch = _nextBatch();
      final delivery = await _deliver(batch);
      if (delivery.removed.isNotEmpty) _removeIds(delivery.removed);
      if (delivery.needsRetry) {
        _onRetryableFailure(delivery.retryBatch!, delivery.retryResult!);
        return false;
      }
      _attempt = 0;
      _nextAttemptAt = null;
      _lastBackoff = null;
      _retryTimer?.cancel();
    }
    return true;
  }

  void _dropExpired(DateTime now) {
    final before = _queue.length;
    _queue.removeWhere((m) => now.difference(m.timestamp) > maxMessageAge);
    final dropped = before - _queue.length;
    if (dropped > 0) {
      _log('dropped $dropped messages older than 7 days');
      _markDirty();
    }
  }

  List<QueuedMessage> _nextBatch() {
    final out = <QueuedMessage>[];
    var size = 96 + _writeKey.length;
    for (final m in _queue) {
      if (out.length >= maxBatchSize) break;
      if (out.isNotEmpty && size + m.bytes + 1 > maxBatchBytes) break;
      out.add(m);
      size += m.bytes + 1;
    }
    return out;
  }

  String _body(List<QueuedMessage> batch) =>
      '{"writeKey":${jsonEncode(_writeKey)},'
      '"sentAt":"${isoTimestamp(_now())}",'
      '"batch":[${batch.map((m) => m.encoded).join(',')}]}';

  Future<_Delivery> _deliver(List<QueuedMessage> batch) async {
    final ids = batch.map((m) => m.messageId).toSet();
    final body = _body(batch);
    _log('POST ${_transport!.endpoint} (${batch.length} messages) '
        '${body.length > 2000 ? '${body.substring(0, 2000)}...' : body}');
    final result = await _transport!.post(body);
    _log('response: $result');
    final code = result.statusCode;
    if (code != null && code >= 200 && code < 300) {
      return _Delivery(removed: ids);
    }
    if (code == 413) {
      if (batch.length == 1) {
        _log('a single message is too large, dropped');
        return _Delivery(removed: ids);
      }
      final mid = batch.length ~/ 2;
      final first = await _deliver(batch.sublist(0, mid));
      if (first.needsRetry) return first;
      final second = await _deliver(batch.sublist(mid));
      return _Delivery(
        removed: {...first.removed, ...second.removed},
        retryBatch: second.retryBatch,
        retryResult: second.retryResult,
      );
    }
    if (code != null &&
        code >= 400 &&
        code < 500 &&
        code != 429 &&
        code != 408) {
      final reason = switch (code) {
        400 => 'malformed request',
        401 => 'unknown or paused write key',
        403 => 'origin or app not allowed for this write key',
        _ => 'rejected',
      };
      _log('HTTP $code ($reason): dropped ${batch.length} messages');
      return _Delivery(removed: ids);
    }
    return _Delivery(retryBatch: batch, retryResult: result);
  }

  void _removeIds(Set<String> ids) {
    _queue.removeWhere((m) => ids.contains(m.messageId));
    _markDirty();
  }

  void _onRetryableFailure(List<QueuedMessage> batch, SendResult result) {
    final now = _now();
    if (result.reachedServer) {
      final expired = batch
          .where((m) => now.difference(m.queuedAt) >= giveUpAfter)
          .map((m) => m.messageId)
          .toSet();
      if (expired.isNotEmpty) {
        _log('gave up on ${expired.length} messages queued over 20 hours ago');
        _removeIds(expired);
      }
    }
    _attempt++;
    final exponent = min(_attempt - 1, 20);
    final baseMs = min(1000 * pow(2, exponent), maxBackoff.inMilliseconds);
    final jitter = 0.8 + _random.nextDouble() * 0.4;
    final delay = Duration(milliseconds: (baseMs * jitter).round());
    _lastBackoff = delay;
    _nextAttemptAt = now.add(delay);
    _log('will retry in ${delay.inMilliseconds} ms (attempt $_attempt)');
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      if (_queue.isNotEmpty) _triggerFlush(force: true);
    });
  }
}
