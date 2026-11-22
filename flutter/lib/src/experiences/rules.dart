/// The experiences bundle (`GET /api/v1/pixel/onsite/config`) and the rules
/// that decide whether one shows. A port of the website renderer's
/// `rules.ts` and `util.ts`, so apps and the website agree. Pure Dart.
library;

import 'state.dart';

/// Formats apps can show.
const Set<String> appFormats = {'popup', 'slide_in', 'toast', 'bar'};

/// Formats that count towards the popup caps.
const Set<String> overlayFormats = {'popup', 'slide_in'};

Map<String, Object?> asMap(Object? value) {
  if (value is Map) {
    return {for (final e in value.entries) e.key.toString(): e.value};
  }
  return <String, Object?>{};
}

List<Object?> asList(Object? value) =>
    value is List ? List<Object?>.of(value) : const <Object?>[];

String asString(Object? value, [String fallback = '']) =>
    value == null ? fallback : value.toString();

num? asNum(Object? value) {
  if (value is num) return value;
  if (value is String) return num.tryParse(value.trim());
  return null;
}

bool? asBool(Object? value) => value is bool ? value : null;

/// One `where.include` / `where.exclude` item.
class UrlRule {
  const UrlRule(this.type, [this.value = '']);

  factory UrlRule.fromJson(Object? json) {
    final m = asMap(json);
    return UrlRule(asString(m['type'], 'any'), asString(m['value']));
  }

  final String type;
  final String value;
}

/// One targeting condition.
class Condition {
  const Condition(this.kind, {this.op, this.value});

  factory Condition.fromJson(Object? json) {
    final m = asMap(json);
    return Condition(
      asString(m['kind']),
      op: m['op'] == null ? null : asString(m['op']),
      value: m['value'],
    );
  }

  final String kind;
  final String? op;
  final Object? value;
}

/// One variant of an experience.
class ExperienceVariant {
  const ExperienceVariant({
    required this.key,
    required this.weight,
    this.kind = 'blocks',
    this.content = const {},
  });

  factory ExperienceVariant.fromJson(Object? json) {
    final m = asMap(json);
    return ExperienceVariant(
      key: asString(m['key']),
      weight: asNum(m['weight']) ?? 0,
      kind: asString(m['kind'], 'blocks'),
      content: asMap(m['content']),
    );
  }

  final String key;
  final num weight;
  final String kind;
  final Map<String, Object?> content;
}

/// One live experience from the bundle.
class Experience {
  Experience({
    required this.id,
    required this.key,
    this.format = 'popup',
    this.platform = 'app',
    this.version = 1,
    this.schedule = const {},
    this.include = const [],
    this.exclude = const [],
    this.whoMatch = 'all',
    this.conditions = const [],
    this.whoServer = false,
    this.serverConditions = 0,
    this.trigger = const {'on': 'page_load'},
    this.frequency = const {'show': 'session'},
    this.holdoutPct = 0,
    this.variants = const [],
  });

  factory Experience.fromJson(Object? json) {
    final m = asMap(json);
    final where = asMap(m['where']);
    final who = asMap(m['who']);
    final trigger = asMap(m['trigger']);
    final frequency = asMap(m['frequency']);
    return Experience(
      id: asNum(m['id'])?.toInt() ?? 0,
      key: asString(m['key']),
      format: asString(m['format'], 'popup'),
      platform: asString(m['platform'], 'any'),
      version: asNum(m['version'])?.toInt() ?? 1,
      schedule: asMap(m['schedule']),
      include: asList(where['include']).map(UrlRule.fromJson).toList(),
      exclude: asList(where['exclude']).map(UrlRule.fromJson).toList(),
      whoMatch: asString(who['match'], 'all'),
      conditions: asList(who['conditions']).map(Condition.fromJson).toList(),
      whoServer: who['server'] == true,
      serverConditions: asNum(who['server_conditions'])?.toInt() ?? 0,
      trigger: trigger.isEmpty ? const {'on': 'page_load'} : trigger,
      frequency: frequency.isEmpty ? const {'show': 'session'} : frequency,
      holdoutPct: asNum(m['holdout_pct']) ?? 0,
      variants: asList(m['variants']).map(ExperienceVariant.fromJson).toList(),
    );
  }

