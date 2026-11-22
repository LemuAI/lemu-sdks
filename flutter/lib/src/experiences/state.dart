/// What the app remembers per visitor for in-app messages: visits, the
/// current session and each experience's history. Same shape as the
/// website's `_lemu_os` value. Pure Dart.
library;

import 'dart:convert';
import 'dart:math';

/// Storage key for [ExperienceState].
const String experiencesStorageKey = 'lemu.experiences';

/// A new session starts after this long without activity.
const Duration sessionGap = Duration(minutes: 30);

int _int(Object? v) => v is num ? v.toInt() : 0;

/// One experience's history.
class SeenRecord {
  SeenRecord({
    this.n = 0,
    this.last = 0,
    this.closes = 0,
    this.lastClose = 0,
    this.submitted = 0,
    this.variant,
    this.sessionShown,
  });

  factory SeenRecord.fromJson(Object? json) {
    final m = json is Map ? json : const <String, Object?>{};
    return SeenRecord(
      n: _int(m['n']),
      last: _int(m['last']),
      closes: _int(m['closes']),
      lastClose: _int(m['lastClose']),
      submitted: _int(m['submitted']),
      variant: m['variant'] is String ? m['variant'] as String : null,
      sessionShown:
          m['sessionShown'] is String ? m['sessionShown'] as String : null,
    );
  }

  /// Times shown.
  int n;

  /// When it last showed (epoch ms).
  int last;
  int closes;
  int lastClose;

  /// When the form was last submitted (epoch ms), 0 if never.
  int submitted;
  String? variant;
  String? sessionShown;

  Map<String, Object?> toJson() => {
        'n': n,
        'last': last,
        'closes': closes,
        'lastClose': lastClose,
        'submitted': submitted,
        if (variant != null) 'variant': variant,
        if (sessionShown != null) 'sessionShown': sessionShown,
      };
}

/// Visits, session and per-experience history.
class ExperienceState {
  ExperienceState({
    this.visits = 0,
    this.first = 0,
    this.last = 0,
    this.session = '',
    this.sessionStart = 0,
    this.popupsThisSession = 0,
    Map<String, SeenRecord>? seen,
  }) : seen = seen ?? {};

  /// Reads the stored JSON; anything unreadable gives a fresh state.
  factory ExperienceState.decode(String? raw) {
    if (raw == null || raw.isEmpty) return ExperienceState();
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return ExperienceState();
      final seen = <String, SeenRecord>{};
      final s = m['seen'];
      if (s is Map) {
        s.forEach((k, v) => seen[k.toString()] = SeenRecord.fromJson(v));
      }
      return ExperienceState(
        visits: _int(m['visits']),
        first: _int(m['first']),
        last: _int(m['last']),
        session: m['session'] is String ? m['session'] as String : '',
        sessionStart: _int(m['sessionStart']),
        popupsThisSession: _int(m['popupsThisSession']),
        seen: seen,
      );
    } catch (_) {
      return ExperienceState();
    }
  }

  int visits;
  int first;
  int last;
  String session;
  int sessionStart;
  int popupsThisSession;
  final Map<String, SeenRecord> seen;

  /// The experience's history, created on first use.
  SeenRecord seenFor(String key) => seen.putIfAbsent(key, SeenRecord.new);

  /// Starts a new session when there is none or the last activity was more
  /// than [sessionGap] ago, then marks activity now. Returns true for a new
  /// session.
  bool touch(int nowMs, Random random) {
    final fresh = session.isEmpty || nowMs - last > sessionGap.inMilliseconds;
    if (fresh) {
      visits += 1;
      session = _sessionId(random);
      sessionStart = nowMs;
      popupsThisSession = 0;
    }
    if (first == 0) first = nowMs;
    last = nowMs;
    return fresh;
  }

  static String _sessionId(Random random) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(8, (_) => chars[random.nextInt(chars.length)]).join();
  }

  String encode() => jsonEncode({
        'visits': visits,
        'first': first,
        'last': last,
        'session': session,
        'sessionStart': sessionStart,
        'popupsThisSession': popupsThisSession,
        'seen': {for (final e in seen.entries) e.key: e.value.toJson()},
      });
}
