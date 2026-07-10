import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/infrastructure/ad_service.dart';
import 'package:connect_merge/infrastructure/analytics_service.dart';

void main() {
  group('AdService analytics instrumentation', () {
    test('showRewarded before init() reports unavailable and logs ad_load_failed',
        () {
      final events = <MapEntry<String, Map<String, Object?>?>>[];
      final analytics = AnalyticsService.withSeams(
        logEvent: (name, params) async {
          events.add(MapEntry(name, params));
        },
      );
      final adService = AdService(analytics: analytics);

      var unavailableCalled = false;
      adService.showRewarded(
        adType: 'hint',
        onReward: () => fail('should not reward'),
        onUnavailable: () => unavailableCalled = true,
      );

      expect(unavailableCalled, isTrue);
      // Compared field-by-field rather than via `expect(events, [MapEntry(...)])`:
      // MapEntry has no custom `==` (default identity equality) and matcher's
      // `equals()` only recurses into List/Map/Set, so a runtime MapEntry can
      // never structurally equal a const MapEntry regardless of contents.
      expect(events, hasLength(1));
      expect(events.single.key, 'ad_load_failed');
      expect(events.single.value, {'adType': 'hint'});
    });

    test('works with no AnalyticsService injected (offline / unconfigured)',
        () {
      final adService = AdService();

      var unavailableCalled = false;
      expect(
        () => adService.showRewarded(
          adType: 'undo',
          onReward: () => fail('should not reward'),
          onUnavailable: () => unavailableCalled = true,
        ),
        returnsNormally,
      );
      expect(unavailableCalled, isTrue);
    });
  });
}
