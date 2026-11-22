import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lemu_analytics/core.dart';
import 'package:lemu_analytics/src/experiences/engine.dart';
import 'package:lemu_analytics/src/experiences/state.dart';

import 'support/harness.dart';

class FakeDisplay implements ExperienceDisplay {
  final List<ExperienceView> shown = [];
  ExperienceView? current;

  @override
  void showExperience(ExperienceView view) {
    shown.add(view);
    current = view;
  }

  @override
  void hideExperience(ExperienceView view) {
    if (identical(current, view)) current = null;
  }
}

Map<String, Object?> experience({
  int id = 1,
  String key = 'welcome',
  String format = 'popup',
  Map<String, Object?> trigger = const {'on': 'page_load'},
  List<Map<String, Object?>> include = const [],
  num holdout = 0,
  Map<String, Object?> who = const {'match': 'all', 'conditions': []},
  Map<String, Object?> frequency = const {'show': 'session'},
  List<Map<String, Object?>>? steps,
}) =>
    {
      'id': id,
      'key': key,
      'format': format,
      'platform': 'app',
      'version': 3,
      'where': {'include': include},
      'who': who,
      'trigger': trigger,
      'frequency': frequency,
      'holdout_pct': holdout,
      'variants': [
        {
          'key': 'a',
          'weight': 100,
          'kind': 'blocks',
          'content': {
            'steps': steps ??
                [
                  {
                    'id': 'main',
                    'blocks': [
                      {'type': 'heading', 'text': 'Hello'},
                      {
                        'type': 'field',
                        'name': 'email',
                        'input': 'email',
                        'required': true
                      },
                      {'type': 'button', 'text': 'Join', 'action': 'submit'},
                    ],
                  },
                  {
                    'id': 'success',
                    'blocks': [
                      {'type': 'heading', 'text': 'Thanks'},
                      {'type': 'offer'},
                    ],
                  },
                ],
          },
        },
      ],
    };

class Harness {
  Harness(List<Map<String, Object?>> experiences,
      {this.anonymousId = 'visitor-1', bool decide = false}) {
    bundle = {
      'live': true,
      'v': 'v1',
      'theme': <String, Object?>{},
      'caps': {'popups_per_page': 1, 'popups_per_session': 5},
      'decide': decide,
      'experiences': experiences,
    };
    client = MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      if (path.endsWith('/onsite/config')) {
        return http.Response(jsonEncode(bundle), 200);
      }
      if (path.endsWith('/onsite/decide')) {
        return http.Response(jsonEncode(decision), 200);
      }
      if (path.endsWith('/onsite/submit')) {
        return http.Response(jsonEncode(submitReply), submitStatus);
      }
      return http.Response('', 404);
    });
    engine = ExperienceEngine(
      writeKey: testWriteKey,
      apiHost: 'https://lemu.test/',
      client: client,
      storage: storage,
      track: (event, props) => tracked.add(MapEntry(event, props)),
      anonymousId: () => anonymousId,
      userId: () => null,
      canStore: () => true,
      optedOut: () => false,
      display: () => display,
      emit: events.add,
      platform: 'ios',
      userAgent: () => testUserAgent,
      clock: () => clock.now,
      random: Random(3),
    );
  }

  final String? anonymousId;
  late Map<String, Object?> bundle;
  Map<String, Object?> decision = {'known': false, 'experiences': {}};
  Map<String, Object?> submitReply = {'ok': true};
  int submitStatus = 200;
  final List<http.Request> requests = [];
  late final MockClient client;
  late final ExperienceEngine engine;
  final storage = InMemoryLemuStorage();
  final display = FakeDisplay();
  final clock = TestClock();
  final List<MapEntry<String, Map<String, Object?>>> tracked = [];
  final List<LemuExperienceEvent> events = [];

  List<String> get trackedNames => tracked.map((e) => e.key).toList();

  http.Request request(String suffix) =>
      requests.lastWhere((r) => r.url.path.endsWith(suffix));
}

