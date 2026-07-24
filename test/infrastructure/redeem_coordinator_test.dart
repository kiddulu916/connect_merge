import 'dart:async';
import 'dart:convert';

import 'package:connect_merge/domain/models/friend.dart';
import 'package:connect_merge/infrastructure/redeem_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('snapshot is one atomic JSON value written before redeem', () async {
    String? stored;
    final writes = <String>[];
    final coordinator = RedeemCoordinator(
      loadSnapshot: () => stored,
      saveSnapshot: (value) async {
        stored = value;
        writes.add(value);
      },
      redeemCode: (code) async {
        expect(
          jsonDecode(stored!) as Map<String, dynamic>,
          {
            'handled': false,
            'active': {'code': 'ABCD2345', 'source': 'liveLink'},
          },
        );
        return const RedeemResult(RedeemStatus.ok);
      },
      onboardingReady: () => true,
      hasGoogleIdentity: () => false,
    );

    await coordinator.enqueueLiveLink('ABCD2345');

    expect(writes, hasLength(2));
    expect(
      jsonDecode(writes.last) as Map<String, dynamic>,
      {'handled': false},
    );
  });

  test('deduplicates active and queued before writing', () async {
    final harness = _Harness(onboardingReady: false);

    await harness.coordinator.enqueueLiveLink('AAAAAAAA');
    await harness.coordinator.enqueueLiveLink('AAAAAAAA');
    await harness.coordinator.enqueueLiveLink('BBBBBBBB');
    await harness.coordinator.enqueueLiveLink('BBBBBBBB');

    expect(harness.writes, hasLength(2));
    expect(harness.snapshot.active,
        const RedeemInput('AAAAAAAA', RedeemSource.liveLink));
    expect(harness.snapshot.queued,
        const RedeemInput('BBBBBBBB', RedeemSource.liveLink));
  });

  test('newest distinct live link replaces the older queued live link',
      () async {
    final harness = _Harness(onboardingReady: false);

    await harness.coordinator.enqueueLiveLink('AAAAAAAA');
    await harness.coordinator.enqueueLiveLink('BBBBBBBB');
    await harness.coordinator.enqueueLiveLink('CCCCCCCC');

    expect(harness.snapshot.active?.code, 'AAAAAAAA');
    expect(harness.snapshot.queued?.code, 'CCCCCCCC');
  });

  test('pending referrer is superseded by a live link and marked handled',
      () async {
    final harness = _Harness(
      onboardingReady: false,
      hasGoogleIdentity: false,
    );

    await harness.coordinator.enqueueInstallReferrer('AAAAAAAA');
    await harness.coordinator.enqueueLiveLink('BBBBBBBB');

    expect(harness.snapshot.handled, isTrue);
    expect(harness.snapshot.active,
        const RedeemInput('BBBBBBBB', RedeemSource.liveLink));
    expect(harness.snapshot.queued, isNull);
  });

  test('live success drops a queued referrer and marks it handled', () async {
    final harness = _Harness(onboardingReady: false);

    await harness.coordinator.enqueueLiveLink('AAAAAAAA');
    await harness.coordinator.enqueueInstallReferrer('BBBBBBBB');
    harness.onboardingReady = true;
    harness.googleReady = true;
    harness.results.add(const RedeemResult(RedeemStatus.ok));

    await harness.coordinator.retry();

    expect(harness.calls, ['AAAAAAAA']);
    expect(harness.snapshot.handled, isTrue);
    expect(harness.snapshot.active, isNull);
    expect(harness.snapshot.queued, isNull);
  });

  test('self and invalid consume active then run queued', () async {
    final harness = _Harness(onboardingReady: false);
    await harness.coordinator.enqueueLiveLink('AAAAAAAA');
    await harness.coordinator.enqueueLiveLink('BBBBBBBB');
    harness.onboardingReady = true;
    harness.results
      ..add(const RedeemResult(RedeemStatus.self))
      ..add(const RedeemResult(RedeemStatus.invalidCode));

    await harness.coordinator.retry();

    expect(harness.calls, ['AAAAAAAA', 'BBBBBBBB']);
    expect(harness.snapshot.active, isNull);
  });

  test('live link arriving during referrer RPC is promoted on transient',
      () async {
    final sent = Completer<void>();
    final response = Completer<RedeemResult>();
    final harness = _Harness(
      redeemCode: (code) {
        if (code == 'AAAAAAAA') {
          sent.complete();
          return response.future;
        }
        return Future.value(const RedeemResult(RedeemStatus.ok));
      },
    );

    final referrer = harness.coordinator.enqueueInstallReferrer('AAAAAAAA');
    await sent.future;
    final live = harness.coordinator.enqueueLiveLink('BBBBBBBB');
    await Future<void>.delayed(Duration.zero);

    expect(harness.snapshot.queued,
        const RedeemInput('BBBBBBBB', RedeemSource.liveLink));
    response.complete(const RedeemResult(RedeemStatus.error));
    await Future.wait([referrer, live]);

    expect(harness.snapshot.handled, isTrue);
    expect(harness.calls, ['AAAAAAAA', 'BBBBBBBB']);
    expect(harness.snapshot.active, isNull);
  });

  test('retries serially with bounded exponential delays', () async {
    var concurrent = 0;
    var maxConcurrent = 0;
    final delays = <Duration>[];
    final harness = _Harness(
      retryDelays: const [
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
      ],
      delay: (duration) async => delays.add(duration),
      redeemCode: (code) async {
        concurrent++;
        if (concurrent > maxConcurrent) maxConcurrent = concurrent;
        await Future<void>.delayed(Duration.zero);
        concurrent--;
        return const RedeemResult(RedeemStatus.error);
      },
    );

    await harness.coordinator.enqueueLiveLink('AAAAAAAA');

    expect(harness.calls, hasLength(4));
    expect(delays, const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ]);
    expect(maxConcurrent, 1);

    await harness.coordinator.retry();
    expect(harness.calls, hasLength(8));
  });

  test('restores a crash-persisted active request and retries it', () async {
    final first = _Harness(onboardingReady: false);
    await first.coordinator.enqueueLiveLink('AAAAAAAA');

    final restored = _Harness(stored: first.stored);
    restored.results.add(const RedeemResult(RedeemStatus.ok));
    await restored.coordinator.retry();

    expect(restored.calls, ['AAAAAAAA']);
    expect(restored.snapshot.active, isNull);
  });

  test('RPC success followed by a failed terminal write remains retryable',
      () async {
    String? stored;
    var saves = 0;
    final first = RedeemCoordinator(
      loadSnapshot: () => stored,
      saveSnapshot: (value) async {
        saves++;
        if (saves == 2) throw StateError('disk unavailable');
        stored = value;
      },
      redeemCode: (_) async => const RedeemResult(RedeemStatus.ok),
      onboardingReady: () => true,
      hasGoogleIdentity: () => true,
    );

    await expectLater(
      first.enqueueLiveLink('AAAAAAAA'),
      throwsA(isA<StateError>()),
    );
    expect(RedeemSnapshot.decode(stored).active?.code, 'AAAAAAAA');

    final restored = _Harness(stored: stored);
    await restored.coordinator.retry();
    expect(restored.calls, ['AAAAAAAA']);
    expect(restored.snapshot.active, isNull);
  });

  test('onboarding gates both sources and Google gates only referrers',
      () async {
    final live = _Harness(onboardingReady: false, hasGoogleIdentity: false);
    await live.coordinator.enqueueLiveLink('AAAAAAAA');
    expect(live.calls, isEmpty);
    live.onboardingReady = true;
    live.results.add(const RedeemResult(RedeemStatus.ok));
    await live.coordinator.retry();
    expect(live.calls, ['AAAAAAAA']);

    final referrer =
        _Harness(onboardingReady: true, hasGoogleIdentity: false);
    await referrer.coordinator.enqueueInstallReferrer('BBBBBBBB');
    expect(referrer.calls, isEmpty);
    referrer.googleReady = true;
    referrer.results.add(const RedeemResult(RedeemStatus.ok));
    await referrer.coordinator.retry();
    expect(referrer.calls, ['BBBBBBBB']);
    expect(referrer.snapshot.handled, isTrue);
  });

  test('handled suppresses referrer resurrection and empty fetch is terminal',
      () async {
    final handled = _Harness(
      stored: jsonEncode({'handled': true}),
    );

    await handled.coordinator.enqueueInstallReferrer('AAAAAAAA');

    expect(handled.calls, isEmpty);
    expect(handled.writes, isEmpty);

    final empty = _Harness(onboardingReady: false);
    await empty.coordinator.markInstallReferrerHandled();
    expect(empty.snapshot.handled, isTrue);
    await empty.coordinator.enqueueInstallReferrer('BBBBBBBB');
    expect(empty.snapshot.active, isNull);
  });

  test('analytics reports source/outcome without leaking friend codes',
      () async {
    final events = <Map<String, Object?>>[];
    final harness = _Harness(
      onAnalyticsEvent: (name, [params]) {
        events.add({'name': name, ...?params});
      },
    );
    harness.results.add(const RedeemResult(RedeemStatus.self));

    await harness.coordinator.enqueueLiveLink('SECRE234');

    expect(events.map((event) => event['name']), [
      'referral_redeem_attempt',
      'referral_redeem_result',
    ]);
    expect(events.last['result'], 'self');
    expect(jsonEncode(events), isNot(contains('SECRE234')));
  });
}

