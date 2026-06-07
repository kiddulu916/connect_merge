import 'dart:io' show Platform;

/// Centralizes AdMob unit IDs. Ships with Google's official TEST IDs so the app
/// builds and runs with no AdMob account. Before release: set [useTestAds] to
/// false and fill in the real unit IDs (and the App IDs in the native manifests).
class AdConfig {
  const AdConfig._();

  static const bool useTestAds = false;

  // Google test unit IDs (safe to ship while developing).
  static const _testBannerAndroid = 'ca-app-pub-3940256099942544/6300978111';
  static const _testBannerIos = 'ca-app-pub-3940256099942544/2934735716';
  static const _testRewardedAndroid = 'ca-app-pub-3940256099942544/5224354917';
  static const _testRewardedIos = 'ca-app-pub-3940256099942544/1712485313';

  // TODO(release): replace with real unit IDs before publishing.
  static const _realBannerAndroid = 'ca-app-pub-4807961095325796/1830849771';
  static const _realBannerIos = 'ca-app-pub-4807961095325796/1257803007';
  static const _realRewardedAndroid = 'ca-app-pub-4807961095325796/8528798683';
  static const _realRewardedIos = 'ca-app-pub-4807961095325796/1034441724';

  static bool get _ios => Platform.isIOS;

  static String get bannerUnitId => useTestAds
      ? (_ios ? _testBannerIos : _testBannerAndroid)
      : (_ios ? _realBannerIos : _realBannerAndroid);

  static String get rewardedUnitId => useTestAds
      ? (_ios ? _testRewardedIos : _testRewardedAndroid)
      : (_ios ? _realRewardedIos : _realRewardedAndroid);
}
