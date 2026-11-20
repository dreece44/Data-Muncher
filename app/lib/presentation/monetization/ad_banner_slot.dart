import 'package:flutter/material.dart';

import '../../application/monetization/monetization_controller.dart';
import '../../data/ads/ad_provider.dart';

/// The banner at the bottom of a screen on the free plan (DAT-38), with a
/// "Remove ads" link to the subscription (DAT-39). Takes no space at all on
/// the ad-free plan.
class AdBannerSlot extends StatelessWidget {
  const AdBannerSlot({
    super.key,
    required this.monetization,
    required this.ads,
    required this.onRemoveAds,
  });

  final MonetizationController monetization;
  final AdProvider ads;
  final VoidCallback onRemoveAds;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: monetization,
      builder: (context, _) {
        if (!monetization.showAds) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Material(
          color: scheme.surfaceContainerHighest,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(child: ads.buildBanner()),
                  TextButton(
                    onPressed: onRemoveAds,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('Remove ads'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Puts [AdBannerSlot] under any screen.
class WithAdBanner extends StatelessWidget {
  const WithAdBanner({
    super.key,
    required this.child,
    required this.monetization,
    required this.ads,
    required this.onRemoveAds,
  });

  final Widget child;
  final MonetizationController monetization;
  final AdProvider ads;
  final VoidCallback onRemoveAds;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: monetization,
      child: child,
      builder: (context, child) => Column(
        children: [
          Expanded(
            // The banner sits over the home indicator area and pads itself,
            // so the screen above mustn't add that space too.
            child: monetization.showAds
                ? MediaQuery.removePadding(
                    context: context,
                    removeBottom: true,
                    child: child!,
                  )
                : child!,
          ),
          AdBannerSlot(
            monetization: monetization,
            ads: ads,
            onRemoveAds: onRemoveAds,
          ),
        ],
      ),
    );
  }
}
