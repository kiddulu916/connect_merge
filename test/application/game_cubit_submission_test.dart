import 'dart:async';

import 'package:connect_merge/application/game_cubit.dart';
import 'package:connect_merge/application/game_state.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/engine/daily_seeder.dart';
import 'package:connect_merge/domain/engine/game_engine.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/domain/models/move.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _date = '2026-07-18';
const _difficulty = Difficulty.easy;

void main() {
  test('success persists pending before the call then settles with analytics',
      () async {
    final storage = _RecordingSubmitStorage();
    await _saveCompleted(storage, _terminalBoard());
    final called = Completer<void>();
    final release = Completer<void>();
    final events = <MapEntry<String, Map<String, Object?>?>>[];
    final cubit = GameCubit(
      storage: storage,
      todayProvider: () => _date,
      onSubmitRun: _blockingSubmit(called, release, SubmitOutcome.success),
      onAnalyticsEvent: (name, [params]) => events.add(MapEntry(name, params)),
    );

    final init = cubit.init(difficulty: _difficulty);
    await called.future;
    expect(storage.loadSubmitStatus(_date, _difficulty),
        const SubmitStatusRecord(SubmitStatus.pending, generation: 0));
    release.complete();
    await init;

    expect(storage.statusWrites, [SubmitStatus.pending, SubmitStatus.settled]);
    expect(storage.loadSubmitStatus(_date, _difficulty),
        const SubmitStatusRecord(SubmitStatus.settled, generation: 0));
    expect(
      events.where((event) => event.key.startsWith('score_submit')).map(
            (event) => {'name': event.key, ...?event.value},
          ),
      [
        {
          'name': 'score_submit_attempt',
          'difficulty': 'easy',
          'season': kLeaderboardSeason,
        },
        {
          'name': 'score_submit_result',
          'difficulty': 'easy',
          'season': kLeaderboardSeason,
          'outcome': 'success',
        },
      ],
    );
    await cubit.close();
  });

  test('terminal rejection settles and reports a nonfatal parity marker',
      () async {
    final storage = _RecordingSubmitStorage();
    await _saveCompleted(storage, _terminalBoard());
    Object? reported;
    bool? reportedFatal;
    final events = <Map<String, Object?>>[];
    final cubit = GameCubit(
      storage: storage,
      todayProvider: () => _date,
      onSubmitRun: _submitWith(SubmitOutcome.terminalRejection),
      onError: (error, stack, {fatal = false}) {
        reported = error;
        reportedFatal = fatal;
      },
      onAnalyticsEvent: (name, [params]) =>
          events.add({'name': name, ...?params}),
    );

    await cubit.init(difficulty: _difficulty);

    expect(storage.loadSubmitStatus(_date, _difficulty).status,
        SubmitStatus.settled);
    expect(reported.toString(), contains('score_submit_terminal_rejection'));
    expect(reportedFatal, isFalse);
    expect(
      events.last,
      {
        'name': 'score_submit_result',
        'difficulty': 'easy',
        'season': kLeaderboardSeason,
        'outcome': 'terminal-rejection',
      },
    );
    await cubit.close();
  });

  test('retryable outcome and thrown exception both remain pending', () async {
    for (final throws in [false, true]) {
      final storage = _RecordingSubmitStorage();
      await _saveCompleted(storage, _terminalBoard());
      Object? reported;
      final outcomes = <Object?>[];
      final cubit = GameCubit(
        storage: storage,
        todayProvider: () => _date,
        onSubmitRun: throws
            ? ({
                required date,
                required difficulty,
                required moveLog,
                required adContinues,
              }) async =>
                throw StateError('offline')
            : _submitWith(SubmitOutcome.retryableFailure),
        onError: (error, stack, {fatal = false}) => reported = error,
        onAnalyticsEvent: (name, [params]) {
          if (name == 'score_submit_result') {
            outcomes.add(params?['outcome']);
          }
        },
      );

      await cubit.init(difficulty: _difficulty);

      expect(storage.loadSubmitStatus(_date, _difficulty).status,
          SubmitStatus.pending);
      expect(reported, throws ? isA<StateError>() : isNull);
      expect(outcomes, ['retryable-failure']);
      await cubit.close();
    }
  });

  test('pending survives an offline exit and retries on online relaunch',
      () async {
    final storage = _RecordingSubmitStorage();
    await _saveCompleted(storage, _continueEligibleBoard());
    final offline = GameCubit(
      storage: storage,
      todayProvider: () => _date,
    );
    await offline.init(difficulty: _difficulty);
    await offline.submitIfPending();
    expect(storage.loadSubmitStatus(_date, _difficulty),
        const SubmitStatusRecord(SubmitStatus.pending, generation: 0));
    await offline.close();

    var calls = 0;
    final online = GameCubit(
      storage: storage,
      todayProvider: () => _date,
      onSubmitRun: ({
        required date,
        required difficulty,
        required moveLog,
        required adContinues,
      }) async {
        calls++;
        return SubmitOutcome.success;
      },
    );
    await online.init(difficulty: _difficulty);

    expect(calls, 1);
    expect(storage.loadSubmitStatus(_date, _difficulty).status,
        SubmitStatus.settled);
    await online.close();
  });

  test(
      'resume retries pending and terminal none, but not continue-eligible none',
      () async {
    Future<int> resume(
      BoardState board, {
      SubmitStatus status = SubmitStatus.none,
      int generation = 0,
    }) async {
      final storage = InMemoryStorageService();
      await _saveCompleted(storage, board);
      await storage.saveSubmitStatus(_date, _difficulty, status, generation);
      var calls = 0;
      final cubit = GameCubit(
        storage: storage,
        todayProvider: () => _date,
        onSubmitRun: ({
          required date,
          required difficulty,
          required moveLog,
          required adContinues,
        }) async {
          calls++;
          return SubmitOutcome.success;
        },
      );
      await cubit.init(difficulty: _difficulty);
      await cubit.close();
      return calls;
    }

    expect(
      await resume(_continueEligibleBoard(),
          status: SubmitStatus.pending, generation: 7),
      1,
    );
    expect(await resume(_terminalBoard()), 1);
    expect(await resume(_continueEligibleBoard()), 0);
  });

  test('resumed settled status seeds the in-memory no-op guard', () async {
    final storage = InMemoryStorageService();
    await _saveCompleted(storage, _terminalBoard());
    await storage.saveSubmitStatus(_date, _difficulty, SubmitStatus.settled, 2);
    var calls = 0;
    final cubit = GameCubit(
      storage: storage,
      todayProvider: () => _date,
      onSubmitRun: ({
        required date,
        required difficulty,
        required moveLog,
        required adContinues,
      }) async {
        calls++;
        return SubmitOutcome.success;
      },
    );

    await cubit.init(difficulty: _difficulty);
    await cubit.submitIfPending();

    expect(calls, 0);
    await cubit.close();
  });

  test('resume and explicit submit coalesce the full attempt', () async {
    final storage = _RecordingSubmitStorage();
    await _saveCompleted(storage, _continueEligibleBoard());
    await storage.saveSubmitStatus(_date, _difficulty, SubmitStatus.pending, 4);
    storage.statusWrites.clear();
    final called = Completer<void>();
    final release = Completer<void>();
    var calls = 0;
    final events = <String>[];
    final cubit = GameCubit(
      storage: storage,
      todayProvider: () => _date,
      onSubmitRun: ({
        required date,
        required difficulty,
        required moveLog,
        required adContinues,
      }) async {
        calls++;
        called.complete();
        await release.future;
        return SubmitOutcome.success;
      },
      onAnalyticsEvent: (name, [params]) {
        if (name.startsWith('score_submit')) events.add(name);
      },
    );

    final resumed = cubit.init(difficulty: _difficulty);
    await called.future;
    final explicit = cubit.submitIfPending();
    release.complete();
    await Future.wait([resumed, explicit]);

    expect(calls, 1);
    expect(storage.statusWrites, [SubmitStatus.pending, SubmitStatus.settled]);
    expect(events, ['score_submit_attempt', 'score_submit_result']);
    await cubit.close();
  });

  test(
      'continued board invalidates a stale result and its improved run submits',
      () async {
    final storage = InMemoryStorageService();
    await _saveCompleted(storage, _continueEligibleBoard());
    await storage.saveSubmitStatus(_date, _difficulty, SubmitStatus.pending, 1);
    final called = Completer<void>();
    final release = Completer<void>();
    final submittedLogs = <List<MoveEvent>>[];
    var calls = 0;
    final first = GameCubit(
      storage: storage,
      todayProvider: () => _date,
      onSubmitRun: ({
        required date,
        required difficulty,
        required moveLog,
        required adContinues,
      }) async {
        calls++;
        submittedLogs.add(moveLog);
        called.complete();
        await release.future;
        return SubmitOutcome.success;
      },
    );

    final resumed = first.init(difficulty: _difficulty);
    await called.future;
    await first.grantAdReward();
    final continued = (first.state as GamePlaying).board;
    release.complete();
    await resumed;

    expect(storage.loadSubmitStatus(_date, _difficulty),
        const SubmitStatusRecord(SubmitStatus.none, generation: 2));
    final storedAfterContinue = storage.loadSnapshot(_date, _difficulty)!;
    expect(storedAfterContinue.completed, isFalse);
    expect(storedAfterContinue.board, continued);
    await first.close();

    final nearDone = continued.copyWith(
      movesRemaining: 1,
      adContinuesUsed: kMaxAdContinuesPerDay,
    );
    await storage.saveSnapshot(GameSnapshot(
      date: _date,
      difficulty: _difficulty,
      board: nearDone,
      completed: false,
    ));
    final second = GameCubit(
      storage: storage,
      todayProvider: () => _date,
      onSubmitRun: ({
        required date,
        required difficulty,
        required moveLog,
        required adContinues,
      }) async {
        calls++;
        submittedLogs.add(moveLog);
        return SubmitOutcome.success;
      },
    );
    await second.init(difficulty: _difficulty);
    await second.playChain(_findChain((second.state as GamePlaying).board));

    expect(calls, 2);
    expect(submittedLogs.last.length, greaterThan(submittedLogs.first.length));
    expect(storage.loadSubmitStatus(_date, _difficulty),
        const SubmitStatusRecord(SubmitStatus.settled, generation: 3));
    await second.close();
  });

  test(
      'a submission that outlives an account switch does not settle under the new account',
      () async {
    final storage = InMemoryStorageService();
    await storage.rebindOwner('account-a');
    await _saveCompleted(storage, _terminalBoard());
    final called = Completer<void>();
    final release = Completer<void>();
    final cubit = GameCubit(
      storage: storage,
      todayProvider: () => _date,
      onSubmitRun: ({
        required date,
        required difficulty,
        required moveLog,
        required adContinues,
      }) async {
        called.complete();
        await release.future;
        return SubmitOutcome.success;
      },
    );

    final init = cubit.init(difficulty: _difficulty);
    await called.future;
    expect(storage.loadSubmitStatus(_date, _difficulty).status,
        SubmitStatus.pending);

    // Simulate an account switch happening while the submission is in
    // flight, after the "pending" write already landed under account A.
    await storage.rebindOwner('account-b');

    release.complete();
    await init;

    // The stale attempt must NOT have settled under account B's record.
    expect(storage.loadSubmitStatus(_date, _difficulty).status,
        SubmitStatus.pending);
    await cubit.close();
  });

  test('a submission that completes before any account change settles normally',
      () async {
    final storage = InMemoryStorageService();
    await storage.rebindOwner('account-a');
    await _saveCompleted(storage, _terminalBoard());
    final cubit = GameCubit(
      storage: storage,
      todayProvider: () => _date,
      onSubmitRun: ({
        required date,
        required difficulty,
        required moveLog,
        required adContinues,
      }) async =>
          SubmitOutcome.success,
    );

    await cubit.init(difficulty: _difficulty);

    expect(storage.loadSubmitStatus(_date, _difficulty).status,
        SubmitStatus.settled);
    await cubit.close();
  });

  test(
      'an account switch during the pending-status write itself blocks the '
      'attempt from proceeding under the new account', () async {
    final storage = _PendingWriteBlockingStorage();
    await storage.rebindOwner('account-a');
    await _saveCompleted(storage, _terminalBoard());
    var hookCalled = false;
    final cubit = GameCubit(
      storage: storage,
      todayProvider: () => _date,
      onSubmitRun: ({
        required date,
        required difficulty,
        required moveLog,
        required adContinues,
      }) async {
        hookCalled = true;
        return SubmitOutcome.success;
      },
    );

    final init = cubit.init(difficulty: _difficulty);
    await storage.pendingWriteStarted.future;

    // Simulate an account switch landing while the pending-status write
    // (the very first persist point of the attempt) is still in flight.
    await storage.rebindOwner('account-b');
    storage.releasePendingWrite.complete();
    await init;

    // The stale attempt must not proceed past the pending write under the
    // new account: the submit hook is never invoked, and status is neither
    // settled nor otherwise mutated beyond the pending write that was
    // already in flight when the switch happened.
    expect(hookCalled, isFalse);
    expect(storage.loadSubmitStatus(_date, _difficulty).status,
        SubmitStatus.pending);
    await cubit.close();
  });
}