void main() {
  test('fetches the config and shows a page_load popup on a matching screen',
      () async {
    final h = Harness([
      experience(include: [
        {'type': 'screen_equals', 'value': 'Home'}
      ]),
    ]);
    await h.engine.start();
    final config = h.request('/onsite/config');
    expect(config.url.toString(),
        'https://lemu.test/api/v1/pixel/onsite/config?k=$testWriteKey');
    expect(config.headers['User-Agent'], testUserAgent);
    expect(h.display.shown, isEmpty, reason: 'no screen yet');

    h.engine.onScreen('Cart');
    await settle();
    expect(h.display.shown, isEmpty);

    h.engine.onScreen('Home');
    await settle();
    expect(h.display.shown, hasLength(1));
    expect(h.trackedNames, ['onsite_viewed']);
    expect(h.tracked.single.value, {
      'experience_id': 1,
      'experience': 'welcome',
      'variant': 'a',
      'version': 3,
      'format': 'popup',
      'screen': 'Home',
    });
    expect(h.events.single.type, LemuExperienceEventType.shown);
    final stored = ExperienceState.decode(h.storage.values['lemu.experiences']);
    expect(stored.seen['welcome']!.n, 1);
    expect(stored.seen['welcome']!.variant, 'a');
    expect(stored.popupsThisSession, 1);

    // Closed by the user: counted, and not again this session.
    h.engine.current!.close();
    expect(h.trackedNames.last, 'onsite_closed');
    expect(h.events.last.byUser, isTrue);
    expect(h.engine.state.seen['welcome']!.closes, 1);
    h.engine.onScreen('Home');
    await settle();
    expect(h.display.shown, hasLength(1));
  });

  test('a visitor in the holdout gets onsite_held_out once per session',
      () async {
    // visitor-3 rolls holdout for experience 42 with 10% held out.
    final h =
        Harness([experience(id: 42, holdout: 10)], anonymousId: 'visitor-3');
    await h.engine.start();
    await settle();
    expect(h.display.shown, isEmpty);
    expect(h.trackedNames, ['onsite_held_out']);
    expect(h.tracked.single.value['variant'], 'holdout');
    h.engine.onScreen('Home');
    await settle();
    expect(h.trackedNames, ['onsite_held_out']);
    expect(h.engine.show('welcome'), isFalse);
  });

  test('event triggers, internal events and setEnabled', () async {
    final h = Harness([
      experience(
        key: 'cart_nudge',
        format: 'toast',
        trigger: {'on': 'event', 'event': 'AddToCart'},
      ),
    ]);
    await h.engine.start();
    h.engine.onTrack('onsite_viewed', const {});
    h.engine.setEnabled(false);
    h.engine.onTrack('add_to_cart', const {});
    await settle();
    expect(h.display.shown, isEmpty);
    h.engine.setEnabled(true);
    h.engine.onTrack('add_to_cart', const {});
    await settle();
    expect(h.display.shown.single.experience.key, 'cart_nudge');
  });

  test('delay trigger waits and a new screen cancels it', () async {
    final h = Harness([
      experience(trigger: {'on': 'delay', 'seconds': 0.2}),
    ]);
    await h.engine.start();
    h.engine.onScreen('A');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    h.engine.onScreen('B');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(h.display.shown, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(h.display.shown, hasLength(1));
  });

  test('manual show waits for the bundle and ignores where and frequency',
      () async {
    final h = Harness([
      experience(
        trigger: {'on': 'manual'},
        include: [
          {'type': 'screen_equals', 'value': 'Nowhere'}
        ],
        frequency: {'show': 'ever'},
      ),
    ]);
    expect(h.engine.show('welcome'), isFalse);
    await h.engine.start();
    expect(h.display.shown, hasLength(1), reason: 'pending show ran');
    h.engine.hide();
    expect(h.events.last.byUser, isFalse);
    expect(h.engine.state.seen['welcome']!.closes, 0);
    expect(h.engine.show('welcome'), isTrue);
    expect(h.engine.show('unknown'), isFalse);
  });

  test('server rules ask decide first', () async {
    final h = Harness([
      experience(who: {
        'match': 'all',
        'conditions': [],
        'server': true,
        'server_conditions': 1,
      }),
    ], decide: true);
    h.decision = {
      'known': true,
      'experiences': {
        'welcome': {'match': false, 'hidden': false}
      },
    };
    await h.engine.start();
    h.engine.onTrack('ViewContent', const {
      'content_ids': ['SKU9']
    });
    h.engine.onScreen('Product');
    await settle(10);
    expect(h.display.shown, isEmpty);
    final body = jsonDecode(h.request('/onsite/decide').body) as Map;
    expect(body['writeKey'], testWriteKey);
    expect(body['anonymousId'], 'visitor-1');
    expect(
        body['context'], {'screen': 'Product', 'product': <String, Object?>{}});

    h.decision = {
      'known': true,
      'experiences': {
        'welcome': {'match': true, 'hidden': false}
      },
    };
    h.engine.onScreen('Product2');
    await settle(10);
    expect(h.display.shown, hasLength(1));
  });

  test('submit sends the form and moves to the success step', () async {
    final h = Harness([
      experience(trigger: {'on': 'manual'})
    ]);
    await h.engine.start();
    expect(h.engine.show('welcome'), isTrue);
    final view = h.engine.current!;

    await view.submit({'email': 'nope'});
    expect(view.error, 'Enter a valid email address.');
    expect(h.requests.where((r) => r.url.path.endsWith('/submit')), isEmpty);

    h.submitReply = {
      'ok': true,
      'offer': {'code': 'SAVE10', 'headline': '10% off'},
    };
    await view.submit({'email': 'a@b.co'});
    final body = jsonDecode(h.request('/onsite/submit').body) as Map;
    expect(body['experience'], 'welcome');
    expect(body['variant'], 'a');
    expect(body['fields'], {'email': 'a@b.co'});
    expect(body['context'],
        {'screen': '', 'platform': 'ios', 'phone_country': '+91'});
    expect(h.request('/onsite/submit').headers['Content-Type'],
        startsWith('application/json'));
    expect(view.step!.id, 'success');
    expect(view.offer!['code'], 'SAVE10');
    expect(h.events.last.type, LemuExperienceEventType.submitted);
    expect(h.events.last.offerCode, 'SAVE10');
    expect(h.engine.state.seen['welcome']!.submitted, greaterThan(0));

    view.copied();
    expect(h.tracked.last.value['target'], 'copy_code');
  });

  test('submit errors and the WhatsApp code step', () async {
    final h = Harness([
      experience(trigger: {'on': 'manual'})
    ]);
    await h.engine.start();
    h.engine.show('welcome');
    final view = h.engine.current!;

    h.submitReply = {'ok': false};
    h.submitStatus = 429;
    await view.submit({'email': 'a@b.co'});
    expect(view.error, 'Please try again in a minute.');

    h.submitStatus = 200;
    h.submitReply = {'ok': false, 'verify': true};
    await view.submit({'email': 'a@b.co'});
    expect(view.otpPending, isTrue);

    h.submitReply = {'ok': true};
    await view.submit(const {}, otp: '123456');
    final body = jsonDecode(h.request('/onsite/submit').body) as Map;
    expect(body['otp'], '123456');
    expect(body['fields'], {'email': 'a@b.co'});
    expect(view.step!.id, 'success');
  });

  test('a url button tracks the click and calls the handler', () async {
    final h = Harness([
      experience(trigger: {
        'on': 'manual'
      }, steps: [
        {
          'id': 'main',
          'blocks': [
            {
              'type': 'button',
              'text': 'Shop',
              'action': 'url',
              'url': 'https://brand.test/sale'
            },
          ],
        },
      ]),
    ]);
    Uri? opened;
    h.engine.urlHandler = (uri) => opened = uri;
    await h.engine.start();
    h.engine.show('welcome');
    h.engine.current!.openUrl('https://brand.test/sale');
    expect(opened.toString(), 'https://brand.test/sale');
    expect(h.trackedNames, ['onsite_viewed', 'onsite_clicked']);
    expect(h.tracked.last.value['target'], 'https://brand.test/sale');
    expect(h.engine.current, isNull);
    expect(h.engine.state.seen['welcome']!.closes, 0);
  });

  test('live: false shows nothing and the foreground refresh waits 5 minutes',
      () async {
    final h = Harness([experience()]);
    h.bundle = {'live': false};
    await h.engine.start();
    h.engine.onScreen('Home');
    await settle();
    expect(h.display.shown, isEmpty);
    h.engine.onForeground();
    await settle();
    expect(
        h.requests.where((r) => r.url.path.endsWith('/config')), hasLength(1));
    h.clock.advance(const Duration(minutes: 6));
    h.engine.onForeground();
    await settle();
    expect(
        h.requests.where((r) => r.url.path.endsWith('/config')), hasLength(2));
  });
}
