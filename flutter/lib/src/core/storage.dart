/// Key-value storage the SDK keeps its anonymous id, user id, opt-out flag
/// and queue in.
///
/// The Flutter layer uses `shared_preferences`. Tests use
/// [InMemoryLemuStorage]. Implementations may throw; the SDK catches it.
abstract class LemuStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

/// Storage that lives only as long as the object. Useful for tests and for
/// apps that do not want anything written to disk.
class InMemoryLemuStorage implements LemuStorage {
  InMemoryLemuStorage([Map<String, String>? initial]) : values = {...?initial};

  /// The stored values, exposed so tests can inspect them.
  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }
}

/// Storage keys. Prefixed so they don't collide with the host app's keys.
abstract final class LemuStorageKeys {
  static const String anonymousId = 'lemu.anonymous_id';
  static const String userId = 'lemu.user_id';
  static const String queue = 'lemu.queue';
  static const String optOut = 'lemu.opt_out';
  static const String consent = 'lemu.consent';
  static const String appVersion = 'lemu.app_version';
  static const String appBuild = 'lemu.app_build';
}
