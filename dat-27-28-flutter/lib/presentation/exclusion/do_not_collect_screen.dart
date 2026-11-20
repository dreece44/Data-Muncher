import 'package:flutter/material.dart';

import '../../application/exclusion/exclusion_list.dart';
import '../garbage_bin/format.dart';

/// "Do not collect" list (DAT-32): everything scans are skipping, until
/// when, and a way to let a file or app be picked up again.
class DoNotCollectScreen extends StatefulWidget {
  const DoNotCollectScreen({
    super.key,
    required this.exclusions,
    this.thumbnailBuilder,
  });

  final ExclusionList exclusions;

  /// Picture for an entry (photo thumbnail, app icon). Null falls back to
  /// an icon.
  final Widget? Function(Exclusion entry)? thumbnailBuilder;

  @override
  State<DoNotCollectScreen> createState() => _DoNotCollectScreenState();
}

/// "Until Nov 30, 2026 · 30 days left". ("Always" only for an entry saved
/// without an end date, which the app no longer creates.)
String describeExclusionEnd(Exclusion entry, DateTime now) {
  final until = entry.until;
  if (until == null) return 'Always';
  final days = calendarDaysBetween(now, until);
  final left = days <= 0
      ? 'ends today'
      : days == 1
          ? '1 day left'
          : '$days days left';
  return 'Until ${formatDate(until)} · $left';
}

class _DoNotCollectScreenState extends State<DoNotCollectScreen> {
  @override
  void initState() {
    super.initState();
    // After the first frame, so listeners (the home screen) don't rebuild
    // during this route's build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.exclusions.purgeExpired();
    });
  }

  Future<void> _allow(Exclusion entry) async {
    final messenger = ScaffoldMessenger.of(context);
    await widget.exclusions.remove(entry.id, kind: entry.kind);
    final what = entry.kind == ExcludedKind.app
        ? 'suggested for removal'
        : 'collected';
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text('${entry.displayName} can be $what again '
          'from the next scan.'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => widget.exclusions.restore(entry),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Do not collect')),
      body: ListenableBuilder(
        listenable: widget.exclusions,
        builder: (context, _) {
          final entries = widget.exclusions.active;
          final now = widget.exclusions.now();
          if (entries.isEmpty) {
            return const _EmptyView();
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  'Scans skip these until the date shown: files you '
                  'recovered and marked "Do not collect", and apps you '
                  'chose to keep.',
                ),
              ),
              for (final entry in entries)
                _ExclusionTile(
                  key: ValueKey(entry.key),
                  entry: entry,
                  now: now,
                  thumbnail: widget.thumbnailBuilder?.call(entry),
                  onAllow: () => _allow(entry),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ExclusionTile extends StatelessWidget {
  const _ExclusionTile({
    super.key,
    required this.entry,
    required this.now,
    required this.onAllow,
    this.thumbnail,
  });

  final Exclusion entry;
  final DateTime now;
  final VoidCallback onAllow;
  final Widget? thumbnail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final thumbnail = this.thumbnail;
    return ListTile(
      leading: thumbnail != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(width: 48, height: 48, child: thumbnail),
            )
          : CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              foregroundColor: scheme.onPrimaryContainer,
              child: Icon(entry.kind == ExcludedKind.app
                  ? Icons.apps
                  : Icons.photo_outlined),
            ),
      title: Text(entry.displayName,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${entry.kind == ExcludedKind.app ? 'Kept app' : 'Recovered file'}'
        ' · ${describeExclusionEnd(entry, now)}',
      ),
      trailing: TextButton(
        onPressed: onAllow,
        child: Text('Allow', semanticsLabel: 'Allow ${entry.displayName}'),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_outlined,
                size: 56, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('Nothing is excluded',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'When you recover a file from the Garbage Bin or keep an '
              'unused app, you can stop DataMuncher from suggesting it '
              'again. Those choices show up here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
