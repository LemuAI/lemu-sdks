import 'package:shared_preferences/shared_preferences.dart';

import '../core/storage.dart';

/// [LemuStorage] backed by shared_preferences (NSUserDefaults on Apple
/// platforms, SharedPreferences on Android, localStorage on the web, a
/// JSON file on Windows and Linux).
class SharedPreferencesLemuStorage implements LemuStorage {
  SharedPreferencesLemuStorage();

  Future<SharedPreferences>? _prefs;

  Future<SharedPreferences> get _instance =>
      _prefs ??= SharedPreferences.getInstance();

  @override
  Future<String?> read(String key) async => (await _instance).getString(key);

  @override
  Future<void> write(String key, String value) async {
    await (await _instance).setString(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await (await _instance).remove(key);
  }
}