  final int id;
  final String key;
  final String format;
  final String platform;
  final int version;
  final Map<String, Object?> schedule;
  final List<UrlRule> include;
  final List<UrlRule> exclude;
  final String whoMatch;
  final List<Condition> conditions;
  final bool whoServer;
  final int serverConditions;
  final Map<String, Object?> trigger;
  final Map<String, Object?> frequency;
  final num holdoutPct;
  final List<ExperienceVariant> variants;

  /// `trigger.on`.
  String get triggerOn => asString(trigger['on'], 'page_load');

  /// The event an `event` / `add_to_cart` trigger waits for.
  String? get triggerEvent =>
      triggerOn == 'add_to_cart' ? 'AddToCart' : trigger['event']?.toString();

  /// True when an app can show it: app or any platform, a supported format
  /// and at least one variant.
  bool get renderable =>
      (platform == 'app' || platform == 'any') &&
      appFormats.contains(format) &&
      variants.isNotEmpty &&
      key.isNotEmpty;

  ExperienceVariant? variant(String key) {
    for (final v in variants) {
      if (v.key == key) return v;
    }
    return null;
  }
}

/// The source's bundle.
class ExperienceBundle {
  const ExperienceBundle({
    this.live = false,
    this.version,
    this.theme = const {},
    this.caps = const {},
    this.experiences = const [],
    this.decide = false,
  });

  /// Parses the config response. Anything unusable becomes "not live".
  factory ExperienceBundle.fromJson(Object? json) {
    final m = asMap(json);
    if (m['live'] != true) return const ExperienceBundle();
    final experiences = <Experience>[];
    for (final e in asList(m['experiences'])) {
      try {
        final exp = Experience.fromJson(e);
        if (exp.renderable) experiences.add(exp);
      } catch (_) {
        // Skip an experience the app can't read.
      }
    }
    return ExperienceBundle(
      live: true,
      version: m['v']?.toString(),
      theme: asMap(m['theme']),
      caps: asMap(m['caps']),
      experiences: experiences,
      decide: m['decide'] == true,
    );
  }

  final bool live;
  final String? version;
  final Map<String, Object?> theme;
  final Map<String, Object?> caps;
  final List<Experience> experiences;
  final bool decide;

  Experience? find(String key) {
    for (final e in experiences) {
      if (e.key == key) return e;
    }
    return null;
  }
}

/// The server's answer for the visitor (`POST /onsite/decide`).
class Decision {
  const Decision({this.known = false, this.experiences = const {}});

  factory Decision.fromJson(Object? json) {
    final m = asMap(json);
    final out = <String, DecisionAnswer>{};
    asMap(m['experiences']).forEach((k, v) {
      final a = asMap(v);
      out[k] = DecisionAnswer(
        match: asBool(a['match']),
        hidden: a['hidden'] == true,
      );
    });
    return Decision(known: m['known'] == true, experiences: out);
  }

  final bool known;
  final Map<String, DecisionAnswer> experiences;
}

class DecisionAnswer {
  const DecisionAnswer({this.match, this.hidden = false});

  final bool? match;
  final bool hidden;
}

// ---------------------------------------------------------------------------
// Helpers shared with the website (util.ts).

bool _truthy(Object? v) {
  if (v is String) {
    return const ['true', '1', 'yes', 'y'].contains(v.trim().toLowerCase());
  }
  if (v == null || v == false || v == 0 || v == '') return false;
  if (v is num && v.isNaN) return false;
  return true;
}

/// JavaScript's `String(value)` for the values a bundle holds.
String _jsString(Object? v) {
  if (v == null) return 'null';
  if (v is double && v == v.truncateToDouble() && v.isFinite) {
    return v.toInt().toString();
  }
  if (v is List) return v.map((e) => e == null ? '' : _jsString(e)).join(',');
  return v.toString();
}

num _jsNumber(Object? v) {
  if (v == null) return 0;
  if (v is num) return v;
  if (v is bool) return v ? 1 : 0;
  final s = v.toString().trim();
  if (s.isEmpty) return 0;
  return num.tryParse(s) ?? double.nan;
}

