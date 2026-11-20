import 'package:flutter/material.dart';

import '../../data/garbage_bin/bin_entry.dart';
import 'bin_entry_tile.dart';
import 'format.dart';

/// Something another feature does to a file in the bin, such as File
/// Recovery. The viewer only offers the button and refreshes afterwards.
typedef BinEntryAction = Future<void> Function(BinEntry entry);

/// What the user picked in the details sheet.
enum BinEntryChoice { recover, delete }

/// Shows everything known about [entry] so the user can decide whether it
/// really should go. Returns the action they picked, or null if they closed
/// the sheet.
Future<BinEntryChoice?> showBinEntryDetails(
  BuildContext context, {
  required BinEntry entry,
  required DateTime now,
  bool canRecover = false,
  bool canDelete = false,
  Widget? preview,
}) {
  return showModalBottomSheet<BinEntryChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => BinEntryDetailsSheet(
      entry: entry,
      now: now,
      canRecover: canRecover,
      canDelete: canDelete,
      preview: preview,
    ),
  );
}

class BinEntryDetailsSheet extends StatelessWidget {
  const BinEntryDetailsSheet({
    super.key,
    required this.entry,
    required this.now,
    this.canRecover = false,
    this.canDelete = false,
    this.preview,
  });

  final BinEntry entry;
  final DateTime now;
  final bool canRecover;
  final bool canDelete;

  /// Optional picture of the file (e.g. a photo thumbnail).
  final Widget? preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expiresAt = entry.expiresAt;
    final storedSize = formatBytes(entry.storedSizeBytes);
    final preview = this.preview;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (preview != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(height: 200, child: preview),
              ),
              const SizedBox(height: 16),
            ],
            Row(
              children: [
                Icon(
                  iconForCategory(entry.category),
                  size: 32,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(entry.fileName, style: theme.textTheme.titleLarge),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _DetailRow(label: 'Original location', value: entry.originalPath),
            _DetailRow(label: 'Type', value: entry.category.singularLabel),
            _DetailRow(label: 'Why it was collected', value: entry.reason.label),
            _DetailRow(
              label: 'Sent to the bin',
              value: formatDate(entry.collectedAt),
            ),
            _DetailRow(
              label: 'Size',
              value: formatBytes(entry.originalSizeBytes),
            ),
            _DetailRow(
              label: 'Space used in the bin',
              value: entry.isCompressed
                  ? '$storedSize (compressed)'
                  : '$storedSize (not compressed)',
            ),
            _DetailRow(
              label: 'Leaves the bin',
              value: expiresAt == null
                  ? 'No time limit set'
                  : '${formatDate(expiresAt)} '
                      '(${formatTimeLeft(expiresAt, now).toLowerCase()})',
            ),
            if (canRecover || canDelete) ...[
              const SizedBox(height: 24),
              Row(
                children: [
                  if (canRecover)
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () =>
                            Navigator.of(context).pop(BinEntryChoice.recover),
                        icon: const Icon(Icons.restore),
                        label: const Text('Recover'),
                      ),
                    ),
                  if (canRecover && canDelete) const SizedBox(width: 12),
                  if (canDelete)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            Navigator.of(context).pop(BinEntryChoice.delete),
                        icon: const Icon(Icons.delete_forever_outlined),
                        label: const Text('Delete'),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          Text(value, style: theme.textTheme.bodyLarge),
        ],
      ),
    );
  }
}
