import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// PB-25 / DAT-38: where banner ads come from.
abstract interface class AdProvider {
  /// A banner, or an empty box until one loads. Never blocks anything.
  Widget buildBanner();
}

/// AdMob banner ad unit ids.
///
/// Defaults are Google's published test ids, which always show a "Test Ad"
/// and pay nothing. Real ids from the team's AdMob account go in with
/// `--dart-define=ADMOB_BANNER_IOS=...` and `ADMOB_BANNER_ANDROID=...`
/// (and the app ids in AndroidManifest.xml and ios/Runner/Info.plist)
/// before release.
class AdUnitIds {
  static const String _testBannerIos = 'ca-app-pub-3940256099942544/2934735716';
  static const String _testBannerAndroid =
      'ca-app-pub-3940256099942544/6300978111';

  static const String bannerIos =
      String.fromEnvironment('ADMOB_BANNER_IOS', defaultValue: _testBannerIos);
  static const String bannerAndroid = String.fromEnvironment(
      'ADMOB_BANNER_ANDROID',
      defaultValue: _testBannerAndroid);

  static bool get usingTestAds =>
      bannerIos == _testBannerIos && bannerAndroid == _testBannerAndroid;
}

/// AdMob on iPhone and Android; nothing anywhere else.
AdProvider platformAdProvider() => switch (defaultTargetPlatform) {
      TargetPlatform.iOS => AdMobProvider(AdUnitIds.bannerIos),
      TargetPlatform.android => AdMobProvider(AdUnitIds.bannerAndroid),
      _ => const NoAdProvider(),
    };

class NoAdProvider implements AdProvider {
  const NoAdProvider();

  @override
  Widget buildBanner() => const SizedBox.shrink();
}

/// Google AdMob banners (google_mobile_ads).
class AdMobProvider implements AdProvider {
  AdMobProvider(this.bannerUnitId);

  final String bannerUnitId;
  static Future<void>? _started;

  /// Starts the SDK once, the first time a banner is needed, so ad-free
  /// users never load it.
  static Future<void> _start() => _started ??= MobileAds.instance
      .initialize()
      .then((_) {}, onError: (Object e) => debugPrint('AdMob failed: $e'));

  @override
  Widget buildBanner() => _AdMobBanner(unitId: bannerUnitId, start: _start);
}

class _AdMobBanner extends StatefulWidget {
  const _AdMobBanner({required this.unitId, required this.start});

  final String unitId;
  final Future<void> Function() start;

  @override
  State<_AdMobBanner> createState() => _AdMobBannerState();
}

class _AdMobBannerState extends State<_AdMobBanner> {
  BannerAd? _ad;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await widget.start();
    if (!mounted) return;
    final ad = BannerAd(
      adUnitId: widget.unitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (mounted) setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, error) {
          // No ad (offline, no fill): show nothing rather than a gap.
          debugPrint('Banner failed to load: ${error.message}');
          ad.dispose();
          if (mounted) {
            setState(() {
              _ad = null;
              _loaded = false;
            });
          }
        },
      ),
    );
    _ad = ad;
    await ad.load();
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (ad == null || !_loaded) return const SizedBox.shrink();
    return SizedBox(
      width: ad.size.width.toDouble(),
      height: ad.size.height.toDouble(),
      child: AdWidget(ad: ad),
    );
  }
}