/// Same rules as the server's compare (`api/services/onsite/decide.py`).
bool compare(Object? actual, String? op, Object? expected) {
  final o = (op == null || op.isEmpty) ? 'eq' : op;
  if (o == 'exists') {
    return actual != null &&
        actual != '' &&
        !(actual is List && actual.isEmpty);
  }
  if (o == 'not_exists') return !compare(actual, 'exists', expected);
  if (o == 'in' || o == 'not_in') {
    final list = expected is List
        ? expected
        : _jsString(expected).split(',').cast<Object?>();
    final a = _jsString(actual).trim().toLowerCase();
    final found = list.any((e) => _jsString(e).trim().toLowerCase() == a);
    return o == 'in' ? found : !found;
  }
  if (o == 'contains' || o == 'not_contains') {
    final found = (actual == null ? '' : _jsString(actual))
        .toLowerCase()
        .contains(_jsString(expected).toLowerCase());
    return o == 'contains' ? found : !found;
  }
  if (o == 'gt' || o == 'gte' || o == 'lt' || o == 'lte') {
    final a = _jsNumber(actual);
    final b = _jsNumber(expected);
    if (a.isNaN || b.isNaN) return false;
    switch (o) {
      case 'gt':
        return a > b;
      case 'gte':
        return a >= b;
      case 'lt':
        return a < b;
      default:
        return a <= b;
    }
  }
  final equal = (expected is bool || actual is bool)
      ? _truthy(actual) == _truthy(expected)
      : _jsString(actual).trim().toLowerCase() ==
          _jsString(expected).trim().toLowerCase();
  return o == 'neq' ? !equal : equal;
}

/// Event names compared without case, spaces, `_` or `-`.
bool sameEvent(Object? configured, Object? incoming) {
  String norm(Object? v) =>
      (v ?? '').toString().toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');
  return configured != null &&
      norm(configured).isNotEmpty &&
      norm(configured) == norm(incoming);
}

/// FNV-1a over UTF-16 code units: a stable 0..1 bucket for (visitor,
/// experience), the same number the website and the server compute.
double bucket(String text) {
  var h = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    h ^= unit;
    // h * 0x01000193 mod 2^32, without products above 2^53.
    h = (h * 0x193 + ((h & 0xff) << 24)) & 0xffffffff;
  }
  return h / 0xffffffff;
}

// ---------------------------------------------------------------------------
// Rules (rules.ts).

bool _ruleMatches(UrlRule rule, String screen) {
  final s = screen.trim().toLowerCase();
  final v = rule.value.trim().toLowerCase();
  switch (rule.type) {
    case 'any':
      return true;
    case 'screen_equals':
      return s == v;
    case 'screen_prefix':
      return s.startsWith(v);
    default:
      return false;
  }
}

/// Whether the experience may show on [screen].
bool whereMatches(Experience exp, String screen) {
  final include = exp.include.isNotEmpty ? exp.include : const [UrlRule('any')];
  if (!include.any((r) => _ruleMatches(r, screen))) return false;
  return !exp.exclude.any((r) => _ruleMatches(r, screen));
}

/// The conditions an app can answer; others are left out.
bool? appCondition(Condition c, int visits, String? userId) {
  switch (c.kind) {
    case 'visitor':
      return compare(visits > 1 ? 'returning' : 'new', c.op, c.value);
    case 'visit_count':
      return compare(visits, c.op, c.value);
    case 'identified':
      return compare(userId != null, c.op, c.value ?? true);
    default:
      return null;
  }
}

/// App conditions plus the server's answer, with the experience's all /
/// any rule.
bool whoMatches(
  Experience exp,
  Decision? decision,
  String? userId,
  int visits,
) {
  final results = <bool>[];
  for (final c in exp.conditions) {
    final r = appCondition(c, visits, userId);
    if (r != null) results.add(r);
  }
  final server = decision?.experiences[exp.key];
  if (exp.whoServer && server == null) return false;
  if (server != null && server.hidden) return false;
  final serverCount = exp.serverConditions;
  if (exp.whoMatch == 'any') {
    if (results.isEmpty && serverCount == 0) return true;
    return results.any((r) => r) ||
        (serverCount > 0 && server != null && server.match == true);
  }
  return results.every((r) => r) &&
      (serverCount == 0 || server == null || server.match != false);
}

