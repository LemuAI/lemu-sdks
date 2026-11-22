@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lemu_analytics/lemu_analytics.dart';
import 'package:lemu_analytics/src/experiences/engine.dart';
import 'package:lemu_analytics/src/flutter/experiences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';

Map<String, Object?> bundle(String format) => {
      'live': true,
      'v': 'v1',
      'theme': {'primary_color': '#0f766e'},
      'caps': <String, Object?>{},
      'decide': false,
      'experiences': [
        {
          'id': 9,
          'key': 'welcome',
          'format': format,
          'platform': 'app',
          'version': 1,
          'where': <String, Object?>{},
          'who': {'match': 'all', 'conditions': <Object?>[]},
          'trigger': {'on': 'manual'},
          'frequency': {'show': 'always', 'stop_after_submit': false},
          'holdout_pct': 0,
          'variants': [
            {
              'key': 'a',
              'weight': 100,
              'kind': 'blocks',
              'content': {
                'steps': [
                  {
                    'id': 'main',
                    'blocks': [
                      {'type': 'heading', 'text': 'Get **10%** off'},
                      {
                        'type': 'field',
                        'name': 'email',
                        'input': 'email',
                        'placeholder': 'Email',
                        'required': true,
                      },
                      {
                        'type': 'field',
                        'name': 'size',
                        'input': 'chips',
                        'options': ['S', 'M'],
                      },
                      {'type': 'button', 'text': 'Join', 'action': 'submit'},
                      {'type': 'close'},
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
        },
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<http.Request> requests;
  late List<LemuExperienceEvent> events;
  late List<String> tracked;

  setUp(() {
    requests = [];
    events = [];
    tracked = [];
  });

  /// A standalone LemuExperiences with its own engine (no Lemu core), so
  /// everything runs on the widget test's fake clock.
  Future<LemuExperiences> mount(WidgetTester tester, String format) async {
    final client = MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      if (path.endsWith('/onsite/config')) {
        return http.Response(jsonEncode(bundle(format)), 200);
      }
      if (path.endsWith('/onsite/submit')) {
        return http.Response(
            jsonEncode({
              'ok': true,
              'offer': {'code': 'SAVE10'},
            }),
            200);
      }
      return http.Response('', 204);
    });
    final experiences = LemuExperiences.internal();
    experiences.events.listen(events.add);
    final engine = ExperienceEngine(
      writeKey: testWriteKey,
      apiHost: 'https://lemu.test',
      client: client,
      storage: InMemoryLemuStorage(),
      track: (event, _) => tracked.add(event),
      anonymousId: () => 'visitor-1',
      userId: () => null,
      canStore: () => true,
      optedOut: () => false,
      display: () => experienceDisplayOf(experiences),
      emit: (e) => emitExperienceEvent(experiences, e),
    );
    attachExperienceEngine(experiences, engine);
    await tester.pumpWidget(WidgetsApp(
      color: const Color(0xffffffff),
      builder: (context, child) => LemuExperiencesHost(
        experiences: experiences,
        child: const SizedBox.expand(),
      ),
    ));
    final started = engine.start();
    await tester.pump(const Duration(milliseconds: 10));
    await started;
    expect(engine.bundle, isNotNull);
    addTearDown(engine.close);
    return experiences;
  }

  testWidgets('a popup shows in the host and the close button closes it',
      (tester) async {
    final experiences = await mount(tester, 'popup');
    expect(experiences.show('welcome'), isTrue);
    await tester.pump();
    expect(find.text('Get 10% off'), findsOneWidget);
    expect(find.text('No thanks'), findsOneWidget);
    expect(find.bySemanticsLabel('Close'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('lemu-close')));
    await tester.pump();
    expect(find.text('Get 10% off'), findsNothing);
    await tester.pump();
    expect(events.map((e) => e.type), [
      LemuExperienceEventType.shown,
      LemuExperienceEventType.closed,
    ]);
    expect(events.last.byUser, isTrue);
    expect(tracked, ['onsite_viewed', 'onsite_closed']);
  });

  testWidgets('the form checks the email, submits and shows the code',
      (tester) async {
    final experiences = await mount(tester, 'slide_in');
    experiences.show('welcome');
    await tester.pump();

    await tester.tap(find.text('Join'));
    await tester.pump();
    expect(find.text('Please fill in the highlighted fields.'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'asha@brand.test');
    await tester.tap(find.text('M'));
    await tester.pump();
    await tester.tap(find.text('Join'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    final submit =
        requests.lastWhere((r) => r.url.path.endsWith('/onsite/submit'));
    final body = jsonDecode(submit.body) as Map;
    expect(body['fields'], {'email': 'asha@brand.test', 'size': 'M'});
    expect(find.text('Thanks'), findsOneWidget);
    expect(find.text('SAVE10'), findsOneWidget);
    expect(events.last.type, LemuExperienceEventType.submitted);
    expect(events.last.offerCode, 'SAVE10');

    experiences.hide();
    await tester.pump();
    expect(find.text('Thanks'), findsNothing);
    expect(events.last.byUser, isFalse);
  });

  group('Lemu.instance', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      PackageInfo.setMockInitialValues(
        appName: 'Brand',
        packageName: 'com.brand.app',
        version: '2.0.0',
        buildNumber: '20',
        buildSignature: '',
      );
    });

    tearDown(() => Lemu.instance.debugTearDown());

    test('fetches experiences after setup and passes screens on', () async {
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/onsite/config')) {
          return http.Response(jsonEncode(bundle('popup')), 200);
        }
        return http.Response('', 204);
      });
      await Lemu.instance.setup(
        testWriteKey,
        options: const LemuOptions(trackLifecycle: false),
        storage: InMemoryLemuStorage(),
        httpClient: client,
      );
      await eventually(
          () => Lemu.instance.experiences.engine?.bundle?.live == true);
      final config =
          requests.firstWhere((r) => r.url.path.endsWith('/onsite/config'));
      expect(config.url.queryParameters['k'], testWriteKey);
      Lemu.instance.screen('Home');
      expect(Lemu.instance.experiences.engine!.screen, 'Home');
      // No host mounted: nothing can show.
      expect(Lemu.instance.experiences.show('welcome'), isFalse);
    });

    test('inAppMessages: false fetches nothing', () async {
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('', 204);
      });
      await Lemu.instance.setup(
        testWriteKey,
        options: const LemuOptions(trackLifecycle: false, inAppMessages: false),
        storage: InMemoryLemuStorage(),
        httpClient: client,
      );
      await settle();
      expect(Lemu.instance.experiences.show('welcome'), isFalse);
      expect(Lemu.instance.experiences.engine, isNull);
      expect(requests.where((r) => r.url.path.contains('/onsite/')), isEmpty);
    });
  });
}
