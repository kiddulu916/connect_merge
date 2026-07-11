import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/infrastructure/ad_config.dart';

void main() {
  test('uses Google test ad unit IDs (useTestAds is true)', () {
    expect(AdConfig.useTestAds, isTrue);
    expect(AdConfig.bannerUnitId, isNotEmpty);
    expect(AdConfig.rewardedUnitId, isNotEmpty);
  });
}