/// Start, end, days of the week (0 = Monday) and hours. Days and hours use
/// the device's local time (Dart has no time zone database).
bool scheduleOpen(Map<String, Object?> schedule, DateTime now) {
  final start = DateTime.tryParse(asString(schedule['start']));
  final end = DateTime.tryParse(asString(schedule['end']));
  if (start != null && now.isBefore(start)) return false;
  if (end != null && !now.isBefore(end)) return false;
  final local = now.toLocal();
  final days = asList(schedule['days_of_week'])
      .map((d) => asNum(d)?.toInt())
      .whereType<int>()
      .toList();
  if (days.isNotEmpty && !days.contains(local.weekday - 1)) return false;
  final hours = asMap(schedule['hours']);
  final fromText = asString(hours['from']);
  final toText = asString(hours['to']);
  if (fromText.isNotEmpty && toText.isNotEmpty) {
    int toMin(String t) {
      final parts = t.split(':');
      return (int.tryParse(parts[0]) ?? 0) * 60 +
          (parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0);
    }

    final minutes = local.hour * 60 + local.minute;
    final from = toMin(fromText);
    final to = toMin(toText);
    final closed = from <= to
        ? minutes < from || minutes >= to
        : minutes < from && minutes >= to;
    if (closed) return false;
  }
  return true;
}

/// Frequency caps (`frequency`) for this visitor.
bool frequencyAllows(
  Experience exp,
  SeenRecord h,
  ExperienceState state,
  int nowMs,
) {
  final f = exp.frequency;
  if (f['stop_after_submit'] != false && h.submitted > 0) return false;
  final maxCloses = asNum(f['max_closes']);
  if (maxCloses != null && maxCloses > 0 && h.closes >= maxCloses) {
    return false;
  }
  final cooldownHours = asNum(f['cooldown_hours_after_close']) ?? 24;
  final cooldown = cooldownHours * 3600 * 1000;
  if (h.lastClose > 0 && cooldown > 0 && nowMs - h.lastClose < cooldown) {
    return false;
  }
  const day = 24 * 3600 * 1000;
  switch (asString(f['show'], 'session')) {
    case 'always':
      return true;
    case 'session':
      return h.sessionShown != state.session;
    case 'day':
      return h.last == 0 || nowMs - h.last > day;
    case 'days':
      final days = asNum(f['days']) ?? 7;
      return h.last == 0 || nowMs - h.last > (days == 0 ? 7 : days) * day;
    case 'ever':
      return h.n == 0;
    default:
      return true;
  }
}

/// Sticky variant (or "holdout") for this visitor. Stores it in [h].
String assign(Experience exp, String visitorId, SeenRecord h) {
  final active = exp.variants.map((v) => v.key).toList();
  final prior = h.variant;
  if (prior != null &&
      prior.isNotEmpty &&
      (prior == 'holdout' ? exp.holdoutPct > 0 : active.contains(prior))) {
    return prior;
  }
  final roll = bucket('$visitorId:${exp.id}');
  String chosen;
  if (roll * 100 < exp.holdoutPct) {
    chosen = 'holdout';
  } else {
    final denominator = 100 - exp.holdoutPct;
    final rest =
        (roll * 100 - exp.holdoutPct) / (denominator == 0 ? 1 : denominator);
    var total = 0.0;
    for (final v in exp.variants) {
      total += v.weight < 0 ? 0 : v.weight;
    }
    if (total == 0) total = 1;
    var acc = 0.0;
    chosen = exp.variants.last.key;
    for (final v in exp.variants) {
      acc += (v.weight < 0 ? 0 : v.weight) / total;
      if (rest < acc) {
        chosen = v.key;
        break;
      }
    }
  }
  h.variant = chosen;
  return chosen;
}

// ---------------------------------------------------------------------------
// Text helpers for the renderer.

