import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/infrastructure/analytics_service.dart';

void main() {
  group('AnalyticsService', () {
    test('logEvent forwards name and params to the injected seam', () {
      String? capturedName;
      Map<String, Object?>? capturedParams;
      final service = AnalyticsService.withSeams(
        logEvent: (name, params) async {
          capturedName = name;
          capturedParams = params;
        },
      );

      service.logEvent('run_completed', {'score': 42});

      expect(capturedName, 'run_completed');
      expect(capturedParams, {'score': 42});
    });

    test('logEvent works with no params', () {
      String? capturedName;
      final service = AnalyticsService.withSeams(
        logEvent: (name, params) async {
          capturedName = name;
        },
      );

      service.logEvent('onboarding_completed');

      expect(capturedName, 'onboarding_completed');
    });

    test('logEvent never throws even when the seam throws synchronously',
        () {
      final service = AnalyticsService.withSeams(
        logEvent: (name, params) {
          throw StateError('seam exploded');
        },
      );

      expect(() => service.logEvent('run_completed'), returnsNormally);
    });

    test('logEvent never throws when the seam returns a failing Future',
        () async {
      final service = AnalyticsService.withSeams(
        logEvent: (name, params) async {
          throw StateError('async seam failure');
        },
      );

      expect(() => service.logEvent('run_completed'), returnsNormally);
      await Future<void>.delayed(Duration.zero);
    });

    test('navigatorObserver defaults to a plain NavigatorObserver when none injected',
        () {
      final service = AnalyticsService.withSeams(
        logEvent: (name, params) async {},
      );

      expect(service.navigatorObserver, isA<NavigatorObserver>());
    });

    test('navigatorObserver returns the injected observer when provided',
        () {
      final observer = NavigatorObserver();
      final service = AnalyticsService.withSeams(
        logEvent: (name, params) async {},
        observer: observer,
      );

      expect(service.navigatorObserver, same(observer));
    });
  });
}
