/// Access the scan engine may need from the user.
enum ScanPermission {
  /// Android: "All files access" (MANAGE_EXTERNAL_STORAGE) on Android 11+,
  /// READ_EXTERNAL_STORAGE on older versions.
  storage('Storage access'),

  /// iOS: access to the Photos library ("Full" or "Limited").
  photos('Photo library access'),

  /// Android: "Usage access", which lets the app see when other apps were
  /// last used. Only needed for unused-app detection.
  appUsage('App usage access');

  const ScanPermission(this.label);
  final String label;
}

enum PermissionState {
  granted,

  /// iOS "Limited" photo access: only photos the user selected are visible.
  limited,
  denied,

  /// The user said no and the OS won't ask again. The user must change it
  /// in the device's Settings app.
  permanentlyDenied,

  /// Blocked by parental controls or device management.
  restricted;

  bool get allowsAccess =>
      this == PermissionState.granted || this == PermissionState.limited;
}

/// Checks and requests permissions on the current device.
///
/// On a phone this is backed by the OS (see the `scan_engine_flutter`
/// package). On a development computer [StaticPermissionService] simulates
/// the user's answers.
abstract interface class PermissionService {
  /// Current state, without prompting the user.
  Future<PermissionState> check(ScanPermission permission);

  /// Prompts the user (or opens the Settings screen) and returns the result.
  /// This is for the onboarding / grant flow (DAT-15). The scan engine itself
  /// never calls it: it only checks.
  Future<PermissionState> request(ScanPermission permission);
}

/// Thrown by `ScanEngine.scan` when required storage access hasn't been
/// granted. No storage has been read when this is thrown.
final class PermissionDeniedException implements Exception {
  PermissionDeniedException(this.missing) : assert(missing.isNotEmpty);

  /// Each permission that is missing, with its current state.
  final Map<ScanPermission, PermissionState> missing;

  @override
  String toString() {
    final details = [
      for (final e in missing.entries) '${e.key.label} is ${e.value.name}',
    ].join(', ');
    return 'PermissionDeniedException: scan refused because $details. '
        'Ask the user to grant access before scanning.';
  }
}

/// A [PermissionService] with fixed answers. Used by tests and by the
/// command-line scanner to simulate a user granting or denying access.
final class StaticPermissionService implements PermissionService {
  StaticPermissionService([Map<ScanPermission, PermissionState>? states])
      : _states = {...?states};

  final Map<ScanPermission, PermissionState> _states;

  /// Permissions that were checked, in order. Lets tests prove the gate ran.
  final List<ScanPermission> checks = [];

  void set(ScanPermission permission, PermissionState state) =>
      _states[permission] = state;

  @override
  Future<PermissionState> check(ScanPermission permission) async {
    checks.add(permission);
    return _states[permission] ?? PermissionState.denied;
  }

  @override
  Future<PermissionState> request(ScanPermission permission) =>
      check(permission);
}
