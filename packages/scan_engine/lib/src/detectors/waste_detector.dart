import '../model/finding.dart';
import '../model/waste_category.dart';
import '../permissions/permissions.dart';
import '../platform/device_adapter.dart';
import '../scan/scan_context.dart';

/// Finds one [WasteCategory] of wasted space. Add a category to the engine
/// by writing a subclass and passing it to `ScanEngine(detectors: ...)`.
abstract class WasteDetector {
  const WasteDetector();

  WasteCategory get category;

  /// Permissions needed on top of storage access. If any is missing the
  /// category is skipped, but the rest of the scan still runs.
  Set<ScanPermission> get extraPermissions => const {};

  /// Why this check can't run on [device] at all, or null if it can.
  String? unsupportedReason(DeviceAdapter device) => null;

  Future<List<Finding>> detect(ScanContext context);
}

/// Whether [bytes] hold no content: only whitespace, zero bytes, or a UTF-8
/// byte-order mark.
bool isBlankContent(List<int> bytes) {
  var start = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    start = 3;
  }
  for (var i = start; i < bytes.length; i++) {
    final b = bytes[i];
    if (b != 0x00 && b != 0x20 && b != 0x09 && b != 0x0A && b != 0x0D) {
      return false;
    }
  }
  return true;
}
