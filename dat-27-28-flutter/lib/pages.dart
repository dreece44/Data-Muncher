import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import 'application/exclusion/exclusion_list.dart';
import 'application/garbage_bin/empty_bin.dart';
import 'core.dart';
import 'data/garbage_bin/bin_entry.dart';
import 'data/garbage_bin/munch_bin_store.dart';
import 'presentation/exclusion/do_not_collect_screen.dart';
import 'presentation/exclusion/do_not_collect_dialog.dart';
import 'presentation/garbage_bin/garbage_bin_screen.dart';

const green = Color(0xFF2E7D1E);
const darkGreen = Color(0xFF1B3D12);
const mono = TextStyle(fontFamily: 'Impact', color: Colors.white, fontSize: 16);

class Thumb extends StatelessWidget {
  final AssetEntity asset;
  final bool selected;
  final VoidCallback onTap;

  /// Marked "Do not collect" (DAT-32).
  final bool excluded;
  const Thumb(this.asset, this.selected, this.onTap, {this.excluded = false, super.key});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Stack(fit: StackFit.expand, children: [
          Image(
            image: AssetEntityImageProvider(asset, isOriginal: false, thumbnailSize: const ThumbnailSize.square(200)),
            fit: BoxFit.cover,
          ),
          if (asset.type == AssetType.video) const Positioned(left: 4, bottom: 4, child: Icon(Icons.videocam, size: 18)),
          if (excluded)
            const Positioned(
              right: 4,
              top: 4,
              child: Tooltip(message: 'Marked Do not collect', child: Icon(Icons.shield, size: 20)),
            ),
          if (selected) Container(color: green.withValues(alpha: 0.55), child: const Icon(Icons.check_circle, size: 32)),
        ]),
      );
}

/// Used by Duplicates / Empty / Blurry / Image Select / Video Select.
class ReviewPage extends StatefulWidget {
  final MunchState state;
  final String title;
  final List<AssetEntity> assets;
  final bool preselect;
  const ReviewPage(this.state, this.title, this.assets, {this.preselect = true, super.key});

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  ExclusionList get _exclusions => widget.state.exclusions;

  late final Set<String> sel = widget.preselect
      ? {for (final a in widget.assets) if (!_exclusions.isExcluded(a.id)) a.id}
      : {};

  Future<void> _munch() async {
    final chosen = widget.assets.where((a) => sel.contains(a.id)).toList();
    final excluded = chosen.where((a) => _exclusions.isExcluded(a.id)).length;
    if (excluded > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Collect anyway?'),
          content: Text(excluded == 1
              ? 'You marked 1 of these "Do not collect". Collecting it removes that mark.'
              : 'You marked $excluded of these "Do not collect". Collecting them removes that mark.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Collect anyway')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await widget.state.collect(chosen);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.title, style: mono), backgroundColor: Colors.transparent),
        body: widget.assets.isEmpty
            ? const Center(child: Text('NOTHING TO MUNCH', style: mono))
            : GridView.builder(
                padding: const EdgeInsets.all(4),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4),
                itemCount: widget.assets.length,
                itemBuilder: (_, i) {
                  final a = widget.assets[i];
                  return Thumb(
                    a,
                    sel.contains(a.id),
                    () => setState(() => sel.contains(a.id) ? sel.remove(a.id) : sel.add(a.id)),
                    excluded: _exclusions.isExcluded(a.id),
                  );
                },
              ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: darkGreen, padding: const EdgeInsets.all(16)),
              onPressed: sel.isEmpty ? null : _munch,
              child: Text('MUNCH ${sel.length} ITEMS', style: mono),
            ),
          ),
        ),
      );
}

/// Garbage Bin Viewer (DAT-27) wired to the app: File Recovery with optional
/// Collection Exclusion, single-file delete, and Garbage Bin Empty.
class BinPage extends StatefulWidget {
  final MunchState state;
  const BinPage(this.state, {super.key});
  @override
  State<BinPage> createState() => _BinPageState();
}

class _BinPageState extends State<BinPage> {
  late final MunchBinStore _store = MunchBinStore(widget.state);

  /// Whether this phone keeps deleted files in a trash; null until known.
  bool? _hasTrash;

  @override
  void initState() {
    super.initState();
    widget.state.systemTrashAvailable().then((value) {
      if (mounted) setState(() => _hasTrash = value);
    });
  }

  @override
  void dispose() {
    _store.dispose();
    super.dispose();
  }

