/// In-app messages: fetches the source's experiences, decides when one
/// shows (screens, events, delays, frequency, holdout, targeting), keeps
/// each visitor's history and drives the message on screen. Pure Dart: the
/// Flutter widget that draws a message is in `src/flutter/experiences.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../core/storage.dart';
import 'rules.dart';
import 'state.dart';

/// What happened to an in-app message.
enum LemuExperienceEventType { shown, closed, submitted, clicked }

/// One in-app message event, from `Lemu.instance.experiences.events`.
class LemuExperienceEvent {
  const LemuExperienceEvent({
    required this.type,
    required this.experience,
    required this.variant,
    this.byUser = false,
    this.target,
    this.fields = const {},
    this.offerCode,
  });

  final LemuExperienceEventType type;

  /// The experience key.
  final String experience;

  /// The variant shown.
  final String variant;

  /// [LemuExperienceEventType.closed]: true when the user closed it.
  final bool byUser;

  /// [LemuExperienceEventType.clicked]: the URL, or `copy_code`.
  final String? target;

  /// [LemuExperienceEventType.submitted]: the values the user entered.
  final Map<String, Object?> fields;

  /// [LemuExperienceEventType.submitted]: the offer code, when there is one.
  final String? offerCode;

  @override
  String toString() => 'LemuExperienceEvent(${type.name}, $experience, '
      '$variant${target == null ? '' : ', $target'})';
}

/// Draws messages. `LemuExperiencesHost` implements it; tests use fakes.
abstract class ExperienceDisplay {
  void showExperience(ExperienceView view);
  void hideExperience(ExperienceView view);
}

/// One step of a message.
class ExperienceStep {
  const ExperienceStep(this.id, this.blocks);

  factory ExperienceStep.fromJson(Object? json) {
    final m = asMap(json);
    return ExperienceStep(
      asString(m['id']),
      asList(m['blocks']).map(asMap).toList(),
    );
  }

  final String id;
  final List<Map<String, Object?>> blocks;

  bool get hasFields => blocks.any((b) => b['type'] == 'field');
}

/// A choice in a select / chips field.
class FieldOption {
  const FieldOption(this.value, this.label);

  final String value;
  final String label;
}

/// The options of a choice field (`options`, or 1..5 for rating, 0..10
/// for nps).
List<FieldOption> fieldOptions(Map<String, Object?> block) {
  final input = asString(block['input']);
  if (input == 'rating') {
    return [for (var i = 1; i <= 5; i++) FieldOption('$i', '$i')];
  }
  if (input == 'nps') {
    return [for (var i = 0; i <= 10; i++) FieldOption('$i', '$i')];
  }
  return asList(block['options']).map((o) {
    if (o is Map) {
      final m = asMap(o);
      final value = asString(m['value']);
      return FieldOption(value, asString(m['label'], value));
    }
    return FieldOption(asString(o), asString(o));
  }).toList();
}

/// Inputs drawn as a single-choice picker.
const Set<String> choiceInputs = {'select', 'size', 'chips', 'rating', 'nps'};

/// Inputs drawn as a checkbox.
const Set<String> checkInputs = {'consent', 'checkbox'};

/// The phone number as sent: `+` and digits when the user typed a leading
/// `+`, otherwise [countryCode] plus the digits without leading zeros.
String normalizePhone(String raw, String countryCode) {
  final t = raw.trim();
  if (t.isEmpty) return '';
  final digits = t.replaceAll(RegExp(r'[^\d]'), '');
  if (t.startsWith('+')) return '+$digits';
  return countryCode + digits.replaceFirst(RegExp(r'^0+'), '');
}

/// The outcome of checking a step's fields.
class StepCheck {
  const StepCheck(this.message, this.invalid);

  /// The error to show, or null when the step is fine.
  final String? message;

  /// Field names to highlight.
  final Set<String> invalid;

  bool get ok => message == null;
}

final RegExp _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]{2,}$');

