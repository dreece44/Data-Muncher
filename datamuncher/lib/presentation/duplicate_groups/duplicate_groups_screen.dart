import 'package:flutter/material.dart';

import '../../application/duplicate_groups/best_copy.dart';
import '../../pages.dart' show darkGreen, green, mono;

/// What to do with the copies the user doesn't keep.
enum DuplicateRemoval {
  /// Move them to the Garbage Bin, where they can be recovered.
  bin,

  /// Delete them now (through the phone's trash where it has one).
  delete,
}

/// DAT-34 (PB-21): duplicates grouped, the best copy of each picked to keep,
/// and the rest removed in one action.
///
/// Each group starts with its suggested copy (clearest, most centred) marked
/// KEEP and every other copy marked for removal. Tapping another photo keeps
/// that one instead; unticking a group leaves it alone.
class DuplicateGroupsScreen extends StatefulWidget {
  const DuplicateGroupsScreen({
    required this.groups,
    required this.thumbnailBuilder,
    required this.onRemove,
    super.key,
  });

  final List<DuplicateGroup> groups;

  /// Thumbnail for a photo or video id.
  final Widget Function(String id) thumbnailBuilder;

  /// Removes [ids]; returns the message to show once done.
  final Future<String> Function(List<String> ids, DuplicateRemoval how) onRemove;

  @override
  State<DuplicateGroupsScreen> createState() => _DuplicateGroupsScreenState();
}

class _DuplicateGroupsScreenState extends State<DuplicateGroupsScreen> {
  /// Group index -> id of the copy being kept.
  late final Map<int, String> _keep = {
    for (var i = 0; i < widget.groups.length; i++) i: widget.groups[i].bestId,
  };

  /// Groups the user unticked.
  final Set<int> _skipped = {};

  bool _busy = false;

  List<String> get _toRemove => [
        for (var i = 0; i < widget.groups.length; i++)
          if (!_skipped.contains(i))
            for (final id in widget.groups[i].ids)
              if (id != _keep[i]) id,
      ];

  Future<void> _remove() async {
    final ids = _toRemove;
    final n = ids.length;
    final how = await showDialog<DuplicateRemoval>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove $n duplicate${n == 1 ? '' : 's'}?'),
        content: const Text('The copy marked KEEP in each group stays. Move the rest to the Garbage Bin, '
            'where you can recover them, or delete them now?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(
            key: const ValueKey('remove-delete'),
            onPressed: () => Navigator.pop(c, DuplicateRemoval.delete),
            child: const Text('Delete now'),
          ),
          TextButton(
            key: const ValueKey('remove-bin'),
            onPressed: () => Navigator.pop(c, DuplicateRemoval.bin),
            child: const Text('Garbage Bin'),
          ),
        ],
      ),
    );
    if (how == null || !mounted) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final message = await widget.onRemove(ids, how);
    messenger.showSnackBar(SnackBar(content: Text(message)));
    if (mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final count = _toRemove.length;
    return Scaffold(
      appBar: AppBar(title: const Text('DUPLICATES', style: mono), backgroundColor: Colors.transparent),
      body: widget.groups.isEmpty
          ? const Center(child: Text('NO DUPLICATES', style: mono))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: widget.groups.length,
              itemBuilder: (_, i) => _groupCard(i),
            ),
      bottomNavigationBar: widget.groups.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  key: const ValueKey('remove-duplicates'),
                  style: FilledButton.styleFrom(backgroundColor: darkGreen, padding: const EdgeInsets.all(16)),
                  onPressed: count == 0 || _busy ? null : _remove,
                  child: _busy
                      ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text('REMOVE $count DUPLICATE${count == 1 ? '' : 'S'}', style: mono),
                ),
              ),
            ),
    );
  }

  Widget _groupCard(int i) {
    final group = widget.groups[i];
    final included = !_skipped.contains(i);
    final keep = _keep[i]!;
    final chosen = keep == group.bestId;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 12, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Checkbox(
              key: ValueKey('group-$i'),
              value: included,
              activeColor: green,
              onChanged: (v) => setState(() => v == true ? _skipped.remove(i) : _skipped.add(i)),
            ),
            Expanded(
              child: Text(
                included
                    ? '${group.members.length} copies · keep 1, remove ${group.members.length - 1}'
                    : '${group.members.length} copies · leaving these alone',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: SizedBox(
              height: 112,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: group.members.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, k) {
                  final id = group.members[k].id;
                  return _tile(id, kept: id == keep, best: id == group.bestId, removing: included && id != keep,
                      onTap: () => setState(() {
                            _keep[i] = id;
                            _skipped.remove(i);
                          }));
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 8),
            child: Text(
              chosen
                  ? 'Suggested: ${group.reason}. Tap another photo to keep it instead.'
                  : 'You picked a different copy. The suggested one (BEST) was ${group.reason}.',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _tile(String id,
          {required bool kept, required bool best, required bool removing, required VoidCallback onTap}) =>
      GestureDetector(
        key: ValueKey('copy-$id'),
        onTap: onTap,
        child: Container(
          width: 112,
          decoration: BoxDecoration(border: Border.all(color: kept ? green : Colors.transparent, width: 3)),
          child: Stack(fit: StackFit.expand, children: [
            widget.thumbnailBuilder(id),
            if (removing)
              Container(
                color: Colors.black.withValues(alpha: 0.55),
                child: const Icon(Icons.delete_outline, size: 32, color: Colors.white70),
              ),
            if (kept) const Positioned(left: 0, top: 0, child: _Badge('KEEP', green)),
            if (best) const Positioned(right: 0, bottom: 0, child: _Badge('★ BEST', Colors.amber, dark: true)),
          ]),
        ),
      );
}

class _Badge extends StatelessWidget {
  const _Badge(this.label, this.color, {this.dark = false});

  final String label;
  final Color color;
  final bool dark;

  @override
  Widget build(BuildContext context) => Container(
        color: color,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: dark ? Colors.black : Colors.white)),
      );
}
