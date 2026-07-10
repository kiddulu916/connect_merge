import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/widgets.dart';

/// Transport seam (mirrors [CrashReportingService]/[LeaderboardService]).
typedef LogEventFn = Future<void> Function(
    String name, Map<String, Object?>? params);

/// Isolates firebase_analytics so the rest of the app never imports the
/// plugin directly (mirrors [AdService]/[CrashReportingService]). Every call
/// swallows its own failures (sync throw or async `Future` rejection) —
/// observability must never itself become a new failure mode.
class AnalyticsService {
  final LogEventFn _logEvent;
  final NavigatorObserver _observer;

  /// Production constructor: wires the seam to the real Analytics plugin and
  /// builds a [FirebaseAnalyticsObserver] for automatic screen-view tracking.
  AnalyticsService()
      : _logEvent = ((name, params) => FirebaseAnalytics.instance.logEvent(
            name: name,
            parameters: params?.map((k, v) => MapEntry(k, v as Object)),
          )),
        _observer =
            FirebaseAnalyticsObserver(analytics: FirebaseAnalytics.instance);

  /// Test constructor: inject the transport seam (and optionally a fake
  /// [NavigatorObserver]) directly.
  AnalyticsService.withSeams({
    required LogEventFn logEvent,
    NavigatorObserver? observer,
  })  : _logEvent = logEvent,
        _observer = observer ?? NavigatorObserver();

  /// A [NavigatorObserver] that logs `screen_view` automatically. Attach via
  /// `MaterialApp.navigatorObservers`.
  NavigatorObserver get navigatorObserver => _observer;

  /// Log a custom event. [params] values must never be null (Analytics event
  /// params are non-nullable); every v1 event in this app only ever passes
  /// String/int/bool values. Fire-and-forget: never throws.
  void logEvent(String name, [Map<String, Object?>? params]) {
    try {
      _logEvent(name, params).catchError((_) {});
    } catch (_) {
      // Observability must never itself become a failure mode.
    }
  }
}