/// Required fields, email and phone format (same messages as the website).
StepCheck validateStep(
  List<Map<String, Object?>> blocks,
  Map<String, Object?> values,
) {
  final missing = <String>{};
  for (final b in blocks) {
    if (b['type'] != 'field' || b['required'] != true) continue;
    final input = asString(b['input']);
    if (input == 'hidden') continue;
    final name = asString(b['name']);
    final v = values[name];
    final empty = v == null || v == false || (v is String && v.trim().isEmpty);
    if (empty) missing.add(name);
  }
  if (missing.isNotEmpty) {
    return StepCheck('Please fill in the highlighted fields.', missing);
  }
  for (final b in blocks) {
    if (b['type'] != 'field') continue;
    final name = asString(b['name']);
    final v = values[name];
    if (v is! String || v.trim().isEmpty) continue;
    final input = asString(b['input']);
    if (input == 'email' && !_email.hasMatch(v.trim())) {
      return StepCheck('Enter a valid email address.', {name});
    }
    if (input == 'phone' && v.replaceAll(RegExp(r'[^\d]'), '').length < 6) {
      return StepCheck('Enter a valid phone number.', {name});
    }
  }
  return const StepCheck(null, {});
}

/// A message on screen: its steps, answers, errors and offer. The widget
/// listens to it and calls its actions.
class ExperienceView {
  ExperienceView._(this._engine, this.experience, this.variant, this.theme);

  final ExperienceEngine _engine;
  final Experience experience;
  final ExperienceVariant variant;
  final ExperienceTheme theme;

  int stepIndex = 0;
  final Map<String, Object?> answers = {};
  Map<String, Object?>? offer;
  bool busy = false;
  String? error;
  Set<String> invalid = {};
  bool otpPending = false;
  bool closed = false;
  Timer? _timer;
  final List<void Function()> _listeners = [];

  String get format => experience.format;
  Map<String, Object?> get content => variant.content;
  Map<String, Object?> get layout => asMap(content['layout']);

  List<ExperienceStep> get steps =>
      asList(content['steps']).map(ExperienceStep.fromJson).toList();

  ExperienceStep? get step {
    final s = steps;
    return stepIndex < s.length ? s[stepIndex] : null;
  }

  bool get showCloseButton => layout['close_button'] != false;

  /// Popups dim the app behind them unless `layout.overlay` is false.
  bool get dimsBackground => format == 'popup' && layout['overlay'] != false;

  bool get closeOnOverlay => layout['close_on_overlay'] != false;

  void addListener(void Function() fn) => _listeners.add(fn);
  void removeListener(void Function() fn) => _listeners.remove(fn);

  void _changed() {
    for (final fn in List.of(_listeners)) {
      try {
        fn();
      } catch (_) {}
    }
  }

  /// Text with `{{answers.x}}` / `{{offer.code}}` filled and markdown
  /// markers removed.
  String text(Object? template) => plainText(fill(asString(template), {
        'answers': answers,
        'offer': offer ?? const {},
      }));

  void _start() {
    if (format != 'toast') return;
    final secs = asNum(layout['auto_hide_seconds']) ?? 8;
    if (secs > 0) {
      _timer = Timer(Duration(milliseconds: (secs * 1000).round()),
          () => close(byUser: false));
    }
  }

  /// Closes the message. [byUser] counts as a close for frequency caps and
  /// sends `onsite_closed`.
  void close({bool byUser = true}) {
    if (closed) return;
    closed = true;
    _timer?.cancel();
    _engine._viewClosed(this, byUser);
  }

  Map<String, Object?> _collect(Map<String, Object?> values) {
    final out = <String, Object?>{};
    for (final b in step?.blocks ?? const <Map<String, Object?>>[]) {
      if (b['type'] != 'field') continue;
      final name = asString(b['name']);
      if (name.isEmpty) continue;
      final input = asString(b['input']);
      if (input == 'hidden') {
        out[name] = b['value'];
      } else if (input == 'phone') {
        out[name] = normalizePhone(
          asString(values[name]),
          asString(b['default_country'], '+91'),
        );
      } else if (checkInputs.contains(input)) {
        out[name] = values[name] == true;
      } else if (values.containsKey(name)) {
        out[name] = values[name];
      }
    }
    return out;
  }

  bool _check(Map<String, Object?> values) {
    final result = validateStep(step?.blocks ?? const [], values);
    error = result.message;
    invalid = result.invalid;
    if (!result.ok) _changed();
    return result.ok;
  }

  /// `next_step`: checks this step, keeps its answers, goes on.
  void next(Map<String, Object?> values) {
    if (closed || !_check(values)) return;
    answers.addAll(_collect(values));
    if (stepIndex < steps.length - 1) stepIndex++;
    _changed();
  }

