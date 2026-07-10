import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/infrastructure/crash_reporting_service.dart';

void main() {
  group('CrashReportingService', () {
    test('recordError forwards to the injected seam', () {
      Object? capturedError;
      StackTrace? capturedStack;
      bool? capturedFatal;
      final service = CrashReportingService.withSeams(
        recordError: (exception, stack, fatal) async {
          capturedError = exception;
          capturedStack = stack;
          capturedFatal = fatal;
        },
        log: (_) async {},
      );

      final stack = StackTrace.current;
      service.recordError('boom', stack, fatal: true);

      expect(capturedError, 'boom');
      expect(capturedStack, stack);
      expect(capturedFatal, true);
    });

    test('recordError defaults fatal to false', () {
      bool? capturedFatal;
      final service = CrashReportingService.withSeams(
        recordError: (exception, stack, fatal) async {
          capturedFatal = fatal;
        },
        log: (_) async {},
      );

      service.recordError('boom', null);

      expect(capturedFatal, false);
    });

    test('recordError never throws even when the seam throws synchronously',
        () {
      final service = CrashReportingService.withSeams(
        recordError: (exception, stack, fatal) {
          throw StateError('seam exploded');
        },
        log: (_) async {},
      );

      expect(() => service.recordError('boom', null), returnsNormally);
    });

    test('recordError never throws when the seam returns a failing Future',
        () async {
      final service = CrashReportingService.withSeams(
        recordError: (exception, stack, fatal) async {
          throw StateError('async seam failure');
        },
        log: (_) async {},
      );

      expect(() => service.recordError('boom', null), returnsNormally);
      // Let the rejected Future's microtask run so it doesn't surface as an
      // unhandled async error in the test zone.
      await Future<void>.delayed(Duration.zero);
    });

    test('log forwards to the injected seam', () {
      String? captured;
      final service = CrashReportingService.withSeams(
        recordError: (exception, stack, fatal) async {},
        log: (message) async {
          captured = message;
        },
      );

      service.log('breadcrumb');

      expect(captured, 'breadcrumb');
    });
  });
}
