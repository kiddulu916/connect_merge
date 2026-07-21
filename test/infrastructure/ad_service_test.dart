import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/infrastructure/ad_service.dart';
import 'package:connect_merge/infrastructure/analytics_service.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

void main() {
  group('AdService analytics instrumentation', () {
    test('showRewarded before init reports ad_not_initialized', () {
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
      expect(events.single.key, 'ad_not_initialized');
      expect(events.single.value, {'adType': 'hint'});
    });

    test('showRewarded while busy reports ad_busy', () {
      final events = <String>[];
      final fake = _pendingLoader();
      final adService = AdService.withSeams(
        analytics: AnalyticsService.withSeams(
          logEvent: (name, _) async => events.add(name),
        ),
        showing: true,
        loadRewarded: fake.loader,
      );

      var unavailableCalled = false;
      adService.showRewarded(
        adType: 'undo',
        onReward: () async => fail('should not reward'),
        onUnavailable: () => unavailableCalled = true,
      );

      expect(unavailableCalled, isTrue);
      expect(events, ['ad_busy']);
      expect(fake.calls, 0);
    });

    test('showRewarded with no loaded ad reports ad_not_ready', () {
      final events = <String>[];
      final adService = AdService.withSeams(
        analytics: AnalyticsService.withSeams(
          logEvent: (name, _) async => events.add(name),
        ),
        loadRewarded: _pendingLoader().loader,
      );

      adService.showRewarded(
        adType: 'hint',
        onReward: () async => fail('should not reward'),
        onUnavailable: () {},
      );

      expect(events, ['ad_not_ready']);
    });

    test('works with no AnalyticsService injected (offline / unconfigured)',
        () {
      final adService = AdService();

      var unavailableCalled = false;
      expect(
        () => adService.showRewarded(
          adType: 'undo',
          onReward: () async => fail('should not reward'),
          onUnavailable: () => unavailableCalled = true,
        ),
        returnsNormally,
      );
      expect(unavailableCalled, isTrue);
    });
  });

  group('AdService rewarded preload', () {
    test('suppresses overlapping loads and retries after callback failure', () {
      final fake = _pendingLoader();
      final adService = AdService.withSeams(loadRewarded: fake.loader);

      _requestPreload(adService);
      _requestPreload(adService);
      expect(fake.calls, 1);

      fake.callback!.onAdFailedToLoad(_loadError);
      _requestPreload(adService);
      expect(fake.calls, 2);
    });

    test('a synchronous loader throw clears the loading guard', () {
      var calls = 0;
      final adService = AdService.withSeams(
        loadRewarded: ({
          required adUnitId,
          required request,
          required rewardedAdLoadCallback,
        }) {
          calls++;
          throw StateError('sync load failure');
        },
      );

      _requestPreload(adService);
      _requestPreload(adService);
      expect(calls, 2);
    });

    test('an asynchronous loader error clears the loading guard', () async {
      var calls = 0;
      final adService = AdService.withSeams(
        loadRewarded: ({
          required adUnitId,
          required request,
          required rewardedAdLoadCallback,
        }) {
          calls++;
          return Future<void>.error(StateError('async load failure'));
        },
      );

      _requestPreload(adService);
      await Future<void>.delayed(Duration.zero);
      _requestPreload(adService);
      expect(calls, 2);
    });

    test('callback plus future error handles a load failure once', () async {
      final events = <String>[];
      final adService = AdService.withSeams(
        analytics: AnalyticsService.withSeams(
          logEvent: (name, _) async => events.add(name),
        ),
        loadRewarded: ({
          required adUnitId,
          required request,
          required rewardedAdLoadCallback,
        }) {
          rewardedAdLoadCallback.onAdFailedToLoad(_loadError);
          return Future<void>.error(StateError('same load failed twice'));
        },
      );

      _requestPreload(adService);
      await Future<void>.delayed(Duration.zero);
      expect(events.where((event) => event == 'ad_load_failed'), hasLength(1));
    });

    test('placeholder rewarded ID skips the loader', () {
      var calls = 0;
      final adService = AdService.withSeams(
        rewardedUnitIdOverride: () => 'null',
        loadRewarded: ({
          required adUnitId,
          required request,
          required rewardedAdLoadCallback,
        }) async {
          calls++;
        },
      );

      _requestPreload(adService);
      expect(calls, 0);
    });
  });
}

final _loadError = LoadAdError(1, 'test', 'failed', null);

void _requestPreload(AdService adService) {
  adService.showRewarded(
    adType: 'test',
    onReward: () async => fail('should not reward'),
    onUnavailable: () {},
  );
}

_PendingLoader _pendingLoader() => _PendingLoader();

class _PendingLoader {
  int calls = 0;
  RewardedAdLoadCallback? callback;

  Future<void> loader({
    required String adUnitId,
    required AdRequest request,
    required RewardedAdLoadCallback rewardedAdLoadCallback,
  }) {
    calls++;
    callback = rewardedAdLoadCallback;
    return Completer<void>().future;
  }
}