class _Harness {
  String? stored;
  bool onboardingReady;
  bool googleReady;
  final List<String> writes = [];
  final List<String> calls = [];
  final List<RedeemResult> results = [];
  late final RedeemCoordinator coordinator;

  _Harness({
    this.stored,
    this.onboardingReady = true,
    bool hasGoogleIdentity = true,
    Future<RedeemResult> Function(String code)? redeemCode,
    Future<void> Function(Duration duration)? delay,
    List<Duration> retryDelays = const [],
    void Function(String name, [Map<String, Object?>? params])?
        onAnalyticsEvent,
  }) : googleReady = hasGoogleIdentity {
    coordinator = RedeemCoordinator(
      loadSnapshot: () => stored,
      saveSnapshot: (value) async {
        stored = value;
        writes.add(value);
      },
      redeemCode: (code) async {
        calls.add(code);
        if (redeemCode != null) return redeemCode(code);
        return results.isEmpty
            ? const RedeemResult(RedeemStatus.ok)
            : results.removeAt(0);
      },
      onboardingReady: () => onboardingReady,
      hasGoogleIdentity: () => googleReady,
      delay: delay,
      retryDelays: retryDelays,
      onAnalyticsEvent: onAnalyticsEvent,
    );
  }

  RedeemSnapshot get snapshot => RedeemSnapshot.decode(stored);
}
