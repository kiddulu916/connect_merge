import 'dart:async';
import 'dart:convert';

import '../domain/models/friend.dart';

enum RedeemSource { liveLink, installReferrer }

class RedeemInput {
  final String code;
  final RedeemSource source;

  const RedeemInput(this.code, this.source);

  Map<String, Object> toJson() => {
        'code': code,
        'source': source.name,
      };

  static RedeemInput? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = Map<String, dynamic>.from(value);
    final code = json['code'];
    final source = json['source'];
    if (code is! String || source is! String) return null;
    final parsedSource = switch (source) {
      'liveLink' => RedeemSource.liveLink,
      'installReferrer' => RedeemSource.installReferrer,
      _ => null,
    };
    return parsedSource == null ? null : RedeemInput(code, parsedSource);
  }

  @override
  bool operator ==(Object other) =>
      other is RedeemInput && other.code == code && other.source == source;

  @override
  int get hashCode => Object.hash(code, source);
}

class RedeemSnapshot {
  final bool handled;
  final RedeemInput? active;
  final RedeemInput? queued;

  const RedeemSnapshot({
    this.handled = false,
    this.active,
    this.queued,
  });

  Map<String, Object> toJson() => {
        'handled': handled,
        if (active != null) 'active': active!.toJson(),
        if (queued != null) 'queued': queued!.toJson(),
      };

  String encode() => jsonEncode(toJson());

  static RedeemSnapshot decode(String? value) {
    if (value == null) return const RedeemSnapshot();
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return const RedeemSnapshot();
      final json = Map<String, dynamic>.from(decoded);
      return RedeemSnapshot(
        handled: json['handled'] == true,
        active: RedeemInput.fromJson(json['active']),
        queued: RedeemInput.fromJson(json['queued']),
      );
    } catch (_) {
      return const RedeemSnapshot();
    }
  }
}

typedef LoadRedeemSnapshot = String? Function();
typedef SaveRedeemSnapshot = Future<void> Function(String value);
typedef RedeemCode = Future<RedeemResult> Function(String code);
typedef RedeemDelay = Future<void> Function(Duration duration);
typedef RedeemAnalytics = void Function(
  String name, [
  Map<String, Object?>? params,
]);

