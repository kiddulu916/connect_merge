import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/infrastructure/ad_config.dart';

void main() {
  test('ships with real ad unit IDs (useTestAds is false)', () {
    expect(AdConfig.useTestAds, isFalse);
    expect(AdConfig.bannerUnitId, isNotEmpty);
    expect(AdConfig.rewardedUnitId, isNotEmpty);
  });
}
