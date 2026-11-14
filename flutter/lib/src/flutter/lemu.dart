import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../core/events.dart';
import '../core/lemu_core.dart';
import '../core/options.dart';
import '../core/storage.dart';
import '../web/web_bridge_stub.dart'
    if (dart.library.js_interop) '../web/web_bridge_web.dart';
import 'platform_context.dart';
import 'shared_preferences_storage.dart';

/// The Lemu tracking SDK. Call [setup] once in `main()`, then use
/// `Lemu.instance` anywhere.
///
/// ```dart
/// Future<void> main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await Lemu.instance.setup('lpk_...');
///   runApp(const MyApp());
/// }
/// ```
///
/// No method throws. Calls made before [setup] are ignored.
class Lemu with WidgetsBindingObserver {
  Lemu._();

  /// The shared instance.
  static final Lemu instance = Lemu._();

  LemuCore? _core;
  bool _debug = false;
  bool _inBackground = false;
  bool _observing = false;

  /// The engine behind this instance, for advanced use and tests.
  LemuCore? get core => _core;

  /// True once [setup] has been called.
  bool get isSetUp => _core != null;

  /// The anonymous id for this install (or browser), kept until [reset].
  /// Null until [setup] has finished.
  String? get anonymousId => _core?.anonymousId;

  /// The user id set by [identify], or null.
  String? get userId => _core?.userId;

  /// Starts the SDK. [writeKey] is the public key from Lemu, Settings,
  /// Tracking sources. Safe to call before `runApp()`.
  ///
  /// [storage] and [httpClient] replace the defaults (shared_preferences
  /// and package:http) and are mainly for tests.
  Future<void> setup(
    String writeKey, {
    LemuOptions options = const LemuOptions(),
    LemuStorage? storage,
    http.Client? httpClient,
  }) async {
    try {
      _debug = options.debug;
      if (_core != null) {
        _log('setup: already set up, ignored');
        return;
      }
      WidgetsFlutterBinding.ensureInitialized();
      final core = LemuCore(
        writeKey: writeKey,
        options: options,
        storage: storage ?? SharedPreferencesLemuStorage(),
        httpClient: httpClient,
        platformInfo: loadFlutterPlatformInfo,
        idBridge: kIsWeb ? createWebIdBridge() : null,
        isWeb: kIsWeb,
        logSink: (message) => debugPrint(message),
      );
      _core = core;
      if (options.trackLifecycle) {
        core.recordAppLaunch();
        core.appOpened();
      }
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
      await core.ready;
    } catch (e) {
      _log('setup failed: $e');
    }
  }

  /// Records an event. Use [LemuEvent] constants for Meta standard events
  /// so ads platforms recognise them:
  ///
  /// ```dart
  /// Lemu.instance.track(LemuEvent.addToCart, {
  ///   'value': 999, 'currency': 'INR', 'content_ids': ['SKU1'],
  /// });
  /// ```
  void track(String event, [Map<String, Object?>? properties]) =>
      _core?.track(event, properties);

  /// Records a screen view. See also [LemuNavigatorObserver].
  void screen(String name, [Map<String, Object?>? properties]) =>
      _core?.screen(name, properties);

  /// Tells Lemu who the user is. [traits] may hold `email`, `phone` (E.164),
  /// `first_name`, `last_name`, `name` and anything else. Contact details
  /// belong here and nowhere else.
  void identify({String? userId, Map<String, Object?>? traits}) =>
      _core?.identify(userId: userId, traits: traits);

  /// Records a `Purchase` and sends it at once. Always pass the order id
  /// from your backend so the same order reported by the app, the website
  /// or your server counts once.
  void purchase({
    required num value,
    required String currency,
    required String orderId,
    List<LemuContent>? contents,
    List<String>? contentIds,
    int? numItems,
    Map<String, Object?>? properties,
  }) =>
      _core?.purchase(
        value: value,
        currency: currency,
        orderId: orderId,
        contents: contents,
        contentIds: contentIds,
        numItems: numItems,
        properties: properties,
      );

  /// Call on logout: a new anonymous id and no user id.
  void reset() => _core?.reset();

  /// Sends queued events now.
  Future<void> flush() => _core?.flush() ?? Future<void>.value();

  /// With `requireConsent: true`, nothing is sent or stored until this is
  /// called with true. False discards held and queued events.
  void setConsent(bool granted) => _core?.setConsent(granted);

  /// Stops all tracking on this device, remembered across launches.
  void optOut() => _core?.optOut();

  /// Resumes tracking after [optOut].
  void optIn() => _core?.optIn();

  /// Records `deep_link_opened` for a link that opened the app and keeps its
  /// UTM parameters for the rest of the session. Pass links from app_links,
  /// go_router or your own handler.
  void trackDeepLink(Uri uri, {String? referrer}) =>
      _core?.trackDeepLink(uri, referrer: referrer);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final core = _core;
    if (core == null) return;
    try {
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden) {
        if (_inBackground) return;
        _inBackground = true;
        core.appBackgrounded();
      } else if (state == AppLifecycleState.resumed) {
        if (!_inBackground) return;
        _inBackground = false;
        core.appOpened(fromBackground: true);
      }
    } catch (e) {
      _log('lifecycle: $e');
    }
  }

  /// Shuts the instance down so [setup] can run again. For tests.
  @visibleForTesting
  Future<void> debugTearDown() async {
    final core = _core;
    _core = null;
    _inBackground = false;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    await core?.close();
  }

  void _log(String message) {
    if (_debug) debugPrint('[Lemu] $message');
  }
}
