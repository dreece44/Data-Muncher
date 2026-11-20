import 'package:flutter/material.dart';

import '../../application/apps/unused_apps.dart';
import '../../application/apps/unused_apps_controller.dart';
import '../exclusion/do_not_collect_dialog.dart';
import '../garbage_bin/format.dart';
import 'app_icon.dart';

/// PB-10 / DAT-25: installed apps the user hasn't opened in a long time,
/// with Uninstall and Keep.
class UnusedAppsScreen extends StatefulWidget {
  const UnusedAppsScreen({
    super.key,
    required this.controller,
    required this.icons,
    this.onOpenDoNotCollect,
  });

  /// Owned by the caller, so the home screen's count stays in step.
  final UnusedAppsController controller;
  final AppIconCache icons;

  /// Opens the Do-not-collect list (DAT-32).
  final VoidCallback? onOpenDoNotCollect;

  @override
  State<UnusedAppsScreen> createState() => _UnusedAppsScreenState();
}

enum _AppChoice { uninstall, keep }

class _UnusedAppsScreenState extends State<UnusedAppsScreen>
    with WidgetsBindingObserver {
  UnusedAppsController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // After the first frame: the home screen listens to this controller and
    // must not be asked to rebuild while this route is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _c.load();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from Settings (Usage access) or from somewhere apps were removed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _c.onResumed();
  }

  Future<void> _open(UnusedApp app) async {
    final choice = await showModalBottomSheet<_AppChoice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) =>
          _AppDetailsSheet(app: app, icons: widget.icons),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case _AppChoice.uninstall:
        await _uninstall(app);
      case _AppChoice.keep:
        await _keep(app);
    }
  }

  Future<void> _uninstall(UnusedApp app) async {
    final messenger = ScaffoldMessenger.of(context);
    String message;
    try {
      final gone = await _c.uninstall(app);
      message = gone
          ? 'Uninstalled ${app.app.label} and freed '
              '${formatBytes(app.app.sizeBytes)}.'
          : "${app.app.label} wasn't uninstalled.";
    } catch (e) {
      debugPrint('Uninstall failed: $e');
      message = "Couldn't uninstall ${app.app.label}.";
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _keep(UnusedApp app) async {
    final keep = await showDoNotCollectDialog(
      context,
      title: 'Keep ${app.app.label}?',
      message: "DataMuncher won't suggest removing it again for "
          '$exclusionPeriodLabel.',
      confirmLabel: 'Keep',
    );
    if (!mounted || !keep) return;
    final messenger = ScaffoldMessenger.of(context);
    final entry = await _c.keep(app);
    final until = entry.until;
    messenger.showSnackBar(SnackBar(
      content: Text(until == null
          ? "${app.app.label} won't be suggested again."
          : "${app.app.label} won't be suggested until ${formatDate(until)}."),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Unused apps'),
          actions: [
            if (widget.onOpenDoNotCollect != null)
              IconButton(
                tooltip: 'Do-not-collect list',
                icon: const Icon(Icons.shield_outlined),
                onPressed: widget.onOpenDoNotCollect,
              ),
          ],
        ),
        body: switch (_c.status) {
          UnusedAppsStatus.loading => const Center(
              child: CircularProgressIndicator(
                  semanticsLabel: 'Checking your apps')),
          UnusedAppsStatus.unsupported => const _MessageView(
              icon: Icons.phone_iphone,
              title: 'Not available on iPhone',
              message: "iOS doesn't let apps see which other apps are "
                  'installed or how often they are used. To find unused '
                  'apps, open Settings → General → iPhone Storage, or turn '
                  'on "Offload Unused Apps" there.',
            ),
          UnusedAppsStatus.needsAccess => _MessageView(
              icon: Icons.query_stats,
              title: 'Allow usage access',
              message: 'Android needs your permission before DataMuncher can '
                  'see when you last opened each app. DataMuncher only '
                  'reads when apps were last used; nothing leaves your '
                  'phone.\n\nFind DataMuncher in the list, turn on '
                  '"Permit usage access", then come back.',
              action: FilledButton.icon(
                onPressed: _c.openUsageAccessSettings,
                icon: const Icon(Icons.settings),
                label: const Text('Open settings'),
              ),
            ),
          UnusedAppsStatus.failed => _MessageView(
              icon: Icons.error_outline,
              title: "Couldn't check your apps",
              message: _c.error ?? 'Please try again.',
              action: FilledButton.icon(
                onPressed: _c.load,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ),
          UnusedAppsStatus.ready => _buildList(context),
        },
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    final days = _c.rules.unusedAfter.inDays;
    if (_c.unused.isEmpty) {
      return RefreshIndicator(
        onRefresh: _c.load,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: _MessageView(
                icon: Icons.check_circle_outline,
                title: 'No unused apps',
                message: "You've opened every app you installed in the "
                    'last $days days.',
              ),
            ),
          ],
        ),
      );
    }

    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _c.load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${pluralize(_c.unused.length, 'unused app')} · '
                      '${formatBytes(_c.totalBytes)}',
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Apps you haven't opened in $days days. Android asks "
                      'you to confirm each uninstall.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
          ),
          for (final app in _c.unused)
            ListTile(
              key: ValueKey(app.app.packageName),
              onTap: _c.isUninstalling(app.app.packageName)
                  ? null
                  : () => _open(app),
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: AppIcon(
                      packageName: app.app.packageName, cache: widget.icons),
                ),
              ),
              title: Text(app.app.label,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${app.reason} · ${formatBytes(app.app.sizeBytes)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: _c.isUninstalling(app.app.packageName)
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right),
            ),
        ],
      ),
    );
  }
}

class _AppDetailsSheet extends StatelessWidget {
  const _AppDetailsSheet({required this.app, required this.icons});

  final UnusedApp app;
  final AppIconCache icons;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final installed = app.app.installedAt;
    final lastUsed = app.app.lastUsedAt;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: AppIcon(packageName: app.app.packageName, cache: icons),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(app.app.label, style: theme.textTheme.titleLarge),
              ),
            ]),
            const SizedBox(height: 16),
            _Detail('Why it was flagged', app.reason),
            _Detail('Last opened',
                lastUsed == null ? 'No record of it being opened' : formatDate(lastUsed)),
            if (installed != null) _Detail('Installed', formatDate(installed)),
            _Detail('Space it uses', formatBytes(app.app.sizeBytes)),
            _Detail('Package', app.app.packageName),
            const SizedBox(height: 24),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(_AppChoice.uninstall),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Uninstall'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).pop(_AppChoice.keep),
                  icon: const Icon(Icons.shield_outlined),
                  label: const Text('Keep'),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail(this.label, this.value);

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
          Text(label,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          Text(value, style: theme.textTheme.bodyLarge),
        ],
      ),
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
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            if (action != null) ...[const SizedBox(height: 24), action],
          ],
        ),
      ),
    );
  }
}
