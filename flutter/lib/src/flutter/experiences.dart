import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../experiences/engine.dart';
import '../experiences/rules.dart';
import 'lemu.dart';

/// In-app messages: experiences built in Lemu with the app (or any)
/// platform. Reach it through `Lemu.instance.experiences`.
///
/// Messages show inside a [LemuExperiencesHost]; mount one around your app.
class LemuExperiences {
  /// Used by [Lemu]. Apps use `Lemu.instance.experiences`.
  LemuExperiences.internal();

  ExperienceEngine? _engine;
  ExperienceDisplay? _display;
  bool _enabled = true;
  void Function(Uri uri)? _urlHandler;
  final StreamController<LemuExperienceEvent> _events =
      StreamController<LemuExperienceEvent>.broadcast();

  /// Shown, closed, submitted and clicked events for every message.
  Stream<LemuExperienceEvent> get events => _events.stream;

  /// Opens links from buttons with the "Open a link" action, for example
  /// with url_launcher: `(uri) => launchUrl(uri)`. Without one, those
  /// buttons record the click and close the message.
  void Function(Uri uri)? get urlHandler => _urlHandler;
  set urlHandler(void Function(Uri uri)? handler) {
    _urlHandler = handler;
    _engine?.urlHandler = handler;
  }

  /// Shows the experience [key] now, whatever its trigger, pages,
  /// targeting and frequency say (it still respects the A/B holdout).
  /// Returns false when nothing could show: unknown key, not loaded yet
  /// (it shows once loaded), the visitor is in the holdout, a message is
  /// already on screen, or no [LemuExperiencesHost] is mounted.
  bool show(String key) {
    try {
      return _engine?.show(key) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Closes the message on screen, if any.
  void hide() {
    try {
      _engine?.hide();
    } catch (_) {}
  }

  /// False pauses automatic messages (screen, delay and event triggers),
  /// for example during checkout. [show] still works.
  void setEnabled(bool enabled) {
    _enabled = enabled;
    _engine?.setEnabled(enabled);
  }

  bool get isEnabled => _enabled;

  /// Fetches the live experiences now. The SDK also fetches them at start
  /// and when the app comes back to the foreground (at most every 5 minutes).
  Future<void> refresh() =>
      _engine?.refresh().catchError((Object _) {}) ?? Future<void>.value();

  /// The engine, for tests.
  @visibleForTesting
  ExperienceEngine? get engine => _engine;
}

/// Connects [experiences] to [engine] (or disconnects with null). Used by
/// [Lemu] and tests.
void attachExperienceEngine(
  LemuExperiences experiences,
  ExperienceEngine? engine,
) {
  experiences._engine = engine;
  if (engine != null) {
    engine.urlHandler = experiences._urlHandler;
    engine.setEnabled(experiences._enabled);
  }
}

/// The display callback an engine uses for [experiences].
ExperienceDisplay? experienceDisplayOf(LemuExperiences experiences) =>
    experiences._display;

/// Sends [event] to the `events` stream of [experiences].
void emitExperienceEvent(
  LemuExperiences experiences,
  LemuExperienceEvent event,
) {
  if (!experiences._events.isClosed) experiences._events.add(event);
}

/// Shows Lemu in-app messages over your app. Mount it once around the app:
///
/// ```dart
/// MaterialApp(
///   builder: (context, child) => LemuExperiencesHost(child: child!),
///   navigatorObservers: [LemuNavigatorObserver()],
/// );
/// ```
class LemuExperiencesHost extends StatefulWidget {
  const LemuExperiencesHost({super.key, required this.child, this.experiences});

  final Widget child;

  /// Defaults to `Lemu.instance.experiences`.
  final LemuExperiences? experiences;

  @override
  State<LemuExperiencesHost> createState() => _LemuExperiencesHostState();
}

class _LemuExperiencesHostState extends State<LemuExperiencesHost>
    with WidgetsBindingObserver
    implements ExperienceDisplay {
  ExperienceView? _view;

  LemuExperiences get _experiences =>
      widget.experiences ?? Lemu.instance.experiences;

  @override
  void initState() {
    super.initState();
    _experiences._display = this;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(LemuExperiencesHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.experiences ?? Lemu.instance.experiences;
    if (!identical(old, _experiences)) {
      if (identical(old._display, this)) old._display = null;
      _experiences._display = this;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (identical(_experiences._display, this)) _experiences._display = null;
    super.dispose();
  }

  @override
  void showExperience(ExperienceView view) {
    if (mounted) setState(() => _view = view);
  }

  @override
  void hideExperience(ExperienceView view) {
    if (mounted && identical(_view, view)) setState(() => _view = null);
  }

  /// Android back button closes the message.
  @override
  Future<bool> didPopRoute() async {
    final view = _view;
    if (view == null || view.closed) return false;
    view.close();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final view = _view;
    return Stack(
      textDirection: TextDirection.ltr,
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (view != null)
          Positioned.fill(
            child: _MessageLayer(key: ObjectKey(view), view: view),
          ),
      ],
    );
  }
}

Color _c(int argb) => Color(argb);

class _MessageLayer extends StatefulWidget {
  const _MessageLayer({super.key, required this.view});

  final ExperienceView view;

  @override
  State<_MessageLayer> createState() => _MessageLayerState();
}

class _MessageLayerState extends State<_MessageLayer> {
  final Map<String, TextEditingController> _text = {};
  final Map<String, FocusNode> _focus = {};
  final Map<String, bool> _checks = {};
  final Map<String, String?> _choices = {};
  final TextEditingController _otp = TextEditingController();
  final FocusNode _otpFocus = FocusNode();
  int _builtStep = -1;
  bool _copied = false;

  ExperienceView get view => widget.view;
  ExperienceTheme get theme => view.theme;

  @override
  void initState() {
    super.initState();
    view.addListener(_changed);
  }

  @override
  void dispose() {
    view.removeListener(_changed);
    for (final c in _text.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    _otp.dispose();
    _otpFocus.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Fresh inputs for each step, prefilled from earlier answers.
  void _prepareStep() {
    if (_builtStep == view.stepIndex) return;
    _builtStep = view.stepIndex;
    _text.clear();
    _checks.clear();
    _choices.clear();
    for (final b in view.step?.blocks ?? const <Map<String, Object?>>[]) {
      if (b['type'] != 'field') continue;
      final name = asString(b['name']);
      final input = asString(b['input']);
      final prior = view.answers[name];
      if (checkInputs.contains(input)) {
        _checks[name] = prior is bool ? prior : b['checked'] == true;
      } else if (choiceInputs.contains(input)) {
        _choices[name] = prior?.toString();
      } else if (input != 'hidden') {
        _text[name] = TextEditingController(
            text: prior is String && input != 'phone' ? prior : '');
        _focus.putIfAbsent(name, FocusNode.new);
      }
    }
  }

  Map<String, Object?> _values() => {
        for (final e in _text.entries) e.key: e.value.text,
        ..._checks,
        for (final e in _choices.entries) e.key: e.value,
      };

  TextStyle get _base => TextStyle(
        color: _c(theme.text),
        fontSize: 15,
        height: 1.4,
        decoration: TextDecoration.none,
        fontWeight: FontWeight.w400,
      );

  // -------------------------------------------------------------------------
  // Frame.

  @override
  Widget build(BuildContext context) {
    _prepareStep();
    final media = MediaQuery.maybeOf(context);
    final size = media?.size ?? const Size(400, 800);
    final padding = media?.padding ?? EdgeInsets.zero;
    final inset = media?.viewInsets.bottom ?? 0;
    final format = view.format;
    final card = _card(maxHeight: size.height * 0.85 - inset);
    Widget layer;
    if (format == 'popup') {
      layer = Stack(children: [
        if (view.dimsBackground)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: view.closeOnOverlay ? () => view.close() : null,
              child: ColoredBox(color: _c(theme.overlay)),
            ),
          ),
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                16, padding.top + 16, 16, padding.bottom + 16 + inset),
            child: Center(child: card),
          ),
        ),
      ]);
      if (!view.dimsBackground) {
        layer = Center(
          child: Padding(
            padding: EdgeInsets.only(bottom: inset),
            child: card,
          ),
        );
      }
    } else if (format == 'bar') {
      layer = Align(alignment: Alignment.topCenter, child: card);
    } else {
      layer = Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, padding.bottom + 16 + inset),
          child: card,
        ),
      );
    }
    return DefaultTextStyle(
      style: _base,
      child: Directionality(
        textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
        child: layer,
      ),
    );
  }

  Widget _card({required double maxHeight}) {
    final isBar = view.format == 'bar';
    final top = isBar ? (MediaQuery.maybeOf(context)?.padding.top ?? 0) : 0.0;
    final body = Padding(
      padding: EdgeInsets.fromLTRB(
        isBar ? 16 : 20,
        (isBar ? 10 : 20) + top,
        view.showCloseButton ? 44 : (isBar ? 16 : 20),
        isBar ? 10 : 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _blocks(),
      ),
    );
    final maxWidth = view.format == 'toast'
        ? 420.0
        : isBar
            ? double.infinity
            : 520.0;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      scopesRoute: view.format == 'popup',
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: maxHeight < 120 ? 120 : maxHeight,
        ),
        child: Container(
          width: isBar ? double.infinity : null,
          decoration: BoxDecoration(
            color: _c(theme.background),
            borderRadius: isBar ? null : BorderRadius.circular(theme.radius),
            boxShadow: const [
              BoxShadow(
                color: Color(0x24000000),
                blurRadius: 30,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Stack(children: [
            SingleChildScrollView(child: body),
            if (view.showCloseButton)
              Positioned(
                top: top + (isBar ? 2 : 6),
                right: 6,
                child: Semantics(
                  button: true,
                  label: 'Close',
                  excludeSemantics: true,
                  child: GestureDetector(
                    key: const ValueKey('lemu-close'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => view.close(),
                    child: SizedBox(
                      width: 36,
                      height: 36,
                      child: Center(
                        child: Text(
                          '×',
                          style: _base.copyWith(
                            fontSize: 24,
                            height: 1,
                            color: _c(theme.muted),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Blocks.

  List<Widget> _blocks() {
    final step = view.step;
    if (step == null) return const [];
    final out = <Widget>[];
    var otpShown = false;
    for (final b in step.blocks) {
      final type = asString(b['type']);
      if (view.otpPending && type == 'field') continue;
      if (view.otpPending &&
          !otpShown &&
          type == 'button' &&
          _isSubmit(asString(b['action'], 'submit'))) {
        otpShown = true;
        out.add(_otpField());
      }
      final w = _block(b);
      if (w != null) {
        if (out.isNotEmpty) out.add(const SizedBox(height: 12));
        out.add(w);
      }
    }
    if (view.otpPending && !otpShown) out.add(_otpField());
    final error = view.error;
    if (error != null && error.isNotEmpty) {
      out.add(const SizedBox(height: 10));
      out.add(Semantics(
        liveRegion: true,
        child: Text(
          error,
          style: _base.copyWith(color: const Color(0xffdc2626), fontSize: 13),
        ),
      ));
    }
    return out;
  }

  bool _isSubmit(String action) => action == 'submit' || action == 'call_me';

  TextAlign? _align(Map<String, Object?> b) => switch (b['align']) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        'left' => TextAlign.left,
        _ => null,
      };

  Widget? _block(Map<String, Object?> b) {
    switch (asString(b['type'])) {
      case 'heading':
        final level = (asNum(b['level']) ?? 2).clamp(1, 3).toInt();
        return Semantics(
          header: true,
          child: Text(
            view.text(b['text']),
            textAlign: _align(b),
            style: _base.copyWith(
              fontSize: const {1: 24.0, 2: 20.0, 3: 17.0}[level],
              fontWeight: FontWeight.w700,
              height: 1.25,
            ),
          ),
        );
      case 'text':
        return Text(
          view.text(b['text']),
          textAlign: _align(b),
          style: b['muted'] == true
              ? _base.copyWith(color: _c(theme.muted))
              : null,
        );
      case 'image':
        final url = asString(b['url']);
        if (url.isEmpty) return null;
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(theme.radius / 2),
            child: Image.network(
              url,
              fit: BoxFit.contain,
              semanticLabel: asString(b['alt']),
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
        );
      case 'button':
        return _button(b);
      case 'close':
        return _plainButton(
            asString(b['text'], 'No thanks'), () => view.close());
      case 'field':
        return _field(b);
      case 'offer':
        return _offer(b);
      default:
        return null;
    }
  }

  Widget? _button(Map<String, Object?> b) {
    final action = asString(b['action'], 'submit');
    final label = view.text(b['text'] ?? 'Continue');
    VoidCallback? onTap;
    switch (action) {
      case 'submit':
      case 'call_me':
        onTap = () => view.submit(_values(), otp: _otp.text);
      case 'next_step':
        onTap = () => view.next(_values());
      case 'close':
        onTap = () => view.close();
      case 'url':
        final url = asString(b['url']);
        onTap = () => view.openUrl(url);
      case 'copy_code':
        onTap = _copy;
      default:
        return null;
    }
    final secondary = b['variant'] == 'secondary' || action == 'close';
    final busy = view.busy && _isSubmit(action);
    return Semantics(
      button: true,
      enabled: !busy,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: busy ? null : onTap,
        child: Opacity(
          opacity: busy ? 0.6 : 1,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: secondary ? null : _c(theme.primary),
              borderRadius: BorderRadius.circular(theme.buttonRadius),
              border: secondary ? Border.all(color: _c(theme.primary)) : null,
            ),
            alignment: Alignment.center,
            child: Text(
              busy ? 'Sending...' : label,
              textAlign: TextAlign.center,
              style: _base.copyWith(
                fontWeight: FontWeight.w600,
                color: secondary ? _c(theme.primary) : _c(theme.buttonText),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _plainButton(String label, VoidCallback onTap) => Semantics(
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: _base.copyWith(
                color: _c(theme.muted),
                decoration: TextDecoration.underline,
                decorationColor: _c(theme.muted),
              ),
            ),
          ),
        ),
      );

  Widget? _label(Map<String, Object?> b) {
    final label = asString(b['label']);
    if (label.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        '${view.text(label)}${b['required'] == true ? ' *' : ''}',
        style: _base.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget? _field(Map<String, Object?> b) {
    final name = asString(b['name']);
    final input = asString(b['input']);
    if (name.isEmpty || input == 'hidden') return null;
    final bad = view.invalid.contains(name);
    if (checkInputs.contains(input)) {
      final on = _checks[name] ?? false;
      return Semantics(
        checked: on,
        label: view.text(b['label']),
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _checks[name] = !on),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 20,
                height: 20,
                margin: const EdgeInsets.only(top: 1, right: 10),
                decoration: BoxDecoration(
                  color: on ? _c(theme.primary) : null,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: bad
                        ? const Color(0xffdc2626)
                        : on
                            ? _c(theme.primary)
                            : _c(theme.muted),
                  ),
                ),
                alignment: Alignment.center,
                child: on
                    ? Text('✓',
                        style: _base.copyWith(
                            color: _c(theme.buttonText),
                            fontSize: 13,
                            height: 1))
                    : null,
              ),
              Expanded(
                child: Text(
                  view.text(b['label']),
                  style: _base.copyWith(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (choiceInputs.contains(input)) {
      final selected = _choices[name];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_label(b) != null) _label(b)!,
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final o in fieldOptions(b))
                Semantics(
                  button: true,
                  selected: selected == o.value,
                  child: GestureDetector(
                    onTap: () => setState(() => _choices[name] = o.value),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          vertical: 8, horizontal: 14),
                      decoration: BoxDecoration(
                        color: selected == o.value ? _c(theme.primary) : null,
                        borderRadius: BorderRadius.circular(theme.buttonRadius),
                        border: Border.all(
                          color: bad
                              ? const Color(0xffdc2626)
                              : selected == o.value
                                  ? _c(theme.primary)
                                  : _c(theme.muted),
                        ),
                      ),
                      child: Text(
                        o.label,
                        style: _base.copyWith(
                          fontSize: 14,
                          color: selected == o.value
                              ? _c(theme.buttonText)
                              : _c(theme.text),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      );
    }
    final controller = _text[name];
    if (controller == null) return null;
    final keyboard = switch (input) {
      'email' => TextInputType.emailAddress,
      'phone' => TextInputType.phone,
      'number' || 'pincode' => TextInputType.number,
      'textarea' => TextInputType.multiline,
      _ => TextInputType.text,
    };
    final box = _input(
      controller: controller,
      focus: _focus[name]!,
      keyboard: keyboard,
      placeholder: asString(b['placeholder']),
      invalid: bad,
      lines: input == 'textarea' ? 3 : 1,
      prefix: input == 'phone' ? asString(b['default_country'], '+91') : null,
      semanticsLabel: asString(b['label'], asString(b['placeholder'], name)),
      autofill: switch (input) {
        'email' => AutofillHints.email,
        'phone' => AutofillHints.telephoneNumber,
        _ => name == 'name' || name == 'first_name'
            ? AutofillHints.givenName
            : null,
      },
    );
    final label = _label(b);
    if (label == null) return box;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [label, box],
    );
  }

  Widget _input({
    required TextEditingController controller,
    required FocusNode focus,
    required TextInputType keyboard,
    required String placeholder,
    required bool invalid,
    required String semanticsLabel,
    int lines = 1,
    String? prefix,
    String? autofill,
    Key? key,
  }) {
    final field = EditableText(
      key: key,
      controller: controller,
      focusNode: focus,
      style: _base,
      cursorColor: _c(theme.primary),
      backgroundCursorColor: _c(theme.muted),
      keyboardType: keyboard,
      maxLines: lines,
      minLines: lines,
      autofillHints: autofill == null ? null : [autofill],
      textInputAction:
          lines > 1 ? TextInputAction.newline : TextInputAction.next,
    );
    return Semantics(
      textField: true,
      label: semanticsLabel,
      child: GestureDetector(
        onTap: () => focus.requestFocus(),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: invalid ? const Color(0xffdc2626) : _c(theme.muted),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (prefix != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(prefix,
                      style: _base.copyWith(color: _c(theme.muted))),
                ),
              Expanded(
                child: Stack(children: [
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (_, value, __) => value.text.isEmpty
                        ? Text(
                            placeholder,
                            style: _base.copyWith(color: _c(theme.muted)),
                          )
                        : const SizedBox.shrink(),
                  ),
                  field,
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _otpField() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4, top: 4),
            child: Text(
              'Enter the code we sent on WhatsApp',
              style: _base.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          _input(
            key: const ValueKey('lemu-otp'),
            controller: _otp,
            focus: _otpFocus,
            keyboard: TextInputType.number,
            placeholder: '',
            invalid: false,
            semanticsLabel: 'Enter the code we sent on WhatsApp',
            autofill: AutofillHints.oneTimeCode,
          ),
          const SizedBox(height: 12),
        ],
      );

  Widget? _offer(Map<String, Object?> b) {
    final o = view.offer;
    if (o == null) return null;
    final code = asString(o['code']);
    final headline = asString(o['headline']);
    final terms = asString(o['terms']);
    final show = asString(b['show'], 'code');
    if (code.isEmpty && headline.isEmpty) return null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (headline.isNotEmpty && (show == 'headline' || show == 'both'))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              headline,
              textAlign: TextAlign.center,
              style: _base.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        if (code.isNotEmpty && show != 'headline')
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _c(theme.muted)),
            ),
            child: Row(children: [
              Expanded(
                child: Text(
                  code,
                  style: _base.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    letterSpacing: 1,
                  ),
                ),
              ),
              Semantics(
                button: true,
                child: GestureDetector(
                  onTap: _copy,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(theme.buttonRadius),
                      border: Border.all(color: _c(theme.primary)),
                    ),
                    child: Text(
                      _copied ? 'Copied' : asString(b['copy_label'], 'Copy'),
                      style: _base.copyWith(
                        color: _c(theme.primary),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        if (terms.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              terms,
              textAlign: TextAlign.center,
              style: _base.copyWith(fontSize: 12, color: _c(theme.muted)),
            ),
          ),
      ],
    );
  }

  void _copy() {
    final code = asString(view.offer?['code']);
    if (code.isEmpty) return;
    unawaited(
        Clipboard.setData(ClipboardData(text: code)).catchError((Object _) {}));
    setState(() => _copied = true);
    view.copied();
  }
}
