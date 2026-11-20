import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../application/monetization/monetization_controller.dart';

/// Free with ads (DAT-38) vs the optional ad-free subscription (DAT-39).
///
/// Both plans include every feature; the only difference is ads.
class PlansScreen extends StatefulWidget {
  const PlansScreen({super.key, required this.monetization, this.platform});

  final MonetizationController monetization;

  /// Overrides the platform for the store wording; for tests.
  final TargetPlatform? platform;

  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  MonetizationController get _m => widget.monetization;
  String? _shownMessage;

  bool get _isIos =>
      (widget.platform ?? defaultTargetPlatform) == TargetPlatform.iOS;
  String get _storeName => _isIos ? 'App Store' : 'Google Play';
  String get _manageHint => _isIos
      ? 'Manage or cancel it any time in Settings → your name → Subscriptions.'
      : 'Manage or cancel it any time in the Play Store → Payments & '
          'subscriptions → Subscriptions.';

  @override
  void initState() {
    super.initState();
    _m.addListener(_showMessage);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _m.offerStatus == OfferStatus.unavailable) _m.loadOffer();
    });
  }

  @override
  void dispose() {
    _m.removeListener(_showMessage);
    super.dispose();
  }

  void _showMessage() {
    final message = _m.message;
    if (message == null || message == _shownMessage || !mounted) return;
    _shownMessage = message;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
    _m.clearMessage();
    _shownMessage = null;
  }

  Future<void> _subscribe() async {
    if (_m.isTest) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Test purchase'),
          content: Text('This is test mode: you become ad-free, but no '
              'store is contacted and no money is charged '
              '(${_m.offer?.price ?? ''}/month in the real app).'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Subscribe (test)'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _m.subscribe();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Plans')),
      body: ListenableBuilder(
        listenable: _m,
        builder: (context, _) {
          final theme = Theme.of(context);
          final adFree = _m.plan == Plan.adFree;
          final price = _m.offer?.price;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_m.isTest) ...[
                const _Notice(
                  icon: Icons.science_outlined,
                  text: 'Test mode: purchases are simulated and no money is '
                      'charged.',
                ),
                const SizedBox(height: 12),
              ],
              Text(
                adFree ? "You're ad-free" : "You're on the free plan",
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 4),
              Text(
                'Every DataMuncher feature is included in both plans. The '
                'only difference is ads.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              _PlanCard(
                plan: Plan.free,
                price: 'Free',
                current: !adFree,
                points: const [
                  'Every feature: scans, Garbage Bin, unused apps, '
                      'Do-not-collect list',
                  'A small banner ad at the bottom of the screen',
                ],
              ),
              const SizedBox(height: 12),
              _PlanCard(
                plan: Plan.adFree,
                price: price == null ? 'Monthly' : '$price / month',
                current: adFree,
                points: const [
                  'Every feature, exactly the same as Free',
                  'No ads anywhere',
                ],
              ),
              const SizedBox(height: 20),
              if (adFree)
                ..._adFreeActions(theme)
              else
                ..._freeActions(theme, price),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _freeActions(ThemeData theme, String? price) {
    if (_m.pending) {
      return [
        const _Notice(
          icon: Icons.hourglass_top,
          text: 'Waiting for the purchase to be approved. Ads disappear as '
              'soon as it is.',
        ),
        const SizedBox(height: 8),
        _restoreButton(),
      ];
    }
    return [
      switch (_m.offerStatus) {
        OfferStatus.loading => const Center(
            child: Padding(
              padding: EdgeInsets.all(8),
              child: CircularProgressIndicator(
                  semanticsLabel: 'Loading the subscription'),
            ),
          ),
        OfferStatus.unavailable => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Notice(
                icon: Icons.cloud_off_outlined,
                text: "The subscription isn't available right now. Check "
                    'your connection and that you are signed in to the '
                    '$_storeName.',
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _m.loadOffer,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ),
        OfferStatus.available => FilledButton(
            onPressed: _m.busy ? null : _subscribe,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            child: _m.purchasing
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : Text('Go ad-free for $price / month'),
          ),
      },
      const SizedBox(height: 8),
      _restoreButton(),
      const SizedBox(height: 16),
      Text(
        'Billed monthly through the $_storeName and renews automatically '
        'until you cancel. Cancel at least 24 hours before it renews to '
        'avoid the next charge. $_manageHint',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    ];
  }

  List<Widget> _adFreeActions(ThemeData theme) => [
        const _Notice(
          icon: Icons.favorite_outline,
          text: 'Thanks for supporting DataMuncher. No ads will be shown.',
        ),
        const SizedBox(height: 12),
        if (_m.isTest)
          OutlinedButton(
            onPressed: _m.endTestSubscription,
            child: const Text('End test subscription'),
          )
        else
          Text(_manageHint, style: theme.textTheme.bodyMedium),
      ];

  Widget _restoreButton() => TextButton(
        onPressed: _m.busy ? null : _m.restore,
        child: _m.restoring
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Restore purchases'),
      );
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.price,
    required this.current,
    required this.points,
  });

  final Plan plan;
  final String price;
  final bool current;
  final List<String> points;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: current ? scheme.primary : scheme.outlineVariant,
          width: current ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text(plan.label, style: theme.textTheme.titleLarge)),
              if (current)
                Chip(
                  label: const Text('Current plan'),
                  visualDensity: VisualDensity.compact,
                  side: BorderSide(color: scheme.primary),
                ),
            ]),
            Text(price, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final point in points)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.check, size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(child: Text(point)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Icon(icon, color: scheme.onSecondaryContainer),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text,
              style: TextStyle(color: scheme.onSecondaryContainer)),
        ),
      ]),
    );
  }
}
