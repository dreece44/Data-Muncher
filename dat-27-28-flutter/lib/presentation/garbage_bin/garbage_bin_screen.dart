import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/garbage_bin/bin_query.dart';
import '../../application/garbage_bin/empty_bin.dart';
import '../../application/garbage_bin/garbage_bin_viewer_controller.dart';
import '../../data/garbage_bin/bin_entry.dart';
import '../../data/garbage_bin/garbage_bin_store.dart';
import 'bin_entry_details_sheet.dart';
import 'bin_entry_tile.dart';
import 'format.dart';

/// PB-13 Garbage Bin Viewer: lists everything in the Garbage Bin so the user
/// can check it before anything is permanently removed.
///
/// Open it from the main menu with the app's [GarbageBinStore]. [onRecover]
/// and [onDelete] are supplied by the File Recovery and deletion features;
/// while they are null their buttons are hidden and the viewer is read-only.
class GarbageBinScreen extends StatefulWidget {
  const GarbageBinScreen({
    super.key,
    required this.store,
    this.onRecover,
    this.onDelete,
    this.onEmptyBin,
    this.emptyBinNote,
    this.thumbnailBuilder,
    this.clock,
  });

  /// Where the bin's contents come from. Read when the screen opens.
  final GarbageBinStore store;

  /// Restores a file to its original location (File Recovery).
  final BinEntryAction? onRecover;

  /// Deletes one file from the bin now. The user confirms first.
  final BinEntryAction? onDelete;

  /// Garbage Bin Empty (DAT-28): removes everything in the bin and reports
  /// which files left. Shown as an app bar button when set; the user confirms
  /// first. Throw if it fails.
  final Future<EmptyBinOutcome> Function()? onEmptyBin;

  /// Extra sentence for the Empty Bin confirmation, e.g. where the files go.
  final String? emptyBinNote;

  /// Picture for a file (e.g. a photo thumbnail). Return null to fall back to
  /// the type icon.
  final Widget? Function(BinEntry entry)? thumbnailBuilder;

  /// Overrides "now"; for tests.
  final DateTime Function()? clock;

  @override
  State<GarbageBinScreen> createState() => _GarbageBinScreenState();
}

class _GarbageBinScreenState extends State<GarbageBinScreen> {
  late final GarbageBinViewerController _controller;
  final TextEditingController _searchField = TextEditingController();
  bool _emptying = false;

  @override
  void initState() {
    super.initState();
    _controller = GarbageBinViewerController(
      store: widget.store,
      clock: widget.clock,
    );
    unawaited(_controller.load());
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchField.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _searchField.clear();
    _controller.setSearchText('');
  }

  void _clearFilters() {
    _searchField.clear();
    _controller.clearFilters();
  }

  Future<void> _openDetails(BinEntry entry) async {
    final onRecover = widget.onRecover;
    final onDelete = widget.onDelete;
    final choice = await showBinEntryDetails(
      context,
      entry: entry,
      now: _controller.now(),
      canRecover: onRecover != null,
      canDelete: onDelete != null,
      preview: widget.thumbnailBuilder?.call(entry),
    );
    if (!mounted || choice == null) return;

    switch (choice) {
      case BinEntryChoice.recover:
        if (onRecover == null) return;
        await _runAction(
          () => onRecover(entry),
          success: 'Recovered ${entry.fileName}',
          failure: "Couldn't recover ${entry.fileName}. It's still in the bin.",
        );
      case BinEntryChoice.delete:
        if (onDelete == null) return;
        final confirmed = await _confirmDelete(entry);
        if (!mounted || !confirmed) return;
        await _runAction(
          () => onDelete(entry),
          success: 'Deleted ${entry.fileName}',
          failure: "Couldn't delete ${entry.fileName}. It's still in the bin.",
        );
    }
  }