  /// Sends the form. With [otp], sends the answers again with the code.
  Future<void> submit(Map<String, Object?> values, {String? otp}) async {
    if (closed || busy) return;
    if (!otpPending) {
      if (!_check(values)) return;
      answers.addAll(_collect(values));
    }
    busy = true;
    error = null;
    invalid = {};
    _changed();
    var phoneCountry = '+91';
    for (final s in steps) {
      for (final b in s.blocks) {
        if (b['type'] == 'field' && b['input'] == 'phone') {
          phoneCountry = asString(b['default_country'], '+91');
        }
      }
    }
    final result = await _engine._submit(
      this,
      Map.of(answers),
      phoneCountry: phoneCountry,
      otp: otpPending ? (otp ?? '') : null,
    );
    busy = false;
    if (closed) return;
    final status = result.status;
    final data = result.data;
    if (status == null) {
      error = "Couldn't send. Check your connection and try again.";
      _changed();
      return;
    }
    final errors = asMap(data['errors']);
    if (data['verify'] == true) {
      otpPending = true;
      final otpError = errors['_otp'];
      error = otpError == null ? null : asString(otpError);
      _changed();
      return;
    }
    if (data['ok'] != true) {
      final first = errors['_form'] ??
          (errors.values.isNotEmpty ? errors.values.first : null);
      error = first != null
          ? asString(first)
          : status == 429
              ? 'Please try again in a minute.'
              : 'Something went wrong. Please try again.';
      _changed();
      return;
    }
    otpPending = false;
    final o = data['offer'];
    offer = o is Map ? asMap(o) : null;
    _engine._viewSubmitted(this, Map.of(answers), offer?['code']?.toString());
    final all = steps;
    var success = -1;
    for (var i = stepIndex + 1; i < all.length; i++) {
      if (all[i].id == 'success' || !all[i].hasFields) {
        success = i;
        break;
      }
    }
    if (success > 0) {
      stepIndex = success;
      _changed();
    } else {
      close(byUser: false);
    }
  }

  /// A `url` button: records the click, opens the link (through the app's
  /// handler) and closes the message.
  void openUrl(String url) {
    if (closed) return;
    _engine._viewClicked(this, url);
    _engine._openUrl(url);
    close(byUser: false);
  }

  /// The offer code was copied.
  void copied() {
    if (closed) return;
    _engine._viewClicked(this, 'copy_code');
  }
}

class _Reply {
  const _Reply(this.status, this.data);

  final int? status;
  final Map<String, Object?> data;
}

/// The in-app message engine for one write key.
class ExperienceEngine {
  ExperienceEngine({
    required this.writeKey,
    required String apiHost,
    required http.Client client,
    required LemuStorage storage,
    required void Function(String event, Map<String, Object?> properties) track,
    required String? Function() anonymousId,
    required String? Function() userId,
    required bool Function() canStore,
    required bool Function() optedOut,
    required ExperienceDisplay? Function() display,
    required void Function(LemuExperienceEvent event) emit,
    this.platform = 'android',
    String? Function()? userAgent,
    DateTime Function()? clock,
    Random? random,
    void Function(String message)? log,
    this.timeout = const Duration(seconds: 15),
  })  : _host = _trim(apiHost),
        _client = client,
        _storage = storage,
        _track = track,
        _anonymousId = anonymousId,
        _userId = userId,
        _canStore = canStore,
        _optedOut = optedOut,
        _display = display,
        _emit = emit,
        _userAgent = userAgent,
        _clock = clock ?? DateTime.now,
        _random = random ?? Random(),
        _log = log ?? ((_) {});

  static const Duration refreshEvery = Duration(minutes: 5);
  static const Duration decideTtl = Duration(minutes: 10);

  final String writeKey;
  final String platform;
  final Duration timeout;
  final String _host;
  final http.Client _client;
  final LemuStorage _storage;
  final void Function(String, Map<String, Object?>) _track;
  final String? Function() _anonymousId;
  final String? Function() _userId;
  final bool Function() _canStore;
  final bool Function() _optedOut;
  final ExperienceDisplay? Function() _display;
  final void Function(LemuExperienceEvent) _emit;
  final String? Function()? _userAgent;
  final DateTime Function() _clock;
  final Random _random;
  final void Function(String) _log;