/// Blocks the first `pending`-status write until the test releases it, so a
/// test can simulate an account switch landing mid-await on that very write
/// — the persist point [_submitOnce] itself performs before any hook call.
class _PendingWriteBlockingStorage extends InMemoryStorageService {
  final Completer<void> pendingWriteStarted = Completer<void>();
  final Completer<void> releasePendingWrite = Completer<void>();
  bool _intercepted = false;

  @override
  Future<void> saveSubmitStatus(
    String date,
    Difficulty difficulty,
    SubmitStatus status,
    int generation,
  ) async {
    if (!_intercepted && status == SubmitStatus.pending) {
      _intercepted = true;
      pendingWriteStarted.complete();
      await releasePendingWrite.future;
    }
    await super.saveSubmitStatus(date, difficulty, status, generation);
  }
}

SubmitRun _submitWith(SubmitOutcome outcome) => ({
      required date,
      required difficulty,
      required moveLog,
      required adContinues,
    }) async =>
        outcome;

SubmitRun _blockingSubmit(
  Completer<void> called,
  Completer<void> release,
  SubmitOutcome outcome,
) =>
    ({
      required date,
      required difficulty,
      required moveLog,
      required adContinues,
    }) async {
      called.complete();
      await release.future;
      return outcome;
    };

BoardState _terminalBoard() => _continueEligibleBoard().copyWith(
      adContinuesUsed: kMaxAdContinuesPerDay,
    );