/// Serializes live-link and Play-referrer redemption around one durable value.
///
/// [active] remains persisted while its RPC is in flight. A process death
/// therefore restores it as pending, and the idempotent server RPC can retry it.
class RedeemCoordinator {
  static const defaultRetryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
  ];

  final SaveRedeemSnapshot _saveSnapshot;
  final RedeemCode _redeemCode;
  final bool Function() _onboardingReady;
  final RedeemDelay _delay;
  final List<Duration> retryDelays;
  final RedeemAnalytics? _onAnalyticsEvent;

  late RedeemSnapshot _snapshot;
  Future<void> _stateTail = Future.value();
  Future<void>? _runner;
  bool _runRequested = false;
  bool _inFlight = false;
  int _retryIndex = 0;
  bool _disposed = false;

  RedeemCoordinator({
    required LoadRedeemSnapshot loadSnapshot,
    required SaveRedeemSnapshot saveSnapshot,
    required RedeemCode redeemCode,
    required bool Function() onboardingReady,
    RedeemDelay? delay,
    this.retryDelays = defaultRetryDelays,
    RedeemAnalytics? onAnalyticsEvent,
  })  : _saveSnapshot = saveSnapshot,
        _redeemCode = redeemCode,
        _onboardingReady = onboardingReady,
        _delay = delay ?? Future<void>.delayed,
        _onAnalyticsEvent = onAnalyticsEvent {
    _snapshot = RedeemSnapshot.decode(loadSnapshot());
  }

  RedeemSnapshot get snapshot => _snapshot;

  Future<void> enqueueLiveLink(String code) =>
      _enqueue(RedeemInput(code, RedeemSource.liveLink));

  Future<void> enqueueInstallReferrer(String code) =>
      _enqueue(RedeemInput(code, RedeemSource.installReferrer));

  /// Records a successful organic/malformed referrer fetch. Fetch failures must
  /// not call this, because they remain eligible for a later public [retry].
  Future<void> markInstallReferrerHandled() async {
    final changed = await _synchronized(() async {
      if (_snapshot.handled) return false;
      var active = _snapshot.active;
      var queued = _snapshot.queued;
      if (!_inFlight && active?.source == RedeemSource.installReferrer) {
        active = queued?.source == RedeemSource.liveLink ? queued : null;
        queued = null;
      } else if (queued?.source == RedeemSource.installReferrer) {
        queued = null;
      }
      await _persist(RedeemSnapshot(
        handled: true,
        active: active,
        queued: queued,
      ));
      return true;
    });
    if (changed) await _requestRun(resetBackoff: true);
  }

  /// Triggered by onboarding readiness, foreground, and connectivity recovery.
  /// It rearms the bounded retry series without allowing concurrent RPCs.
  Future<void> retry() => _requestRun(resetBackoff: true);

  Future<void> _enqueue(RedeemInput input) async {
    final changed = await _synchronized(() async {
      if (input.source == RedeemSource.installReferrer &&
          _snapshot.handled) {
        return false;
      }
      if (_snapshot.active == input || _snapshot.queued == input) return false;

      final active = _snapshot.active;
      final queued = _snapshot.queued;
      late final RedeemSnapshot next;
      if (active == null) {
        next = RedeemSnapshot(
          handled: _snapshot.handled,
          active: input,
          queued: queued,
        );
      } else if (input.source == RedeemSource.liveLink &&
          active.source == RedeemSource.installReferrer &&
          !_inFlight) {
        next = RedeemSnapshot(
          handled: true,
          active: input,
        );
      } else if (queued == null) {
        next = RedeemSnapshot(
          handled: _snapshot.handled,
          active: active,
          queued: input,
        );
      } else if (input.source == RedeemSource.liveLink) {
        next = RedeemSnapshot(
          handled: _snapshot.handled ||
              queued.source == RedeemSource.installReferrer,
          active: active,
          queued: input,
        );
      } else {
        return false;
      }

      await _persist(next);
      return true;
    });
    if (changed) await _requestRun(resetBackoff: true);
  }

  Future<void> _requestRun({bool resetBackoff = false}) {
    if (_disposed) return Future.value();
    if (resetBackoff) _retryIndex = 0;
    _runRequested = true;
    final running = _runner;
    if (running != null) return running;

    late final Future<void> future;
    future = _drainRunRequests().whenComplete(() async {
      if (identical(_runner, future)) _runner = null;
      if (_runRequested && !_disposed) await _requestRun();
    });
    _runner = future;
    return future;
  }

  Future<void> _drainRunRequests() async {
    while (_runRequested && !_disposed) {
      _runRequested = false;
      await _runUntilBlocked();
    }
  }

  Future<void> _runUntilBlocked() async {
    while (!_disposed) {
      final input = await _takeReadyActive();
      if (input == null) return;

      _log('referral_redeem_attempt', {'source': input.source.name});
      RedeemResult? result;
      Object? failure;
      try {
        result = await _redeemCode(input.code);
      } catch (error) {
        failure = error;
      }

      final disposition = await _completeAttempt(input, result);
      if (disposition == _AttemptDisposition.terminal ||
          disposition == _AttemptDisposition.promoted) {
        _retryIndex = 0;
        continue;
      }

      _log('referral_redeem_failure', {
        'source': input.source.name,
        'reason': failure == null ? result!.status.name : 'exception',
      });
      if (!_isReady(input) || _retryIndex >= retryDelays.length) return;
      final retryDelay = retryDelays[_retryIndex++];
      await _delay(retryDelay);
    }
  }

  Future<RedeemInput?> _takeReadyActive() => _synchronized(() async {
        if (_inFlight) return null;
        final input = _snapshot.active;
        if (input == null || !_isReady(input)) return null;
        _inFlight = true;
        return input;
      });

  bool _isReady(RedeemInput _) => _onboardingReady();

  Future<_AttemptDisposition> _completeAttempt(
    RedeemInput input,
    RedeemResult? result,
  ) =>
      _synchronized(() async {
        try {
          final terminal = result != null &&
              (result.status == RedeemStatus.ok ||
                  result.status == RedeemStatus.self ||
                  result.status == RedeemStatus.invalidCode);
          if (terminal) {
            final queued = _snapshot.queued;
            final dropQueuedReferrer =
                queued?.source == RedeemSource.installReferrer &&
                    (input.source == RedeemSource.installReferrer ||
                        result.status == RedeemStatus.ok);
            await _persist(RedeemSnapshot(
              handled: _snapshot.handled ||
                  input.source == RedeemSource.installReferrer ||
                  dropQueuedReferrer,
              active: dropQueuedReferrer ? null : queued,
            ));
            _log('referral_redeem_result', {
              'source': input.source.name,
              'result': result.status.name,
            });
            return _AttemptDisposition.terminal;
          }

          final queued = _snapshot.queued;
          if (input.source == RedeemSource.installReferrer &&
              queued?.source == RedeemSource.liveLink) {
            await _persist(RedeemSnapshot(
              handled: true,
              active: queued,
            ));
            return _AttemptDisposition.promoted;
          }

          // The value is deliberately rewritten even though active stays
          // pending: every state-machine transition has one durable snapshot.
          await _persist(_snapshot);
          return _AttemptDisposition.transient;
        } finally {
          _inFlight = false;
        }
      });

  Future<void> _persist(RedeemSnapshot next) async {
    await _saveSnapshot(next.encode());
    _snapshot = next;
  }

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _stateTail = _stateTail.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  void _log(String name, [Map<String, Object?>? params]) {
    try {
      _onAnalyticsEvent?.call(name, params);
    } catch (_) {
      // Observability must not affect redemption.
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _runRequested = false;
    final running = _runner;
    if (running != null) await running;
  }
}

enum _AttemptDisposition { terminal, transient, promoted }
