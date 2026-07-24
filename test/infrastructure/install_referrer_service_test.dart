import 'package:connect_merge/infrastructure/install_referrer_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseCode', () {
    test('extracts one exact base32 friend code', () {
      expect(
        InstallReferrerService.parseCode(
          'utm_source=invite&code=ABCD2345',
        ),
        'ABCD2345',
      );
    });

    test('rejects organic, malformed, lowercase, and invalid alphabet', () {
      for (final referrer in <String?>[
        null,
        '',
        'utm_source=organic',
        'code=abcd2345',
        'code=ABCD0189',
        '%',
      ]) {
        expect(InstallReferrerService.parseCode(referrer), isNull);
      }
    });
  });

  test('handled snapshot suppresses Play referrer resurrection', () async {
    var fetches = 0;
    final service = InstallReferrerService(
      isAndroid: () => true,
      isHandled: () => true,
      fetch: () async {
        fetches++;
        return 'code=ABCD2345';
      },
      markHandled: () async {},
      enqueue: (_) async {},
    );

    await service.capture();
    expect(fetches, 0);
  });

  test('successful empty or malformed fetch is terminal', () async {
    for (final raw in ['', 'utm_source=organic', 'code=BAD']) {
      var handled = false;
      final service = InstallReferrerService(
        isAndroid: () => true,
        isHandled: () => false,
        fetch: () async => raw,
        markHandled: () async => handled = true,
        enqueue: (_) async => fail('invalid payload must not enqueue'),
      );

      await service.capture();
      expect(handled, isTrue, reason: raw);
    }
  });

  test('fetch failure remains unhandled for a later retry', () async {
    var handled = false;
    final events = <Map<String, Object?>>[];
    final service = InstallReferrerService(
      isAndroid: () => true,
      isHandled: () => false,
      fetch: () async => throw StateError('service unavailable'),
      markHandled: () async => handled = true,
      enqueue: (_) async {},
      analytics: (event, parameters) =>
          events.add({'event': event, ...?parameters}),
    );

    await service.capture();

    expect(handled, isFalse);
    expect(events.single['result'], 'failure');
    expect(events.single.toString(), isNot(contains('ABCD2345')));
  });

  test('valid fetch enqueues without marking handled early', () async {
    var handled = false;
    String? enqueued;
    final service = InstallReferrerService(
      isAndroid: () => true,
      isHandled: () => false,
      fetch: () async => 'code=ABCD2345',
      markHandled: () async => handled = true,
      enqueue: (code) async => enqueued = code,
    );

    await service.capture();

    expect(enqueued, 'ABCD2345');
    expect(handled, isFalse);
  });
}
