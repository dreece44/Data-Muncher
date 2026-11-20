import '../model/finding.dart';
import '../model/waste_category.dart';
import '../permissions/permissions.dart';
import '../platform/device_adapter.dart';
import '../scan/scan_context.dart';
import 'waste_detector.dart';

/// Installed apps that haven't been opened for a long time
/// ([ScanRules.unusedAppAfter]).
///
/// Android only: iOS doesn't let apps see which other apps are installed
/// or how often they're used.
final class UnusedAppDetector extends WasteDetector {
  const UnusedAppDetector();

  @override
  WasteCategory get category => WasteCategory.unusedApp;

  @override
  Set<ScanPermission> get extraPermissions => const {ScanPermission.appUsage};

  @override
  String? unsupportedReason(DeviceAdapter device) => device.apps == null
      ? "This device's operating system doesn't let apps see which other "
          'apps are installed or how often they are used'
      : null;

  @override
  Future<List<Finding>> detect(ScanContext context) async {
    final apps = await context.device.apps!.listApps();
    final cutoff = context.now.subtract(context.rules.unusedAppAfter);
    final days = context.rules.unusedAppAfter.inDays;

    final findings = <Finding>[];
    for (var i = 0; i < apps.length; i++) {
      context.tick(category, i + 1, apps.length);
      final app = apps[i];
      if (app.isSystem || app.isEssential) continue;
      // Recently installed apps haven't had a chance to be used yet.
      final installed = app.installedAt;
      if (installed != null && installed.isAfter(cutoff)) continue;
      final lastUsed = app.lastUsedAt;
      if (lastUsed != null && !lastUsed.isBefore(cutoff)) continue;

      findings.add(Finding(
        category: category,
        items: [app],
        reason: lastUsed == null
            ? 'Not opened in at least $days days'
            : 'Last opened ${context.now.difference(lastUsed).inDays} days ago',
      ));
    }
    findings.sort((a, b) => b.reclaimableBytes.compareTo(a.reclaimableBytes));
    return findings;
  }
}
