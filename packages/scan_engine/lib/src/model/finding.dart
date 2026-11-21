import 'storage_item.dart';
import 'waste_category.dart';

/// One piece of wasted space the scan found: a single item (an empty file,
/// an unused app) or a group (a set of duplicate photos).
final class Finding {
  Finding({
    required this.category,
    required this.items,
    required this.reason,
    this.keep,
  }) : assert(keep == null || items.contains(keep));

  final WasteCategory category;

  /// Everything involved. For duplicate groups this includes [keep].
  final List<Reclaimable> items;

  /// For groups: the copy the engine suggests keeping. Null when every item
  /// is suggested for removal.
  final Reclaimable? keep;

  /// Plain-language explanation shown to the user.
  final String reason;

  /// Items suggested for removal (everything except [keep]).
  List<Reclaimable> get removable => keep == null
      ? items
      : [
          for (final i in items)
            if (i.id != keep!.id) i
        ];

  int get reclaimableBytes =>
      removable.fold(0, (sum, item) => sum + item.sizeBytes);

  Map<String, Object?> toJson() => {
        'category': category.name,
        'reason': reason,
        'reclaimableBytes': reclaimableBytes,
        if (keep != null) 'keep': keep!.id,
        'items': [for (final i in items) i.toJson()],
      };
}
