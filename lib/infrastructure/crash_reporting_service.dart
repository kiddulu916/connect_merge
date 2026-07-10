import 'package:firebase_crashlytics/firebase_crashlytics.dart';

/// Transport seam (mirrors [LeaderboardService]'s [InvokeFn]/[RpcFn]). The
/// default binds to the real [FirebaseCrashlytics] singleton; tests inject a
/// fake so this service's failure-swallowing logic can be exercised without
/// a platform channel.
typedef RecordErrorFn = Future<void> Function(
    Object exception, StackTrace? stack, bool fatal);
typedef LogFn = Future<void> Function(String message);

/// Isolates firebase_crashlytics so the rest of the app never imports the
/// plugin directly (mirrors [AdService]/[AuthService]). Every call swallows
/// its own failures (both a synchronous throw and an async `Future`
/// rejection) — observability must never itself become a new failure mode
/// that blocks gameplay.
class CrashReportingService {
  final RecordErrorFn _recordError;
  final LogFn _log;

  /// Production constructor: wires the seams to the real Crashlytics plugin.
  CrashReportingService()
      : _recordError = ((exception, stack, fatal) =>
            FirebaseCrashlytics.instance
                .recordError(exception, stack, fatal: fatal)),
        _log = FirebaseCrashlytics.instance.log;

  /// Test constructor: inject the transport seams directly.
  CrashReportingService.withSeams({
    required RecordErrorFn recordError,
    required LogFn log,
  })  : _recordError = recordError,
        _log = log;

  /// Record a non-fatal (by default) error with its stack trace. Fire-and-
  /// forget: never throws, regardless of whether the underlying report
  /// succeeds, fails synchronously, or fails asynchronously.
  void recordError(Object error, StackTrace? stack, {bool fatal = false}) {
    try {
      _recordError(error, stack, fatal).catchError((_) {});
    } catch (_) {
      // Observability must never itself become a failure mode.
    }
  }

  /// Attach a breadcrumb (no PII) to any crash report that follows.
  void log(String message) {
    try {
      _log(message).catchError((_) {});
    } catch (_) {
      // Observability must never itself become a failure mode.
    }
  }
}
