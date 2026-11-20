import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../../core.dart';
import '../../data/garbage_bin/bin_entry.dart';
import 'duplicate_groups_screen.dart';

/// [DuplicateGroupsScreen] wired to the app: thumbnails from the photo
/// library, removal through the Garbage Bin and the phone's trash.
class DuplicateGroupsPage extends StatefulWidget {
  const DuplicateGroupsPage(this.state, {super.key});

  final MunchState state;

  @override
  State<DuplicateGroupsPage> createState() => _DuplicateGroupsPageState();
}

class _DuplicateGroupsPageState extends State<DuplicateGroupsPage> {
  MunchState get s => widget.state;

  late final Map<String, AssetEntity> _assets = {for (final a in s.all) a.id: a};

  // Fixed while the page is open; removing closes it.
  late final groups = List.of(s.duplicateGroups);

  Widget _thumbnail(String id) {
    final asset = _assets[id];
    if (asset == null) return const Icon(Icons.image_not_supported_outlined);
    return Image(
      image: AssetEntityImageProvider(asset, isOriginal: false, thumbnailSize: const ThumbnailSize.square(240)),
      fit: BoxFit.cover,
    );
  }

  Future<String> _remove(List<String> ids, DuplicateRemoval how) async {
    final assets = [
      for (final id in ids)
        if (_assets[id] case final a?) a
    ];
    final n = assets.length;
    String count(int k) => '$k duplicate${k == 1 ? '' : 's'}';

    // Always through the bin first, so anything the phone refuses to delete
    // stays recoverable there rather than being lost track of.
    await s.collect(assets, reason: CollectionReason.duplicate);
    if (how == DuplicateRemoval.bin) return 'Moved ${count(n)} to the Garbage Bin.';

    final binIds = [for (final a in assets) a.id];
    BinDeletion result;
    try {
      result = await s.deleteFromBin(binIds);
    } on NoSystemTrashException {
      if (!mounted) return 'Moved ${count(n)} to the Garbage Bin.';
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Delete permanently?'),
          content: const Text("This phone doesn't keep deleted photos in a trash, so these duplicates "
              "can't be recovered afterwards."),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep in bin')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete permanently')),
          ],
        ),
      );
      if (ok != true) return 'Moved ${count(n)} to the Garbage Bin. Nothing was deleted.';
      result = await s.deleteFromBin(binIds, allowPermanent: true);
    }
    final deleted = result.removedIds.length;
    final where = result.restorable
        ? " (in your phone's trash for ${systemTrashRetention.inDays} days)"
        : '';
    if (deleted == n) return 'Deleted ${count(n)}$where.';
    return 'Deleted $deleted of $n$where. The rest are in the Garbage Bin.';
  }

  @override
  Widget build(BuildContext context) =>
      DuplicateGroupsScreen(groups: groups, thumbnailBuilder: _thumbnail, onRemove: _remove);
}