  /// Opens links from `url` buttons. Set by the app.
  void Function(Uri uri)? urlHandler;

  ExperienceState state = ExperienceState();
  ExperienceBundle? _bundle;
  DateTime? _fetchedAt;
  Future<void>? _fetching;
  bool _enabled = true;
  bool _closed = false;
  bool _evaluatedOnLoad = false;
  String _screen = '';
  String? _sku;
  int _popupsThisScreen = 0;
  String? _pendingShow;
  ExperienceView? _current;
  final List<Timer> _delays = [];
  final Map<String, (DateTime, Decision)> _decisions = {};

  static String _trim(String host) {
    var h = host.trim();
    while (h.endsWith('/')) {
      h = h.substring(0, h.length - 1);
    }
    return h;
  }

  /// The loaded bundle, or null before the first successful fetch.
  ExperienceBundle? get bundle => _bundle;

  /// The message on screen, if any.
  ExperienceView? get current => _current;

  String get screen => _screen;

  bool get isEnabled => _enabled;

  void setEnabled(bool on) => _enabled = on;

  int get _nowMs => _clock().millisecondsSinceEpoch;

  String get _visitorId {
    final id = _anonymousId();
    return id != null && id.isNotEmpty ? id : state.session;
  }

  /// Loads the stored history, starts a session and fetches the bundle.
  Future<void> start() async {
    try {
      if (_canStore()) {
        state =
            ExperienceState.decode(await _storage.read(experiencesStorageKey));
      }
    } catch (e) {
      _log('experiences: reading history failed: $e');
    }
    state.touch(_nowMs, _random);
    await _persist();
    await refresh();
  }

  /// Stops timers and closes the message on screen.
  void close() {
    _closed = true;
    _cancelDelays();
    final c = _current;
    if (c != null) {
      c.closed = true;
      c._timer?.cancel();
      _current = null;
      _display()?.hideExperience(c);
    }
  }

  Future<void> _persist() async {
    if (!_canStore()) return;
    try {
      await _storage.write(experiencesStorageKey, state.encode());
    } catch (e) {
      _log('experiences: saving history failed: $e');
    }
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json; charset=utf-8',
        if (_userAgent?.call() != null) 'User-Agent': _userAgent!.call()!,
      };

  /// Fetches the config now.
  Future<void> refresh() {
    if (_closed) return Future<void>.value();
    return _fetching ??= _fetch().whenComplete(() => _fetching = null);
  }

