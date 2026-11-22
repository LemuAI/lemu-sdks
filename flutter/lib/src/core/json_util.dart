import '../core/events.dart';

/// Formats [time] as ISO 8601 in UTC with exactly three fraction digits,
/// for example `2026-11-14T10:00:01.123Z`.
String isoTimestamp(DateTime time) {
  final t = time.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final year = t.year.toString().padLeft(4, '0');
  final ms = t.millisecond.toString().padLeft(3, '0');
  return '$year-${two(t.month)}-${two(t.day)}T${two(t.hour)}:'
      '${two(t.minute)}:${two(t.second)}.${ms}Z';
}

const int _maxDepth = 12;

/// Converts arbitrary app values into something `jsonEncode` accepts.
/// Unknown objects become their `toString()`, non-finite numbers are left
/// out, and map keys become strings.
Map<String, Object?> sanitizeMap(Map<dynamic, dynamic>? input) {
  if (input == null) return <String, Object?>{};
  final out = <String, Object?>{};
  input.forEach((key, value) {
    if (key == null) return;
    final v = _sanitize(value, 0);
    if (v is _Skip) return;
    out[key.toString()] = v;
  });
  return out;
}

class _Skip {
  const _Skip();
}

const _skip = _Skip();

Object? _sanitize(Object? value, int depth) {
  if (depth > _maxDepth) return _skip;
  if (value == null || value is String || value is bool) return value;
  if (value is num) {
    if (value is double && (value.isNaN || value.isInfinite)) return _skip;
    return value;
  }
  if (value is DateTime) return isoTimestamp(value);
  if (value is Uri) return value.toString();
  if (value is Enum) return value.name;
  if (value is LemuContent) return _sanitize(value.toJson(), depth + 1);
  if (value is Map) {
    final out = <String, Object?>{};
    value.forEach((k, v) {
      if (k == null) return;
      final s = _sanitize(v, depth + 1);
      if (s is _Skip) return;
      out[k.toString()] = s;
    });
    return out;
  }
  if (value is Iterable) {
    return value
        .map((e) => _sanitize(e, depth + 1))
        .where((e) => e is! _Skip)
        .toList();
  }
  try {
    final dynamic d = value;
    // Objects with a toJson() (json_serializable, freezed, ...).
    // ignore: avoid_dynamic_calls
    final Object? json = d.toJson();
    return _sanitize(json, depth + 1);
  } catch (_) {
    return value.toString();
  }
}

/// UTM parameters (without the `utm_` prefix) plus `gclid` / `fbclid` found
/// in [uri]'s query string. Empty when there are none.
Map<String, String> campaignFromUri(Uri uri) {
  const keys = {
    'utm_source': 'source',
    'utm_medium': 'medium',
    'utm_campaign': 'campaign',
    'utm_term': 'term',
    'utm_content': 'content',
    'gclid': 'gclid',
    'fbclid': 'fbclid',
    'lmclid': 'lmclid',
  };
  final out = <String, String>{};
  Map<String, String> params;
  try {
    params = uri.queryParameters;
  } catch (_) {
    return out;
  }
  keys.forEach((param, field) {
    final value = params[param];
    if (value != null && value.isNotEmpty) out[field] = value;
  });
  return out;
}
