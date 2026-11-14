// The validator in support/schema.dart must reject what batch.schema.json
// rejects, or the conformance checks prove nothing.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'support/schema.dart';

Map<String, dynamic> _validBody() => {
      'writeKey': 'pk_test',
      'sentAt': '2026-11-14T10:00:01.123Z',
      'batch': [
        {
          'type': 'track',
          'event': 'AddToCart',
          'properties': {'value': 999},
          'messageId': '0b8f5c0e-3b0a-4c1e-9f1d-2a6b7c8d9e0f',
          'anonymousId': 'a1',
          'timestamp': '2026-11-14T10:00:00.123Z',
          'context': {
            'platform': 'flutter',
            'library': {'name': 'lemu-flutter', 'version': '1.0.0'},
          },
        },
      ],
    };

List<String> _errors(void Function(Map<String, dynamic> body) mutate) {
  final body = jsonDecode(jsonEncode(_validBody())) as Map<String, dynamic>;
  mutate(body);
  return validateAgainstSchema(body, loadBatchSchema());
}

Map<String, dynamic> _message(Map<String, dynamic> body) =>
    (body['batch'] as List).first as Map<String, dynamic>;

void main() {
  test('a valid body passes', () {
    expect(_errors((_) {}), isEmpty);
  });

  final cases = <String, void Function(Map<String, dynamic>)>{
    'missing writeKey': (b) => b.remove('writeKey'),
    'sentAt without Z': (b) => b['sentAt'] = '2026-11-14T10:00:01',
    'empty batch': (b) => b['batch'] = <Object>[],
    'more than 50 messages': (b) => b['batch'] = List.filled(51, _message(b)),
    'messageId not v4': (b) =>
        _message(b)['messageId'] = '0b8f5c0e-3b0a-1c1e-9f1d-2a6b7c8d9e0f',
    'unknown type': (b) => _message(b)['type'] = 'alias',
    'track without event': (b) => _message(b).remove('event'),
    'track without properties': (b) => _message(b).remove('properties'),
    'screen without name': (b) => _message(b)['type'] = 'screen',
    'identify without traits': (b) => _message(b)['type'] = 'identify',
    'unknown platform': (b) =>
        (_message(b)['context'] as Map)['platform'] = 'unity',
    'advertising id in context': (b) =>
        (_message(b)['context'] as Map)['idfa'] = 'x',
    'bad device type': (b) =>
        (_message(b)['context'] as Map)['device'] = {'type': 'watch'},
    'anonymousId too long': (b) => _message(b)['anonymousId'] = 'a' * 129,
  };
  cases.forEach((name, mutate) {
    test('rejects: $name', () => expect(_errors(mutate), isNotEmpty));
  });
}