  /// File Recovery with Collection Exclusion (DAT-32).
  Future<void> _recover(BinEntry entry) async {
    final doNotCollect = await showDoNotCollectDialog(
      context,
      title: 'Do not collect?',
      message: 'Stop DataMuncher from collecting ${entry.fileName} again for $exclusionPeriodLabel?',
      confirmLabel: 'Do not collect',
      declineLabel: 'Just recover',
    );
    await widget.state.recover(
      [entry.id],
      doNotCollect: doNotCollect,
      names: {entry.id: entry.fileName},
    );
  }

  /// Deletes through the phone's trash. If the phone has none, asks before
  /// deleting permanently; returns null if the user says no.
  Future<BinDeletion?> _deleteWithBackupCheck(List<String> ids, {bool alreadyWarned = false}) async {
    try {
      return await widget.state.deleteFromBin(ids, allowPermanent: alreadyWarned);
    } on NoSystemTrashException {
      if (!mounted) return null;
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Delete permanently?'),
          content: Text("This phone doesn't keep deleted photos and videos in a trash, so "
              "${ids.length == 1 ? 'this file' : 'these files'} can't be recovered afterwards."),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete permanently')),
          ],
        ),
      );
      if (ok != true) return null;
      return widget.state.deleteFromBin(ids, allowPermanent: true);
    }
  }

  Future<void> _delete(BinEntry entry) async {
    final result = await _deleteWithBackupCheck([entry.id]);
    // The user can say no here or refuse the phone's own delete prompt.
    if (result == null || !result.removedIds.contains(entry.id)) {
      throw StateError('${entry.id} was not deleted');
    }
  }

  /// Garbage Bin Empty (DAT-28).
  Future<EmptyBinOutcome> _empty() async {
    // When the phone is known to have no trash, the confirmation already
    // said so (see [_emptyBinNote]), so don't ask a second time.
    final result = await _deleteWithBackupCheck(
      widget.state.bin.toList(),
      alreadyWarned: _hasTrash == false,
    );
    if (result == null) return EmptyBinOutcome.nothingRemoved;
    return EmptyBinOutcome(
      removedIds: result.removedIds,
      restorableFor: result.restorable ? systemTrashRetention : null,
    );
  }

  String? get _emptyBinNote => switch (_hasTrash) {
        true => "They'll go to your phone's trash, where you can restore them for "
            '${systemTrashRetention.inDays} days.',
        false => "This phone has no trash for photos and videos, so they can't be recovered afterwards.",
        null => null,
      };

  Widget? _thumbnail(BinEntry entry) {
    final asset = _store.assetFor(entry.id);
    if (asset == null) return null;
    return Image(
      image: AssetEntityImageProvider(asset, isOriginal: false, thumbnailSize: const ThumbnailSize.square(200)),
      fit: BoxFit.cover,
    );
  }

  @override
  Widget build(BuildContext context) => GarbageBinScreen(
        store: _store,
        onRecover: _recover,
        onDelete: _delete,
        onEmptyBin: _empty,
        emptyBinNote: _emptyBinNote,
        thumbnailBuilder: _thumbnail,
      );
}

/// Do-not-collect list (DAT-32) with photo thumbnails and app icons.
class DoNotCollectPage extends StatelessWidget {
  final MunchState state;

  /// App icon for a package name, from the unused-apps feature (DAT-25).
  final Widget? Function(String packageName)? appIcon;
  const DoNotCollectPage(this.state, {this.appIcon, super.key});

  @override
  Widget build(BuildContext context) => DoNotCollectScreen(
        exclusions: state.exclusions,
        thumbnailBuilder: (entry) => switch (entry.kind) {
          ExcludedKind.app => appIcon?.call(entry.id),
          ExcludedKind.file => _AssetThumb(entry.id),
        },
      );
}

/// Thumbnail for a photo library id, or a plain icon if it's gone.
class _AssetThumb extends StatefulWidget {
  final String id;
  const _AssetThumb(this.id);

  @override
  State<_AssetThumb> createState() => _AssetThumbState();
}

class _AssetThumbState extends State<_AssetThumb> {
  late final Future<AssetEntity?> _asset = AssetEntity.fromId(widget.id);

  @override
  Widget build(BuildContext context) => FutureBuilder<AssetEntity?>(
        future: _asset,
        builder: (_, snap) {
          final asset = snap.data;
          if (asset == null) return const ColoredBox(color: Color(0xFF222222), child: Icon(Icons.photo_outlined));
          return Image(
            image: AssetEntityImageProvider(asset, isOriginal: false, thumbnailSize: const ThumbnailSize.square(120)),
            fit: BoxFit.cover,
          );
        },
      );
}