  Future<void> _fetch() async {
    try {
      final uri = Uri.parse('$_host/api/v1/pixel/onsite/config')
          .replace(queryParameters: {'k': writeKey});
      final response =
          await _client.get(uri, headers: _headers).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _log('experiences: config answered ${response.statusCode}');
        return;
      }
      final bundle = ExperienceBundle.fromJson(jsonDecode(response.body));
      if (_closed) return;
      _bundle = bundle;
      _fetchedAt = _clock();
      _log('experiences: ${bundle.experiences.length} live');
      if (bundle.experiences.isNotEmpty && !_evaluatedOnLoad) {
        _evaluatedOnLoad = true;
        _automatic();
      }
      final pending = _pendingShow;
      _pendingShow = null;
      if (pending != null) show(pending);
    } catch (e) {
      _log('experiences: config failed: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Inputs from the SDK.

  void onScreen(String name) {
    if (_closed) return;
    _screen = name.trim();
    _sku = null;
    _popupsThisScreen = 0;
    _cancelDelays();
    _automatic();
  }

  void onTrack(String event, Map<String, Object?>? properties) {
    if (_closed || event.startsWith('onsite_')) return;
    if (sameEvent('ViewContent', event) && properties != null) {
      final ids = properties['content_ids'];
      final sku = ids is List && ids.isNotEmpty
          ? ids.first
          : properties['sku'] ?? properties['content_id'];
      if (sku != null && sku.toString().isNotEmpty) _sku = sku.toString();
    }
    _automatic(event: event);
  }

  void onForeground() {
    if (_closed) return;
    state.touch(_nowMs, _random);
    unawaited(_persist());
    final at = _fetchedAt;
    if (at == null || _clock().difference(at) >= refreshEvery) {
      unawaited(refresh());
    }
  }

  void onBackground() {
    if (_closed) return;
    state.last = _nowMs;
    unawaited(_persist());
  }

  // -------------------------------------------------------------------------
  // Showing.

  /// Shows [key] now (manual trigger). See `LemuExperiences.show`.
  bool show(String key) {
    if (_closed || _optedOut()) return false;
    final b = _bundle;
    if (b == null) {
      _pendingShow = key;
      return false;
    }
    final exp = b.find(key);
    if (exp == null || _current != null || _display() == null) return false;
    final h = state.seenFor(exp.key);
    final chosen = assign(exp, _visitorId, h);
    unawaited(_persist());
    if (chosen == 'holdout') {
      _heldOut(exp);
      return false;
    }
    final variant = exp.variant(chosen);
    if (variant == null || variant.kind != 'blocks') return false;
    return _present(exp, variant);
  }

  void hide() => _current?.close(byUser: false);

  void _cancelDelays() {
    for (final t in _delays) {
      t.cancel();
    }
    _delays.clear();
  }

  void _automatic({String? event}) {
    final b = _bundle;
    if (b == null || !_enabled || _optedOut()) return;
    final candidates = <Experience>[];
    for (final exp in b.experiences) {
      final on = exp.triggerOn;
      if (event == null) {
        if (on == 'page_load') candidates.add(exp);
        if (on == 'delay') {
          final secs = asNum(exp.trigger['seconds']) ?? 0;
          _delays.add(Timer(
            Duration(milliseconds: (secs * 1000).round()),
            () => unawaited(_tryShow([exp])),
          ));
        }
      } else if ((on == 'event' || on == 'add_to_cart') &&
          sameEvent(exp.triggerEvent, event)) {
        candidates.add(exp);
      }
    }
    if (candidates.isNotEmpty) unawaited(_tryShow(candidates));
  }

  bool _capsAllow(Experience exp) {
    if (!overlayFormats.contains(exp.format)) return true;
    final caps = _bundle?.caps ?? const {};
    final perPage = asNum(caps['popups_per_page']);
    final perSession = asNum(caps['popups_per_session']);
    if (perPage != null && _popupsThisScreen >= perPage) return false;
    if (perSession != null && state.popupsThisSession >= perSession) {
      return false;
    }
    return true;
  }

  bool _preCheck(Experience exp) {
    if (_closed || !_enabled || _optedOut()) return false;
    if (_current != null || _display() == null) return false;
    if (!scheduleOpen(exp.schedule, _clock())) return false;
    if (!whereMatches(exp, _screen)) return false;
    if (!frequencyAllows(exp, state.seenFor(exp.key), state, _nowMs)) {
      return false;
    }
    return _capsAllow(exp);
  }

  /// The first of [list] that may show, shows. Returns true if one did.
  Future<bool> _tryShow(List<Experience> list) async {
    for (final exp in list) {
      try {
        if (!_preCheck(exp)) continue;
        Decision? decision;
        if (exp.whoServer) {
          decision = await _decide();
          if (!_preCheck(exp)) continue;
        }
        if (!whoMatches(exp, decision, _userId(), state.visits)) continue;
        final chosen = assign(exp, _visitorId, state.seenFor(exp.key));
        await _persist();
        if (chosen == 'holdout') {
          _heldOut(exp);
          continue;
        }
        final variant = exp.variant(chosen);
        if (variant == null || variant.kind != 'blocks') continue;
        if (_present(exp, variant)) return true;
      } catch (e) {
        _log('experiences: ${exp.key} failed: $e');
      }
    }
    return false;
  }

  Map<String, Object?> _props(Experience exp, String variant) => {
        'experience_id': exp.id,
        'experience': exp.key,
        'variant': variant,
        'version': exp.version,
        'format': exp.format,
        'screen': _screen,
      };

  void _heldOut(Experience exp) {
    final h = state.seenFor(exp.key);
    if (h.sessionShown == state.session) return;
    h.sessionShown = state.session;
    unawaited(_persist());
    _track('onsite_held_out', _props(exp, 'holdout'));
  }

  bool _present(Experience exp, ExperienceVariant variant) {
    final display = _display();
    if (display == null || _current != null) return false;
    final b = _bundle;
    final view = ExperienceView._(
      this,
      exp,
      variant,
      ExperienceTheme.resolve(
          b?.theme ?? const {}, asMap(variant.content['style'])),
    );
    if (view.steps.isEmpty) return false;
    _current = view;
    final now = _nowMs;
    final h = state.seenFor(exp.key);
    h.n += 1;
    h.last = now;
    h.sessionShown = state.session;
    if (overlayFormats.contains(exp.format)) {
      state.popupsThisSession += 1;
      _popupsThisScreen += 1;
    }
    state.last = now;
    unawaited(_persist());
    _track('onsite_viewed', _props(exp, variant.key));
    _emit(LemuExperienceEvent(
      type: LemuExperienceEventType.shown,
      experience: exp.key,
      variant: variant.key,
    ));
    display.showExperience(view);
    view._start();
    return true;
  }

  // -------------------------------------------------------------------------
  // From the view.

  void _viewClosed(ExperienceView view, bool byUser) {
    if (byUser) {
      final h = state.seenFor(view.experience.key);
      h.closes += 1;
      h.lastClose = _nowMs;
      unawaited(_persist());
      _track('onsite_closed', _props(view.experience, view.variant.key));
    }
    if (identical(_current, view)) _current = null;
    _display()?.hideExperience(view);
    _emit(LemuExperienceEvent(
      type: LemuExperienceEventType.closed,
      experience: view.experience.key,
      variant: view.variant.key,
      byUser: byUser,
    ));
  }

  void _viewSubmitted(
    ExperienceView view,
    Map<String, Object?> fields,
    String? offerCode,
  ) {
    state.seenFor(view.experience.key).submitted = _nowMs;
    unawaited(_persist());
    _emit(LemuExperienceEvent(
      type: LemuExperienceEventType.submitted,
      experience: view.experience.key,
      variant: view.variant.key,
      fields: fields,
      offerCode: offerCode,
    ));
  }

  void _viewClicked(ExperienceView view, String target) {
    _track('onsite_clicked', {
      ..._props(view.experience, view.variant.key),
      'target': target,
    });
    _emit(LemuExperienceEvent(
      type: LemuExperienceEventType.clicked,
      experience: view.experience.key,
      variant: view.variant.key,
      target: target,
    ));
  }

  void _openUrl(String url) {
    final uri = Uri.tryParse(url);
    final handler = urlHandler;
    if (uri == null || handler == null) return;
    try {
      handler(uri);
    } catch (e) {
      _log('experiences: opening $url failed: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Network.

  Future<_Reply> _post(String path, Map<String, Object?> body) async {
    try {
      final response = await _client
          .post(Uri.parse('$_host$path'),
              headers: _headers, body: jsonEncode(body))
          .timeout(timeout);
      Map<String, Object?> data = const {};
      try {
        data = asMap(jsonDecode(response.body));
      } catch (_) {}
      return _Reply(response.statusCode, data);
    } catch (e) {
      _log('experiences: $path failed: $e');
      return const _Reply(null, {});
    }
  }

  Future<Decision?> _decide() async {
    final key = '$_screen|${_sku ?? ''}';
    final cached = _decisions[key];
    if (cached != null && _clock().difference(cached.$1) < decideTtl) {
      return cached.$2;
    }
    final reply = await _post('/api/v1/pixel/onsite/decide', {
      'writeKey': writeKey,
      'anonymousId': _anonymousId(),
      'userId': _userId(),
      'context': {
        'screen': _screen,
        'product': _sku == null ? <String, Object?>{} : {'sku': _sku},
      },
    });
    if (reply.status == null || reply.status! >= 300) return null;
    if (reply.data['experiences'] is! Map) return null;
    final decision = Decision.fromJson(reply.data);
    _decisions[key] = (_clock(), decision);
    return decision;
  }

  Future<_Reply> _submit(
    ExperienceView view,
    Map<String, Object?> fields, {
    required String phoneCountry,
    String? otp,
  }) =>
      _post('/api/v1/pixel/onsite/submit', {
        'writeKey': writeKey,
        'experience': view.experience.key,
        'variant': view.variant.key,
        'anonymousId': _anonymousId(),
        'userId': _userId(),
        'fields': fields,
        'context': {
          'screen': _screen,
          'platform': platform,
          'phone_country': phoneCountry,
        },
        if (otp != null) 'otp': otp,
      });
}