BoardState _continueEligibleBoard() =>
    const DailySeeder(_date, _difficulty).generate().board.copyWith(
          movesRemaining: 0,
          status: GameStatus.outOfMoves,
        );

Future<void> _saveCompleted(
  StorageService storage,
  BoardState board,
) =>
    storage.saveSnapshot(GameSnapshot(
      date: _date,
      difficulty: _difficulty,
      board: board,
      completed: true,
    ));

List<int> _findChain(BoardState board) {
  for (var i = 0; i < board.cells.length; i++) {
    final col = i % board.gridSize;
    final row = i ~/ board.gridSize;
    for (final neighbor in [
      if (col + 1 < board.gridSize) i + 1,
      if (row + 1 < board.gridSize) i + board.gridSize,
      if (row + 1 < board.gridSize && col + 1 < board.gridSize)
        i + board.gridSize + 1,
      if (row + 1 < board.gridSize && col - 1 >= 0) i + board.gridSize - 1,
    ]) {
      for (final path in [
        [i, neighbor],
        [neighbor, i],
      ]) {
        if (GameEngine.isValidChain(board, path)) return path;
      }
    }
  }
  throw StateError('seeded board unexpectedly has no valid chain');
}

class _RecordingSubmitStorage extends InMemoryStorageService {
  final List<SubmitStatus> statusWrites = [];

  @override
  Future<void> saveSubmitStatus(
    String date,
    Difficulty difficulty,
    SubmitStatus status,
    int generation,
  ) async {
    statusWrites.add(status);
    await super.saveSubmitStatus(date, difficulty, status, generation);
  }
}