  Future<bool> _confirmDelete(BinEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this file now?'),
        content: Text(
          '“${entry.fileName}” will be deleted from the Garbage Bin '
          'instead of waiting for its time to run out.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _emptyBin() async {
    final onEmptyBin = widget.onEmptyBin;
    if (onEmptyBin == null || _emptying) return;
    final summary = _controller.summary;
    final note = widget.emptyBinNote;
    final hidden = _controller.query.isFiltering
        ? ' This includes files hidden by your search or filter.'
        : '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Empty the Garbage Bin?'),
        content: Text(
          'All ${pluralize(summary.itemCount, 'file')} '
          '(${formatBytes(summary.totalOriginalBytes)}) will be deleted '
          'from your device.$hidden${note == null ? '' : ' $note'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Empty bin'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    // What the user agreed to, so the report matches what they saw.
    final before = _controller.allEntries;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _emptying = true);
    String message;
    try {
      final outcome = await onEmptyBin();
      message = describeEmptyBin(EmptyBinReport.of(before, outcome));
    } catch (error) {
      debugPrint('Emptying the Garbage Bin failed: $error');
      message = "Couldn't empty the Garbage Bin.";
    }
    if (mounted) setState(() => _emptying = false);
    messenger.showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 6),
    ));
    if (mounted) await _controller.load();
  }

  Future<void> _runAction(
    Future<void> Function() action, {
    required String success,
    required String failure,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    String message;
    try {
      await action();
      message = success;
    } catch (error) {
      debugPrint('Garbage Bin action failed: $error');
      message = failure;
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
    if (mounted) await _controller.load();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final controller = _controller;
        final hasFiles = controller.status == BinLoadStatus.ready &&
            controller.allEntries.isNotEmpty;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Garbage Bin'),
            bottom: _emptying
                ? const PreferredSize(
                    preferredSize: Size.fromHeight(4),
                    child: LinearProgressIndicator(),
                  )
                : null,
            actions: [
              if (hasFiles)
                _SortButton(
                  selected: controller.query.sort,
                  onSelected: controller.setSort,
                ),
              if (hasFiles && widget.onEmptyBin != null)
                IconButton(
                  tooltip: 'Empty Garbage Bin',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: _emptying ? null : _emptyBin,
                ),
            ],
          ),
          body: switch (controller.status) {
            BinLoadStatus.loading => const Center(
                child: CircularProgressIndicator(
                  semanticsLabel: 'Opening the Garbage Bin',
                ),
              ),
            BinLoadStatus.failed => _MessageView(
                icon: Icons.error_outline,
                title: "Couldn't open the Garbage Bin",
                message: 'Nothing in the bin has been changed. '
                    'Please try again.',
                action: FilledButton.icon(
                  onPressed: controller.load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ),
            BinLoadStatus.ready => _buildContents(context),
          },
        );
      },
    );
  }

  Widget _buildContents(BuildContext context) {
    final controller = _controller;

    if (controller.allEntries.isEmpty) {
      return RefreshIndicator(
        onRefresh: controller.load,
        child: const CustomScrollView(
          physics: AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: _MessageView(
                icon: Icons.delete_outline,
                title: 'Your Garbage Bin is empty',
                message: 'Files you send here after a scan will show up in '
                    "this list, so you can check them before they're removed.",
              ),
            ),
          ],
        ),
      );
    }

    final now = controller.now();
    final visible = controller.visibleEntries;
    return RefreshIndicator(
      onRefresh: controller.load,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _buildHeader(context)),
          if (visible.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _MessageView(
                icon: Icons.search_off,
                title: 'No files match',
                message: 'Try a different search or category.',
                action: TextButton(
                  onPressed: _clearFilters,
                  child: const Text('Clear search and filters'),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.only(bottom: 24),
              sliver: SliverList.builder(
                itemCount: visible.length,
                itemBuilder: (context, index) {
                  final entry = visible[index];
                  return BinEntryTile(
                    key: ValueKey(entry.id),
                    entry: entry,
                    now: now,
                    thumbnail: widget.thumbnailBuilder?.call(entry),
                    onTap: () => _openDetails(entry),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final controller = _controller;
    final summary = controller.summary;
    final query = controller.query;
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.refreshFailed) ...[
            _RefreshFailedBanner(onRetry: controller.load),
            const SizedBox(height: 12),
          ],
          _SummaryCard(summary: summary),
          const SizedBox(height: 12),
          TextField(
            controller: _searchField,
            onChanged: controller.setSearchText,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search by name, folder or reason',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: query.searchText.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.clear),
                      onPressed: _clearSearch,
                    ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: Text('All (${summary.itemCount})'),
                  selected: query.category == null,
                  onSelected: (_) => controller.setCategory(null),
                ),
                for (final category in FileCategory.values)
                  if (summary.countFor(category) > 0) ...[
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text(
                        '${category.pluralLabel} '
                        '(${summary.countFor(category)})',
                      ),
                      selected: query.category == category,
                      onSelected: (selected) =>
                          controller.setCategory(selected ? category : null),
                    ),
                  ],
              ],
            ),
          ),
          if (query.isFiltering)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Showing ${controller.visibleEntries.length} '
                'of ${summary.itemCount}',
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final BinSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final saved = summary.bytesSavedByCompression;
    final stored = formatBytes(summary.totalStoredBytes);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${pluralize(summary.itemCount, 'file')} · '
              '${formatBytes(summary.totalOriginalBytes)}',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              saved > 0
                  ? 'Compressed to $stored while in the bin '
                      '(saving ${formatBytes(saved)})'
                  : 'Using $stored while in the bin',
              style: theme.textTheme.bodyMedium,
            ),
            if (summary.expiringSoonCount > 0) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.schedule, size: 18, color: theme.colorScheme.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${pluralize(summary.expiringSoonCount, 'file')} '
                      'will be removed from the bin within '
                      '${expiringSoonWindow.inDays} days',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.error),
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

class _RefreshFailedBanner extends StatelessWidget {
  const _RefreshFailedBanner({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                "Couldn't refresh. This list may be out of date.",
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _SortButton extends StatelessWidget {
  const _SortButton({required this.selected, required this.onSelected});

  final BinSort selected;
  final ValueChanged<BinSort> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<BinSort>(
      icon: const Icon(Icons.sort),
      tooltip: 'Sort: ${selected.label}',
      initialValue: selected,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final sort in BinSort.values)
          CheckedPopupMenuItem<BinSort>(
            value: sort,
            checked: sort == selected,
            child: Text(sort.label),
          ),
      ],
    );
  }
}

class _MessageView extends StatelessWidget {
  const _MessageView({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final action = this.action;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (action != null) ...[
              const SizedBox(height: 24),
              action,
            ],
          ],
        ),
      ),
    );
  }
}
