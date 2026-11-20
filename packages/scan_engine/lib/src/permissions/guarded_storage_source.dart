import 'dart:typed_data';

import '../imaging/thumbnail.dart';
import '../model/scan_report.dart';
import '../model/storage_item.dart';
import '../platform/storage_source.dart';
import 'permissions.dart';

/// Wraps a [StorageSource] so it refuses to touch storage unless the
/// required permissions are granted.
///
/// `ScanEngine` already checks permissions before scanning. This wrapper is
/// the second line of defence: it keeps the rule true for any other code
/// that gets hold of a device's storage source.
final class PermissionGuardedStorageSource implements StorageSource {
  PermissionGuardedStorageSource(this._inner, this._permissions, this._required)
      : assert(_required.isNotEmpty);

  final StorageSource _inner;
  final PermissionService _permissions;
  final Set<ScanPermission> _required;

  /// Set by a listing that passed the permission check. Reads are refused
  /// until then, so item contents can't be reached without a checked listing.
  bool _verified = false;

  Future<void> _verify() async {
    final missing = <ScanPermission, PermissionState>{};
    for (final permission in _required) {
      final state = await _permissions.check(permission);
      if (!state.allowsAccess) missing[permission] = state;
    }
    _verified = missing.isEmpty;
    if (!_verified) throw PermissionDeniedException(missing);
  }

  void _requireVerified() {
    if (!_verified) {
      throw StateError('Storage was read before a permission-checked listing.');
    }
  }

  @override
  Stream<StorageItem> listItems({void Function(ScanIssue)? onIssue}) async* {
    await _verify();
    yield* _inner.listItems(onIssue: onIssue);
  }

  @override
  bool canReadContent(StorageItem item) => _inner.canReadContent(item);

  @override
  bool canDecodeThumbnail(StorageItem item) => _inner.canDecodeThumbnail(item);

  @override
  Future<Uint8List> readRange(StorageItem item, int start, int end) {
    _requireVerified();
    return _inner.readRange(item, start, end);
  }

  @override
  Stream<List<int>> openRead(StorageItem item) {
    _requireVerified();
    return _inner.openRead(item);
  }

  @override
  Future<Thumbnail?> loadThumbnail(StorageItem item, int size) {
    _requireVerified();
    return _inner.loadThumbnail(item, size);
  }
}
