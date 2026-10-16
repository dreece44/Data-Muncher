import 'package:flutter/material.dart';

import '../../application/garbage_bin/bin_query.dart';
import '../../data/garbage_bin/bin_entry.dart';
import 'format.dart';

IconData iconForCategory(FileCategory category) => switch (category) {
      FileCategory.photo => Icons.photo_outlined,
      FileCategory.video => Icons.videocam_outlined,
      FileCategory.document => Icons.description_outlined,
      FileCategory.audio => Icons.music_note_outlined,
      FileCategory.app => Icons.apps,
      FileCategory.other => Icons.insert_drive_file_outlined,
    };

/// One row in the Garbage Bin list.
///
/// Shows the name, why it was collected, its size, when it went into the bin
/// and where it came from, plus a warning when it is about to leave the bin.
class BinEntryTile extends StatelessWidget {
  const BinEntryTile({
    super.key,
    required this.entry,
    required this.now,
    this.onTap,
    this.thumbnail,
  });

  final BinEntry entry;
  final DateTime now;
  final VoidCallback? onTap;

  /// Shown instead of the type icon when given (e.g. a photo thumbnail).
  final Widget? thumbnail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final expiresAt = entry.expiresAt;
    final String? timeLeft =
        (expiresAt != null && !expiresAt.isAfter(now.add(expiringSoonWindow)))
            ? formatTimeLeft(expiresAt, now)
            : null;
    final folder = entry.originalFolder.isEmpty
        ? entry.originalPath
        : entry.originalFolder;
    final details = [
      entry.reason.label,
      formatBytes(entry.originalSizeBytes),
      formatCollectedAt(entry.collectedAt, now),
    ].join(' · ');

    final thumbnail = this.thumbnail;
    return ListTile(
      onTap: onTap,
      isThreeLine: true,
      leading: thumbnail != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(width: 56, height: 56, child: thumbnail),
            )
          : CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              foregroundColor: scheme.onPrimaryContainer,
              child: Icon(iconForCategory(entry.category)),
            ),
      title: Text(
        entry.fileName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text('From $folder', maxLines: 1, overflow: TextOverflow.ellipsis),
          if (timeLeft != null)
            Text(timeLeft, style: TextStyle(color: scheme.error)),
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
    );
  }
}