final RegExp _placeholder =
    RegExp(r'\{\{\s*([a-z_]+)\.([a-z_0-9]+)\s*\}\}', caseSensitive: false);

/// `{{answers.size}}`, `{{offer.code}}`.
String fill(String template, Map<String, Map<String, Object?>> scopes) =>
    template.replaceAllMapped(_placeholder, (m) {
      final v = scopes[m[1]!]?[m[2]!];
      return v == null ? '' : v.toString();
    });

/// Plain text from the block's light markdown: `[label](url)` becomes
/// label, `**` and `*` markers are dropped.
String plainText(String text) => text
    .replaceAllMapped(RegExp(r'\[([^\]]+)\]\(([^)\s]+)\)'), (m) => m[1] ?? '')
    .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m[1] ?? '')
    .replaceAllMapped(RegExp(r'(^|[^*])\*([^*]+)\*(?!\*)'),
        (m) => '${m[1] ?? ''}${m[2] ?? ''}')
    .replaceAll('**', '');

/// ARGB from `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()` or `rgba()`.
int? parseColor(Object? value) {
  if (value == null) return null;
  final s = value.toString().trim().toLowerCase();
  if (s.startsWith('#')) {
    var hex = s.substring(1);
    if (hex.length == 3 || hex.length == 4) {
      hex = hex.split('').map((c) => '$c$c').join();
    }
    if (!RegExp(r'^[0-9a-f]+$').hasMatch(hex)) return null;
    if (hex.length == 6) return 0xff000000 | int.parse(hex, radix: 16);
    if (hex.length == 8) {
      final rgb = int.parse(hex.substring(0, 6), radix: 16);
      final a = int.parse(hex.substring(6), radix: 16);
      return (a << 24) | rgb;
    }
    return null;
  }
  final m = RegExp(r'^rgba?\(([^)]*)\)$').firstMatch(s);
  if (m == null) return null;
  final parts = m[1]!.split(',').map((p) => p.trim()).toList();
  if (parts.length < 3) return null;
  final rgb = parts.take(3).map((p) => int.tryParse(p)).toList();
  if (rgb.any((c) => c == null || c < 0 || c > 255)) return null;
  var alpha = 255;
  if (parts.length > 3) {
    final a = double.tryParse(parts[3]);
    if (a == null) return null;
    alpha = (a.clamp(0, 1) * 255).round();
  }
  return (alpha << 24) | (rgb[0]! << 16) | (rgb[1]! << 8) | rgb[2]!;
}

/// The theme tokens apps use, with `content.style` overrides.
class ExperienceTheme {
  const ExperienceTheme({
    this.primary = 0xff111827,
    this.text = 0xff111827,
    this.background = 0xffffffff,
    this.muted = 0xff6b7280,
    this.buttonText = 0xffffffff,
    this.overlay = 0x8c111827,
    this.radius = 12,
    this.buttonRadius = 8,
  });

  factory ExperienceTheme.resolve(
    Map<String, Object?> theme,
    Map<String, Object?> style,
  ) {
    Object? pick(String key) {
      final v = style[key];
      return v != null && v != '' ? v : theme[key];
    }

    const d = ExperienceTheme();
    final radius = asNum(style['radius'] ?? theme['radius']) ?? 12;
    final buttonRadius = theme['button_style'] == 'pill'
        ? 999
        : asNum(theme['button_radius']) ?? 8;
    return ExperienceTheme(
      primary: parseColor(pick('primary_color')) ?? d.primary,
      text: parseColor(style['text_color'] ?? theme['text_color']) ?? d.text,
      background:
          parseColor(style['background'] ?? theme['background_color']) ??
              d.background,
      muted: parseColor(pick('muted_color')) ?? d.muted,
      buttonText: parseColor(pick('button_text_color')) ?? d.buttonText,
      overlay: parseColor(pick('overlay_color')) ?? d.overlay,
      radius: radius.toDouble(),
      buttonRadius: buttonRadius.toDouble(),
    );
  }

  final int primary;
  final int text;
  final int background;
  final int muted;
  final int buttonText;
  final int overlay;
  final double radius;
  final double buttonRadius;
}
