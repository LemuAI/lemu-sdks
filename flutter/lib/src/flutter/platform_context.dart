import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/platform_info.dart';
import '../version.dart';
import '../web/web_bridge_stub.dart'
    if (dart.library.js_interop) '../web/web_bridge_web.dart';
import 'time_zone_stub.dart' if (dart.library.io) 'time_zone_io.dart';

/// Reads app, device, OS, screen, locale and time zone context. Never
/// reads advertising or hardware ids. Anything that fails is left out.
Future<LemuPlatformInfo> loadFlutterPlatformInfo() async {
  final context = <String, Object?>{};
  String? appVersion;
  String? appBuild;

  try {
    final p = await PackageInfo.fromPlatform();
    appVersion = _nonEmpty(p.version);
    appBuild = _nonEmpty(p.buildNumber);
    context['app'] = _compact({
      'name': p.appName,
      'version': p.version,
      'build': p.buildNumber,
      'namespace': p.packageName,
    });
  } catch (_) {}

  String? manufacturer;
  String? model;
  String? osName;
  String? osVersion;
  String? browserUserAgent;
  try {
    final plugin = DeviceInfoPlugin();
    if (kIsWeb) {
      final info = await plugin.webBrowserInfo;
      browserUserAgent = info.userAgent;
    } else {
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final info = await plugin.androidInfo;
          manufacturer = info.manufacturer;
          model = info.model;
          osName = 'Android';
          osVersion = info.version.release;
        case TargetPlatform.iOS:
          final info = await plugin.iosInfo;
          manufacturer = 'Apple';
          model = info.utsname.machine;
          osName = info.systemName;
          osVersion = info.systemVersion;
        case TargetPlatform.macOS:
          final info = await plugin.macOsInfo;
          manufacturer = 'Apple';
          model = info.model;
          osName = 'macOS';
          osVersion =
              '${info.majorVersion}.${info.minorVersion}.${info.patchVersion}';
        case TargetPlatform.windows:
          final info = await plugin.windowsInfo;
          osName = 'Windows';
          osVersion =
              '${info.majorVersion}.${info.minorVersion}.${info.buildNumber}';
        case TargetPlatform.linux:
          final info = await plugin.linuxInfo;
          osName = info.name;
          osVersion = info.versionId ?? info.version;
        case TargetPlatform.fuchsia:
          osName = 'Fuchsia';
      }
    }
  } catch (_) {}

  double? shortestSide;
  try {
    final views = ui.PlatformDispatcher.instance.views;
    if (views.isNotEmpty) {
      final view = views.first;
      final size = view.physicalSize;
      final ratio = view.devicePixelRatio;
      if (size.width > 0 && size.height > 0 && ratio > 0) {
        context['screen'] = {
          'width': size.width.round(),
          'height': size.height.round(),
          'density': ratio,
        };
        shortestSide = math.min(size.width, size.height) / ratio;
      }
    }
  } catch (_) {}

  context['device'] = _compact({
    'manufacturer': manufacturer,
    'model': model,
    'type': _deviceType(shortestSide, browserUserAgent),
  });
  final os = _compact({'name': osName, 'version': osVersion});
  if (os.isNotEmpty) context['os'] = os;

  try {
    final locale = ui.PlatformDispatcher.instance.locale.toLanguageTag();
    if (locale.isNotEmpty && locale != 'und') context['locale'] = locale;
  } catch (_) {}

  final timeZone = browserTimeZone() ?? nativeTimeZone();
  if (timeZone != null && timeZone.isNotEmpty) context['timezone'] = timeZone;

  String? userAgent;
  if (kIsWeb) {
    if (browserUserAgent != null) context['userAgent'] = browserUserAgent;
  } else {
    userAgent = buildUserAgent(
      osName: osName,
      osVersion: osVersion,
      model: model,
    );
    context['userAgent'] = userAgent;
  }

  return LemuPlatformInfo(
    context: context,
    userAgent: userAgent,
    appVersion: appVersion,
    appBuild: appBuild,
  );
}

/// `lemu-flutter/<sdk version> (<os> <os version>; <model>)`, ASCII only.
String buildUserAgent({String? osName, String? osVersion, String? model}) {
  final os = [osName, osVersion]
      .whereType<String>()
      .where((s) => s.isNotEmpty)
      .join(' ');
  final parts = [
    if (os.isNotEmpty) os,
    if (model != null && model.isNotEmpty) model,
  ];
  final detail = parts.isEmpty ? '' : ' (${parts.join('; ')})';
  final raw = '$lemuLibraryName/$lemuSdkVersion$detail';
  return String.fromCharCodes(
    raw.codeUnits.map((c) => (c < 0x20 || c > 0x7e) ? 0x3f : c),
  );
}

String _deviceType(double? shortestSide, String? browserUserAgent) {
  if (kIsWeb) return webDeviceType(browserUserAgent);
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return shortestSide != null && shortestSide >= 600 ? 'tablet' : 'phone';
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      return 'desktop';
  }
}

/// Device type from a browser User-Agent. The window size says little on
/// the web, where desktop windows can be narrow.
String webDeviceType(String? userAgent) {
  final ua = userAgent ?? '';
  if (RegExp(r'iPad|Tablet|PlayBook|Silk|Kindle').hasMatch(ua) ||
      (ua.contains('Android') && !ua.contains('Mobi'))) {
    return 'tablet';
  }
  if (RegExp(r'Mobi|iPhone|iPod|Android').hasMatch(ua)) return 'phone';
  if (RegExp(r'SmartTV|SMART-TV|CrKey|AppleTV|Tizen|Web0S').hasMatch(ua)) {
    return 'tv';
  }
  return 'desktop';
}

String? _nonEmpty(String? s) => (s == null || s.isEmpty) ? null : s;

Map<String, Object?> _compact(Map<String, Object?> input) => {
      for (final e in input.entries)
        if (e.value != null && e.value != '') e.key: e.value,
    };
