import 'package:flutter/widgets.dart';

import 'lemu.dart';

/// Returns the screen name for [route], or null to skip it.
typedef LemuScreenNameExtractor = String? Function(Route<dynamic> route);

/// Sends a `screen` message whenever a named page route becomes visible.
///
/// ```dart
/// MaterialApp(navigatorObservers: [LemuNavigatorObserver()]);
/// GoRouter(observers: [LemuNavigatorObserver()], routes: [...]);
/// ```
///
/// Routes without a name (`RouteSettings.name`) and non-page routes such
/// as dialogs and bottom sheets are skipped unless [nameExtractor] or
/// [routeFilter] say otherwise.
class LemuNavigatorObserver extends NavigatorObserver {
  LemuNavigatorObserver({
    this.nameExtractor = defaultNameExtractor,
    this.routeFilter = defaultRouteFilter,
    Lemu? lemu,
  }) : _lemu = lemu;

  final LemuScreenNameExtractor nameExtractor;
  final bool Function(Route<dynamic> route) routeFilter;
  final Lemu? _lemu;

  Lemu get _target => _lemu ?? Lemu.instance;

  /// Uses `route.settings.name`.
  static String? defaultNameExtractor(Route<dynamic> route) =>
      route.settings.name;

  /// Accepts page routes only.
  static bool defaultRouteFilter(Route<dynamic> route) => route is PageRoute;

  void _send(Route<dynamic>? route) {
    if (route == null) return;
    try {
      if (!routeFilter(route)) return;
      final name = nameExtractor(route);
      if (name == null || name.trim().isEmpty) return;
      _target.screen(name);
    } catch (_) {
      // Never break navigation.
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _send(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _send(newRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (route is PageRoute) _send(previousRoute);
  }
}
