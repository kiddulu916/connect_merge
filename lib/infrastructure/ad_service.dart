import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ad_config.dart';
import 'consent_service.dart';

/// Isolates all google_mobile_ads lifecycle so the rest of the app never
/// imports the plugin directly.
class AdService {
  RewardedAd? _rewarded;
  bool _initialized = false;

  /// Checks UMP consent before calling [MobileAds.initialize].
  /// If consent has not been granted yet this is a no-op — ads will be
  /// unavailable for this session and initialised on the next launch once
  /// the user has accepted the consent form shown by the native layer.
  Future<void> init(ConsentService consent) async {
    if (!await consent.canRequestAds()) return;
    await MobileAds.instance.initialize();
    _initialized = true;
    _preloadRewarded();
  }

  /// Builds a fresh banner ad ready to load, or null when ads are not yet
  /// initialised (consent not granted). The caller must dispose the returned
  /// ad when done.
  BannerAd? createBanner() {
    if (!_initialized) return null;
    return BannerAd(
      adUnitId: AdConfig.bannerUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: const BannerAdListener(),
    )..load();
  }

  void _preloadRewarded() {
    if (!_initialized) return;
    RewardedAd.load(
      adUnitId: AdConfig.rewardedUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) => _rewarded = ad,
        onAdFailedToLoad: (_) => _rewarded = null,
      ),
    );
  }

  /// Shows a rewarded ad. Calls [onReward] exactly once if the user earns the
  /// reward, then preloads the next ad. [onUnavailable] fires if none is ready
  /// or if ads have not been initialised yet.
  void showRewarded({
    required void Function() onReward,
    required void Function() onUnavailable,
  }) {
    if (!_initialized) {
      onUnavailable();
      return;
    }
    final ad = _rewarded;
    if (ad == null) {
      onUnavailable();
      _preloadRewarded();
      return;
    }
    var rewarded = false;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _rewarded = null;
        _preloadRewarded();
      },
      onAdFailedToShowFullScreenContent: (ad, _) {
        ad.dispose();
        _rewarded = null;
        onUnavailable();
        _preloadRewarded();
      },
    );
    ad.show(onUserEarnedReward: (_, __) {
      if (!rewarded) {
        rewarded = true;
        onReward();
      }
    });
  }

  void dispose() {
    _rewarded?.dispose();
    _rewarded = null;
  }
}
