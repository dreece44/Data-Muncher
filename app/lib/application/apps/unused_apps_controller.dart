import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../data/apps/app_inventory.dart';
import '../../data/apps/installed_app.dart';
import '../exclusion/exclusion_list.dart';
import 'unused_apps.dart';

enum UnusedAppsStatus {
  /// First load in progress.
  loading,

  /// iPhone: not possible.
  unsupported,

  /// Android: waiting for the user to turn on Usage access.
  needsAccess,

  ready,
  failed,
}

/// Shown when the Android side of the feature isn't installed.
const String appInventoryNotSetUpMessage =
    "This build doesn't include DataMuncher's Android app-scanning code. "
    'Run `dart run tool/setup_platforms.dart`, then rebuild.';

/// What the Unused Apps screen and the home button show (DAT-25).
class UnusedAppsController extends ChangeNotifier {
  UnusedAppsController({
    required AppInventory inventory,
    required ExclusionList exclusions,
    this.rules = const UnusedAppRules(),
  })  : _inventory = inventory,
        _exclusions = exclusions {
    _exclusions.addListener(_onExclusionsChanged);
  }

  final AppInventory _inventory;
  final ExclusionList _exclusions;
  final UnusedAppRules rules;

  UnusedAppsStatus _status = UnusedAppsStatus.loading;
  String? _error;
  List<InstalledApp> _apps = const [];
  List<UnusedApp> _unused = const [];
  final Set<String> _uninstalling = {};
  int _generation = 0;
  bool _disposed = false;

  UnusedAppsStatus get status => _status;
  String? get error => _error;
  List<UnusedApp> get unused => _unused;
  int get totalBytes => _unused.fold(0, (sum, u) => sum + u.app.sizeBytes);
  bool isUninstalling(String packageName) =>
      _uninstalling.contains(packageName);

  /// For the home button: the number of unused apps, or null when unknown.
  int? get count => _status == UnusedAppsStatus.ready ? _unused.length : null;

  /// Checks access and reads the installed apps. Keeps the current list on
  /// screen while refreshing.
  Future<void> load() async {
    final generation = ++_generation;
    if (_status != UnusedAppsStatus.ready) {
      _status = UnusedAppsStatus.loading;
      _error = null;
      _notify();
    }
    try {
      final access = await _inventory.checkAccess();
      if (!_current(generation)) return;
      switch (access) {
        case AppAccess.unsupported:
          _status = UnusedAppsStatus.unsupported;
        case AppAccess.needsUsageAccess:
          _status = UnusedAppsStatus.needsAccess;
          _apps = const [];
          _recompute();
        case AppAccess.granted:
          final apps = await _inventory.listApps();
          if (!_current(generation)) return;
          _apps = List.unmodifiable(apps);
          _status = UnusedAppsStatus.ready;
          _error = null;
          _recompute();
      }
    } on MissingPluginException {
      if (!_current(generation)) return;
      _status = UnusedAppsStatus.failed;
      _error = appInventoryNotSetUpMessage;
    } catch (e) {
      if (!_current(generation)) return;
      debugPrint('Unused app scan failed: $e');
      _status = UnusedAppsStatus.failed;
      _error = "Couldn't read your apps. Please try again.";
    }
    _notify();
  }

  /// Sends the user to turn on Usage access. Call [onResumed] when they come
  /// back.
  Future<void> openUsageAccessSettings() =>
      _inventory.openUsageAccessSettings();

  /// The user may have changed Usage access or uninstalled apps while away.
  Future<void> onResumed() async {
    if (_status == UnusedAppsStatus.loading || _uninstalling.isNotEmpty) return;
    if (_status == UnusedAppsStatus.unsupported) return;
    await load();
  }

  /// Asks Android to uninstall [app]. Returns true if it's gone.
  Future<bool> uninstall(UnusedApp app) async {
    final pkg = app.app.packageName;
    if (!_uninstalling.add(pkg)) return false;
    _notify();
    try {
      final gone = await _inventory.uninstall(pkg);
      if (gone) {
        _apps = List.unmodifiable(_apps.where((a) => a.packageName != pkg));
        _recompute();
      }
      return gone;
    } finally {
      _uninstalling.remove(pkg);
      _notify();
    }
  }

  /// Keeps [app]: it isn't suggested again for 30 days (DAT-32).
  Future<Exclusion> keep(UnusedApp app) => _exclusions.exclude(
        app.app.packageName,
        kind: ExcludedKind.app,
        label: app.app.label,
      );

  Future<Uint8List?> appIcon(String packageName) =>
      _inventory.appIcon(packageName);

  void _onExclusionsChanged() {
    _recompute();
    _notify();
  }

  void _recompute() {
    _unused = List.unmodifiable(findUnusedApps(
      _apps,
      now: _exclusions.now(),
      rules: rules,
      isKept: (pkg) => _exclusions.isExcluded(pkg, kind: ExcludedKind.app),
    ));
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _exclusions.removeListener(_onExclusionsChanged);
    super.dispose();
  }
}
