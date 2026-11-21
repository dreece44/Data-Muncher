import 'package:shared_preferences/shared_preferences.dart';

import '../../application/monetization/monetization_controller.dart';

/// Saves the last known plan so an ad-free user sees no ads at launch.
class SharedPrefsPlanStore implements PlanStore {
  SharedPrefsPlanStore(this.prefs);

  static const String key = 'plan';

  final SharedPreferences prefs;

  @override
  Plan? read() {
    final name = prefs.getString(key);
    for (final plan in Plan.values) {
      if (plan.name == name) return plan;
    }
    return null;
  }

  @override
  Future<void> write(Plan plan) => prefs.setString(key, plan.name);
}
