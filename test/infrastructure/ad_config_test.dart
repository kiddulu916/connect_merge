import 'package:connect_merge/infrastructure/ad_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes the iOS placeholder unit ID', () {
    expect(AdConfig.isPlaceholder('null'), isTrue);
    expect(AdConfig.isPlaceholder(AdConfig.rewardedUnitId), isFalse);
  });

  test('release guard: real ad units active, no Google sample IDs', () {
    expect(AdConfig.useTestAds, isFalse,
        reason: 'test ads must never ship in a release build');
    // 3940256099942544 is Google's sample publisher — it pays nothing.
    expect(AdConfig.bannerUnitId, isNot(contains('3940256099942544')));
    expect(AdConfig.rewardedUnitId, isNot(contains('3940256099942544')));
    expect(AdConfig.bannerUnitId, startsWith('ca-app-pub-'));
    expect(AdConfig.rewardedUnitId, startsWith('ca-app-pub-'));
  });
}
