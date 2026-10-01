/// DataMuncher scanning engine.
///
/// Start with [ScanEngine]. Give it a [DeviceAdapter] (from
/// `scan_engine_flutter` on a phone, or [LocalDeviceAdapter] on a computer)
/// and call [ScanEngine.scan].
library;

export 'src/detectors/blank_photo_detector.dart';
export 'src/detectors/duplicate_photo_detector.dart';
export 'src/detectors/empty_file_detector.dart';
export 'src/detectors/unreadable_file_detector.dart';
export 'src/detectors/unused_app_detector.dart';
export 'src/detectors/waste_detector.dart';
export 'src/imaging/image_features.dart';
export 'src/imaging/pure_dart_thumbnail_decoder.dart';
export 'src/imaging/thumbnail.dart';
export 'src/model/file_types.dart';
export 'src/model/finding.dart';
export 'src/model/installed_app.dart';
export 'src/model/scan_report.dart';
export 'src/model/storage_item.dart';
export 'src/model/waste_category.dart';
export 'src/permissions/guarded_storage_source.dart';
export 'src/permissions/permissions.dart';
export 'src/platform/app_inventory.dart';
export 'src/platform/device_adapter.dart';
export 'src/platform/storage_source.dart';
export 'src/report_formatter.dart';
export 'src/scan/scan_context.dart';
export 'src/scan/scan_engine.dart';
export 'src/scan/scan_progress.dart';
export 'src/scan/scan_rules.dart';
export 'src/sources/composite_storage_source.dart';
export 'src/sources/local_device_adapter.dart';
export 'src/sources/local_directory_source.dart';
export 'src/sources/memory_storage_source.dart';
