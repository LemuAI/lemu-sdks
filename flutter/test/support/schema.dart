import 'dart:convert';
import 'dart:io';

/// Loads `../conformance/batch.schema.json` (relative to the package root,
/// where `flutter test` runs).
Map<String, dynamic> loadBatchSchema() =>
    jsonDecode(File('../conformance/batch.schema.json').readAsStringSync())
        as Map<String, dynamic>;

/// A small JSON Schema (2020-12) validator covering the keywords
/// batch.schema.json uses: type, required, properties, enum, const,
/// pattern, minLength, maxLength, minItems, maxItems, items, $ref to
/// #/$defs, allOf, anyOf, not, if/then. Returns the errors found.
List<String> validateAgainstSchema(Object? value, Map<String, dynamic> root) {
  final errors = <String>[];
  _validate(value, root, root, r'$', errors);
  return errors;
}

void _validate(
  Object? value,
  Map<String, dynamic> schema,
  Map<String, dynamic> root,
  String path,
  List<String> errors,
) {
  final ref = schema[r'$ref'];
  if (ref is String) {
    const prefix = r'#/$defs/';
    if (!ref.startsWith(prefix)) {
      errors.add('$path: unsupported \$ref $ref');
      return;
    }
    final target = (root[r'$defs'] as Map)[ref.substring(prefix.length)];
    _validate(value, target as Map<String, dynamic>, root, path, errors);
  }

  final type = schema['type'];
  if (type is String && !_hasType(value, type)) {
    errors.add('$path: expected $type, got ${value.runtimeType}');
    return;
  }
  if (schema.containsKey('const') && value != schema['const']) {
    errors.add('$path: expected ${schema['const']}');
  }
  final enumValues = schema['enum'];
  if (enumValues is List && !enumValues.contains(value)) {
    errors.add('$path: $value not in $enumValues');
  }
  if (value is String) {
    final pattern = schema['pattern'];
    if (pattern is String && !RegExp(pattern).hasMatch(value)) {
      errors.add('$path: "$value" does not match $pattern');
    }
    final minLength = schema['minLength'];
    if (minLength is int && value.length < minLength) {
      errors.add('$path: shorter than $minLength');
    }
    final maxLength = schema['maxLength'];
    if (maxLength is int && value.length > maxLength) {
      errors.add('$path: longer than $maxLength');
    }
  }
  if (value is List) {
    final minItems = schema['minItems'];
    if (minItems is int && value.length < minItems) {
      errors.add('$path: fewer than $minItems items');
    }
    final maxItems = schema['maxItems'];
    if (maxItems is int && value.length > maxItems) {
      errors.add('$path: more than $maxItems items');
    }
    final items = schema['items'];
    if (items is Map<String, dynamic>) {
      for (var i = 0; i < value.length; i++) {
        _validate(value[i], items, root, '$path[$i]', errors);
      }
    }
  }
  if (value is Map) {
    final required = schema['required'];
    if (required is List) {
      for (final key in required) {
        if (!value.containsKey(key)) errors.add('$path: missing $key');
      }
    }
    final properties = schema['properties'];
    if (properties is Map) {
      properties.forEach((key, sub) {
        if (value.containsKey(key)) {
          _validate(value[key], sub as Map<String, dynamic>, root, '$path.$key',
              errors);
        }
      });
    }
  }
  final allOf = schema['allOf'];
  if (allOf is List) {
    for (final sub in allOf) {
      _validate(value, sub as Map<String, dynamic>, root, path, errors);
    }
  }
  final anyOf = schema['anyOf'];
  if (anyOf is List) {
    final ok = anyOf.any((sub) => _matches(value, sub, root));
    if (!ok) errors.add('$path: matches none of anyOf');
  }
  final not = schema['not'];
  if (not is Map<String, dynamic> && _matches(value, not, root)) {
    errors.add('$path: matches a "not" schema');
  }
  final ifSchema = schema['if'];
  if (ifSchema is Map<String, dynamic> && _matches(value, ifSchema, root)) {
    final then = schema['then'];
    if (then is Map<String, dynamic>) {
      _validate(value, then, root, path, errors);
    }
  }
}

bool _matches(Object? value, Object? schema, Map<String, dynamic> root) {
  final errors = <String>[];
  _validate(value, schema as Map<String, dynamic>, root, r'$', errors);
  return errors.isEmpty;
}

bool _hasType(Object? value, String type) => switch (type) {
      'object' => value is Map,
      'array' => value is List,
      'string' => value is String,
      'number' => value is num,
      'integer' => value is int || (value is double && value == value.round()),
      'boolean' => value is bool,
      'null' => value == null,
      _ => true,
    };

/// Validates a raw request body; returns the errors.
List<String> validateBody(String rawBody) =>
    validateAgainstSchema(jsonDecode(rawBody), loadBatchSchema());
