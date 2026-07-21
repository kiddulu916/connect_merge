import 'dart:io' show Platform;

/// Centralizes AdMob unit IDs. Ships with Google's official TEST IDs so the app
/// builds and runs with no AdMob account. Before release: set [useTestAds] to
/// false and fill in the real unit IDs (and the App IDs in the native manifests).
class AdConfig {
  const AdConfig._();

  static const bool useTestAds = false;

  // Google test unit IDs (safe to ship while developing).
  static const _testBannerAndroid = 'ca-app-pub-3940256099942544/6300978111';
  static const _testBannerIos = 'null';
  static const _testRewardedAndroid = 'ca-app-pub-3940256099942544/5224354917';
  static const _testRewardedIos = 'null';

  // Real unit IDs used for release builds.
  static const _realBannerAndroid = 'ca-app-pub-4807961095325796/8783611212';
  static const _realBannerIos = 'null';
  static const _realRewardedAndroid = 'ca-app-pub-4807961095325796/9560406184';
  static const _realRewardedIos = 'null';

  static bool get _ios => Platform.isIOS;

  static String get bannerUnitId => useTestAds
      ? (_ios ? _testBannerIos : _testBannerAndroid)
      : (_ios ? _realBannerIos : _realBannerAndroid);

  static String get rewardedUnitId => useTestAds
      ? (_ios ? _testRewardedIos : _testRewardedAndroid)
      : (_ios ? _realRewardedIos : _realRewardedAndroid);

  static bool isPlaceholder(String unitId) => unitId == 'null';
}
