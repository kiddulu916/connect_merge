import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ad_config.dart';
import 'analytics_service.dart';
import 'consent_service.dart';

/// Isolates all google_mobile_ads lifecycle so the rest of the app never
/// imports the plugin directly.
class AdService {
  final AnalyticsService? analytics;
  final Future<void> Function({
    required String adUnitId,
    required AdRequest request,
    required RewardedAdLoadCallback rewardedAdLoadCallback,
  }) _loadRewarded;
  final String Function() _rewardedUnitId;
  final ValueNotifier<bool> _showing;

  AdService({this.analytics})
      : _loadRewarded = RewardedAd.load,
        _rewardedUnitId = (() => AdConfig.rewardedUnitId),
        _showing = ValueNotifier(false);

  @visibleForTesting
  AdService.withSeams({
    this.analytics,
    bool initialized = true,
    bool showing = false,
    Future<void> Function({
      required String adUnitId,
      required AdRequest request,
      required RewardedAdLoadCallback rewardedAdLoadCallback,
    })? loadRewarded,
    String Function()? rewardedUnitIdOverride,
  })  : _loadRewarded = loadRewarded ?? RewardedAd.load,
        _rewardedUnitId =
            rewardedUnitIdOverride ?? (() => AdConfig.rewardedUnitId),
        _showing = ValueNotifier(showing),
        _initialized = initialized;

  RewardedAd? _rewarded;
  bool _initialized = false;
  bool _loadingRewarded = false;
  bool _showTerminalHandled = false;
  Future<void>? _pendingReward;

  ValueListenable<bool> get showing => _showing;

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
    if (!_initialized || AdConfig.isPlaceholder(AdConfig.bannerUnitId)) {
      return null;
    }
    return BannerAd(
      adUnitId: AdConfig.bannerUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: const BannerAdListener(),
    )..load();
  }

  void _preloadRewarded() {
    if (!_initialized) return;
    final unitId = _rewardedUnitId();
    if (AdConfig.isPlaceholder(unitId)) return;
    if (_loadingRewarded) return;
    _loadingRewarded = true;
    try {
      _loadRewarded(
        adUnitId: unitId,
        request: const AdRequest(),
        rewardedAdLoadCallback: RewardedAdLoadCallback(
          onAdLoaded: (ad) {
            if (!_loadingRewarded || _rewarded != null) {
              ad.dispose();
            } else {
              _rewarded = ad;
            }
            _loadingRewarded = false;
          },
          onAdFailedToLoad: (_) => _handleLoadFailure(),
        ),
      ).catchError((_) => _handleLoadFailure());
    } catch (_) {
      _handleLoadFailure();
    }
  }

  void _handleLoadFailure() {
    if (!_loadingRewarded) return;
    _loadingRewarded = false;
    _rewarded = null;
    analytics?.logEvent('ad_load_failed');
  }

  /// Shows a rewarded ad for feature [adType] (e.g. `'hint'`, `'undo'`,
  /// `'continue'`, `'double_coins'`, `'loot_double'`, `'streak_freeze'`,
  /// `'cosmetic_unlock'`) — used only to tag ad analytics events, not for any
  /// gameplay logic. Calls [onReward] exactly once if the user earns the
  /// reward, then preloads the next ad. [onUnavailable] fires if none is ready,
  /// ads have not been initialised, or another rewarded ad is in flight.
  void showRewarded({
    required String adType,
    required Future<void> Function() onReward,
    required void Function() onUnavailable,
  }) {
    if (!_initialized) {
      analytics?.logEvent('ad_not_initialized', {'adType': adType});
      onUnavailable();
      return;
    }
    if (_showing.value) {
      analytics?.logEvent('ad_busy', {'adType': adType});
      onUnavailable();
      return;
    }
    final ad = _rewarded;
    if (ad == null) {
      analytics?.logEvent('ad_not_ready', {'adType': adType});
      onUnavailable();
      _preloadRewarded();
      return;
    }

    var rewarded = false;
    _showing.value = true;
    _showTerminalHandled = false;
    _pendingReward = null;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) async {
        if (_showTerminalHandled) return;
        _showTerminalHandled = true;
        ad.dispose();
        _rewarded = null;
        try {
          await _pendingReward;
        } finally {
          _pendingReward = null;
          _showing.value = false;
          _preloadRewarded();
        }
      },
      onAdFailedToShowFullScreenContent: (ad, _) => _handleShowFailure(
        ad: ad,
        adType: adType,
        onUnavailable: onUnavailable,
      ),
    );
    analytics?.logEvent('ad_shown', {'adType': adType});
    try {
      ad.show(onUserEarnedReward: (_, __) {
        if (!rewarded) {
          rewarded = true;
          _pendingReward = onReward();
        }
      }).catchError((_) => _handleShowFailure(
            ad: ad,
            adType: adType,
            onUnavailable: onUnavailable,
          ));
    } catch (_) {
      _handleShowFailure(
        ad: ad,
        adType: adType,
        onUnavailable: onUnavailable,
      );
    }
  }

  void _handleShowFailure({
    required RewardedAd ad,
    required String adType,
    required void Function() onUnavailable,
  }) {
    if (_showTerminalHandled) return;
    _showTerminalHandled = true;
    ad.dispose();
    _rewarded = null;
    _pendingReward = null;
    _showing.value = false;
    analytics?.logEvent('ad_show_failed', {'adType': adType});
    onUnavailable();
    _preloadRewarded();
  }

  void dispose() {
    _rewarded?.dispose();
    _rewarded = null;
  }
}
