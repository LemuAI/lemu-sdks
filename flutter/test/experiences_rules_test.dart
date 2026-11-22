import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lemu_analytics/src/experiences/engine.dart';
import 'package:lemu_analytics/src/experiences/rules.dart';
import 'package:lemu_analytics/src/experiences/state.dart';

Experience exp({
  int id = 1,
  String key = 'welcome',
  num holdout = 0,
  List<ExperienceVariant>? variants,
  List<UrlRule> include = const [],
  List<UrlRule> exclude = const [],
  String match = 'all',
  List<Condition> conditions = const [],
  bool server = false,
  int serverConditions = 0,
  Map<String, Object?> frequency = const {'show': 'session'},
}) =>
    Experience(
      id: id,
      key: key,
      holdoutPct: holdout,
      variants: variants ?? const [ExperienceVariant(key: 'a', weight: 100)],
      include: include,
      exclude: exclude,
      whoMatch: match,
      conditions: conditions,
      whoServer: server,
      serverConditions: serverConditions,
      frequency: frequency,
    );

void main() {
  group('bucket (FNV-1a, same as the website)', () {
    test('known vectors', () {
      expect(bucket(''), closeTo(0.5043429000, 1e-9));
      expect(bucket('a'), closeTo(0.8908105597, 1e-9));
      expect(bucket('abc:1'), closeTo(0.0781538687, 1e-9));
      expect(bucket('visitor-1:42'), closeTo(0.3183784358, 1e-9));
      expect(bucket('3f1c2d4e-0000-4000-8000-000000000001:7'),
          closeTo(0.0275701222, 1e-9));
    });
  });

  group('assign', () {
    test('holdout 10 with a 50 / 50 split', () {
      final e = exp(id: 42, holdout: 10, variants: const [
        ExperienceVariant(key: 'a', weight: 50),
        ExperienceVariant(key: 'b', weight: 50),
      ]);
      const expected = [
        'a', 'a', 'holdout', 'b', 'a', 'b', //
        'b', 'a', 'b', 'b', 'b', 'holdout',
      ];
      for (var i = 1; i <= 12; i++) {
        expect(assign(e, 'visitor-$i', SeenRecord()), expected[i - 1],
            reason: 'visitor-$i');
      }
    });

    test('weights 1 : 3 without holdout', () {
      final e = exp(id: 7, variants: const [
        ExperienceVariant(key: 'control', weight: 1),
        ExperienceVariant(key: 'new', weight: 3),
      ]);
      const expected = [
        'control', 'new', 'new', 'new', 'new', 'new', //
        'new', 'control', 'new', 'control', 'control', 'control',
      ];
      for (var i = 1; i <= 12; i++) {
        expect(assign(e, 'visitor-$i', SeenRecord()), expected[i - 1],
            reason: 'visitor-$i');
      }
    });

    test('sticky: a stored variant wins while it is still active', () {
      final e = exp(variants: const [
        ExperienceVariant(key: 'a', weight: 1),
        ExperienceVariant(key: 'b', weight: 1),
      ]);
      final h = SeenRecord(variant: 'b');
      expect(assign(e, 'anyone', h), 'b');
      final gone = SeenRecord(variant: 'old');
      expect(assign(e, 'visitor-1', gone), isNot('old'));
      expect(gone.variant, isNotNull);
      final held = SeenRecord(variant: 'holdout');
      expect(assign(e, 'visitor-1', held), isNot('holdout'));
    });
  });

  group('compare', () {
    test('operators', () {
      expect(compare('Returning', 'eq', 'returning'), isTrue);
      expect(compare('new', 'neq', 'returning'), isTrue);
      expect(compare(3, 'gte', 3), isTrue);
      expect(compare(3, 'gt', '3'), isFalse);
      expect(compare('2', 'lt', 10), isTrue);
      expect(compare('x', 'gt', 1), isFalse);
      expect(compare('Hello world', 'contains', 'WORLD'), isTrue);
      expect(compare('abc', 'not_contains', 'z'), isTrue);
      expect(compare('b', 'in', ['a', 'B']), isTrue);
      expect(compare('b', 'in', 'a, b'), isTrue);
      expect(compare('c', 'not_in', 'a,b'), isTrue);
      expect(compare(null, 'exists', null), isFalse);
      expect(compare('', 'not_exists', null), isTrue);
      expect(compare(true, 'eq', 'yes'), isTrue);
      expect(compare(false, 'eq', true), isFalse);
      expect(compare(2, null, 2.0), isTrue);
    });

    test('sameEvent ignores case, spaces, _ and -', () {
      expect(sameEvent('AddToCart', 'add_to_cart'), isTrue);
      expect(sameEvent('add to cart', 'AddToCart'), isTrue);
      expect(sameEvent('', ''), isFalse);
      expect(sameEvent('Purchase', 'AddToCart'), isFalse);
    });
  });

  group('whereMatches', () {
    test('no rules match every screen', () {
      expect(whereMatches(exp(), ''), isTrue);
      expect(whereMatches(exp(), 'Home'), isTrue);
    });

    test('screen_equals and screen_prefix ignore case', () {
      final e = exp(include: const [
        UrlRule('screen_equals', 'Home'),
        UrlRule('screen_prefix', 'product'),
      ]);
      expect(whereMatches(e, 'home'), isTrue);
      expect(whereMatches(e, 'ProductDetail'), isTrue);
      expect(whereMatches(e, 'Cart'), isFalse);
      expect(whereMatches(e, ''), isFalse);
    });

    test('exclude wins, web-only rules never match', () {
      final e = exp(exclude: const [UrlRule('screen_prefix', 'Checkout')]);
      expect(whereMatches(e, 'CheckoutPayment'), isFalse);
      expect(whereMatches(e, 'Home'), isTrue);
      final web = exp(include: const [UrlRule('path_equals', '/')]);
      expect(whereMatches(web, '/'), isFalse);
    });
  });

  group('whoMatches', () {
    test('visitor, visit_count and identified', () {
      final returning = exp(conditions: const [
        Condition('visitor', op: 'eq', value: 'returning'),
      ]);
      expect(whoMatches(returning, null, null, 1), isFalse);
      expect(whoMatches(returning, null, null, 2), isTrue);
      final often = exp(conditions: const [
        Condition('visit_count', op: 'gte', value: 3),
      ]);
      expect(whoMatches(often, null, null, 3), isTrue);
      final known = exp(conditions: const [Condition('identified')]);
      expect(whoMatches(known, null, null, 1), isFalse);
      expect(whoMatches(known, null, 'u1', 1), isTrue);
    });

    test('browser-only conditions are left out', () {
      final e = exp(match: 'any', conditions: const [
        Condition('device', op: 'eq', value: 'desktop'),
        Condition('utm_source', op: 'eq', value: 'google'),
      ]);
      expect(whoMatches(e, null, null, 1), isTrue);
      final all = exp(conditions: const [
        Condition('cart_value', op: 'gt', value: 1000),
        Condition('identified'),
      ]);
      expect(whoMatches(all, null, 'u1', 1), isTrue);
    });

    test('server answers', () {
      final e = exp(server: true, serverConditions: 1);
      expect(whoMatches(e, null, null, 1), isFalse);
      Decision answer(bool? match, {bool hidden = false}) => Decision(
            experiences: {
              'welcome': DecisionAnswer(match: match, hidden: hidden)
            },
          );
      expect(whoMatches(e, answer(true), null, 1), isTrue);
      expect(whoMatches(e, answer(false), null, 1), isFalse);
      expect(whoMatches(e, answer(true, hidden: true), null, 1), isFalse);
      final any = exp(
        match: 'any',
        server: true,
        serverConditions: 1,
        conditions: const [Condition('identified')],
      );
      expect(whoMatches(any, answer(false), null, 1), isFalse);
      expect(whoMatches(any, answer(true), null, 1), isTrue);
      expect(whoMatches(any, answer(false), 'u1', 1), isTrue);
    });
  });

  group('frequencyAllows', () {
    const hour = 3600 * 1000;
    final now = DateTime.utc(2026, 11, 20, 12).millisecondsSinceEpoch;

    ExperienceState state() => ExperienceState(session: 's1', visits: 1);

    test('session: once per session', () {
      final e = exp();
      expect(frequencyAllows(e, SeenRecord(), state(), now), isTrue);
      expect(
          frequencyAllows(
              e, SeenRecord(n: 1, sessionShown: 's1'), state(), now),
          isFalse);
      expect(
          frequencyAllows(
              e, SeenRecord(n: 1, sessionShown: 's0'), state(), now),
          isTrue);
    });

    test('day, days and ever', () {
      final day = exp(frequency: const {'show': 'day'});
      expect(
          frequencyAllows(
              day, SeenRecord(n: 1, last: now - 23 * hour), state(), now),
          isFalse);
      expect(
          frequencyAllows(
              day, SeenRecord(n: 1, last: now - 25 * hour), state(), now),
          isTrue);
      final days = exp(frequency: const {'show': 'days', 'days': 3});
      expect(
          frequencyAllows(
              days, SeenRecord(n: 1, last: now - 50 * hour), state(), now),
          isFalse);
      expect(
          frequencyAllows(
              days, SeenRecord(n: 1, last: now - 73 * hour), state(), now),
          isTrue);
      final ever = exp(frequency: const {'show': 'ever'});
      expect(frequencyAllows(ever, SeenRecord(), state(), now), isTrue);
      expect(frequencyAllows(ever, SeenRecord(n: 1), state(), now), isFalse);
    });

    test('submit, closes and cooldown', () {
      final always = exp(frequency: const {'show': 'always'});
      expect(frequencyAllows(always, SeenRecord(submitted: now), state(), now),
          isFalse);
      final keep = exp(frequency: const {
        'show': 'always',
        'stop_after_submit': false,
        'cooldown_hours_after_close': 0,
      });
      expect(frequencyAllows(keep, SeenRecord(submitted: now), state(), now),
          isTrue);
      final closes = exp(frequency: const {
        'show': 'always',
        'max_closes': 2,
        'cooldown_hours_after_close': 0,
      });
      expect(
          frequencyAllows(
              closes, SeenRecord(closes: 2, lastClose: 1), state(), now),
          isFalse);
      expect(
          frequencyAllows(always,
              SeenRecord(closes: 1, lastClose: now - 2 * hour), state(), now),
          isFalse);
      expect(
          frequencyAllows(always,
              SeenRecord(closes: 1, lastClose: now - 25 * hour), state(), now),
          isTrue);
    });
  });

  group('bundle', () {
    test('live: false and junk give nothing', () {
      expect(ExperienceBundle.fromJson({'live': false}).live, isFalse);
      expect(ExperienceBundle.fromJson('nope').experiences, isEmpty);
    });

    test('keeps app formats and platforms only', () {
      final b = ExperienceBundle.fromJson({
        'live': true,
        'v': 'abc',
        'decide': true,
        'caps': {'popups_per_session': 2},
        'theme': {'primary_color': '#ff0000'},
        'experiences': [
          {
            'id': 1,
            'key': 'popup_app',
            'format': 'popup',
            'platform': 'app',
            'where': {
              'include': [
                {'type': 'screen_equals', 'value': 'Home'}
              ]
            },
            'who': {'match': 'all', 'conditions': [], 'server': true},
            'trigger': {'on': 'delay', 'seconds': 3},
            'frequency': {'show': 'ever'},
            'holdout_pct': 10,
            'variants': [
              {'key': 'a', 'weight': 100, 'kind': 'blocks', 'content': {}}
            ],
          },
          {
            'id': 2,
            'key': 'inline',
            'format': 'inline',
            'platform': 'any',
            'variants': [
              {'key': 'a', 'weight': 1}
            ],
          },
          {
            'id': 3,
            'key': 'web_bar',
            'format': 'bar',
            'platform': 'web',
            'variants': [
              {'key': 'a', 'weight': 1}
            ],
          },
          {
            'id': 4,
            'key': 'any_toast',
            'format': 'toast',
            'platform': 'any',
            'trigger': {'on': 'add_to_cart'},
            'variants': [
              {'key': 'a', 'weight': 1}
            ],
          },
        ],
      });
      expect(b.live, isTrue);
      expect(b.decide, isTrue);
      expect(b.experiences.map((e) => e.key), ['popup_app', 'any_toast']);
      final e = b.find('popup_app')!;
      expect(e.triggerOn, 'delay');
      expect(e.trigger['seconds'], 3);
      expect(e.whoServer, isTrue);
      expect(e.holdoutPct, 10);
      expect(e.include.single.type, 'screen_equals');
      expect(b.find('any_toast')!.triggerEvent, 'AddToCart');
    });
  });

  group('text, colours and fields', () {
    test('plainText and fill', () {
      expect(plainText('Get **10% off** your *first* [order](https://x.y)'),
          'Get 10% off your first order');
      expect(
          fill('Code {{offer.code}} for {{answers.name}}{{answers.none}}', {
            'offer': {'code': 'SAVE10'},
            'answers': {'name': 'Asha'},
          }),
          'Code SAVE10 for Asha');
    });

    test('parseColor', () {
      expect(parseColor('#fff'), 0xffffffff);
      expect(parseColor('#111827'), 0xff111827);
      expect(parseColor('#11182780'), 0x80111827);
      expect(parseColor('rgba(17,24,39,0.55)'), 0x8c111827);
      expect(parseColor('rgb(255, 0, 0)'), 0xffff0000);
      expect(parseColor('red'), isNull);
      final theme = ExperienceTheme.resolve(
        {'primary_color': '#ff0000', 'button_style': 'pill'},
        {'background': '#000000'},
      );
      expect(theme.primary, 0xffff0000);
      expect(theme.background, 0xff000000);
      expect(theme.buttonRadius, 999);
      expect(theme.radius, 12);
    });

    test('validateStep and normalizePhone', () {
      final blocks = [
        {'type': 'field', 'name': 'email', 'input': 'email', 'required': true},
        {'type': 'field', 'name': 'phone', 'input': 'phone'},
        {'type': 'field', 'name': 'ok', 'input': 'consent', 'required': true},
      ];
      expect(validateStep(blocks, {'email': '', 'ok': true}).message,
          'Please fill in the highlighted fields.');
      expect(validateStep(blocks, {'email': 'a@b.co', 'ok': false}).invalid,
          {'ok'});
      expect(validateStep(blocks, {'email': 'nope', 'ok': true}).message,
          'Enter a valid email address.');
      expect(
          validateStep(blocks, {'email': 'a@b.co', 'phone': '123', 'ok': true})
              .message,
          'Enter a valid phone number.');
      expect(
          validateStep(blocks,
              {'email': 'a@b.co', 'phone': '98765 43210', 'ok': true}).ok,
          isTrue);
      expect(normalizePhone('098765 43210', '+91'), '+919876543210');
      expect(normalizePhone('+1 (415) 555-0100', '+91'), '+14155550100');
      expect(normalizePhone(' ', '+91'), '');
    });
  });

  test('state: sessions and round trip', () {
    final random = Random(1);
    final s = ExperienceState();
    final start = DateTime.utc(2026, 11, 20).millisecondsSinceEpoch;
    expect(s.touch(start, random), isTrue);
    expect(s.visits, 1);
    final first = s.session;
    expect(first, hasLength(8));
    expect(s.touch(start + 10 * 60 * 1000, random), isFalse);
    expect(s.touch(start + 50 * 60 * 1000, random), isTrue);
    expect(s.visits, 2);
    expect(s.session, isNot(first));
    s.seenFor('welcome')
      ..n = 2
      ..variant = 'a';
    final back = ExperienceState.decode(s.encode());
    expect(back.visits, 2);
    expect(back.session, s.session);
    expect(back.seen['welcome']!.n, 2);
    expect(back.seen['welcome']!.variant, 'a');
    expect(ExperienceState.decode('{bad').visits, 0);
  });
}
