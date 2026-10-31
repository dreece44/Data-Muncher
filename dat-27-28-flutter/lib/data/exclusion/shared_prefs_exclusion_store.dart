import 'package:shared_preferences/shared_preferences.dart';

import '../../application/exclusion/exclusion_list.dart';

/// Saves the Do-not-collect list in the app's SharedPreferences.
class SharedPrefsExclusionStore implements ExclusionStore {
  SharedPrefsExclusionStore(this.prefs);

  final SharedPreferences prefs;

  @override
  List<String>? getStringList(String key) => prefs.getStringList(key);

  @override
  Future<void> setStringList(String key, List<String> value) =>
      prefs.setStringList(key, value);

  @override
  Future<void> remove(String key) => prefs.remove(key);
}
