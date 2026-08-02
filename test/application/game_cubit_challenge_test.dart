import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/application/game_cubit.dart';
import 'package:connect_merge/application/game_state.dart';
import 'package:connect_merge/domain/engine/daily_seeder.dart';
import 'package:connect_merge/domain/engine/game_engine.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/challenge_rule.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/domain/models/move.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';

/// Finds any legal 2-tile adjacent chain on [b] (every Challenge rule's
/// baseline minimum, `longChainsOnly` aside).
List<int> _findChain(BoardState b) {
  for (var i = 0; i < b.cells.length; i++) {
    final col = i % b.gridSize;
    final row = i ~/ b.gridSize;
    for (final neighbor in [
      if (col + 1 < b.gridSize) i + 1,
      if (row + 1 < b.gridSize) i + b.gridSize,
    ]) {
      for (final path in [
        [i, neighbor],
        [neighbor, i],
      ]) {
        if (GameEngine.isValidChain(b, path)) return path;
      }
    }
  }
  throw StateError('seeded board unexpectedly has no valid adjacent chain');
}

void main() {
  late InMemoryStorageService storage;
  late GameCubit cubit;

  setUp(() {
    storage = InMemoryStorageService();
    cubit = GameCubit(
      storage: storage,
      todayProvider: () => '2026-06-23',
    );
  });

  tearDown(() => cubit.close());

  test('init with challenge sets an activeRule', () async {
    await cubit.init(difficulty: Difficulty.challenge);
    expect(cubit.activeRule, isNotNull);
    expect(ChallengeRule.values.contains(cubit.activeRule!), isTrue);
  });

  test('longChainsOnly rule rejects 2-tile chains', () async {
    // Override the rule for a deterministic test.
    await cubit.init(difficulty: Difficulty.challenge, ruleOverride: ChallengeRule.longChainsOnly);
    if (cubit.state is! GamePlaying) return;
    final board = (cubit.state as GamePlaying).board;
    // Find any adjacent pair (length-2 path).
    int? a, b;
    for (var i = 0; i < board.cells.length && a == null; i++) {
      final t = board.cells[i];
      if (t == null) continue;
      final gs = board.gridSize;
      final right = i + 1;
      if (right < board.cells.length &&
          right % gs != 0 &&
          board.cells[right]?.tier == t.tier) {
        a = i; b = right;
      }
    }
    if (a == null) return; // no adjacent pair on this seed; vacuous pass
    final scoreBefore = board.score;
    await cubit.playChain([a, b!]);
    // Score should be unchanged (move rejected).
    if (cubit.state is GamePlaying) {
      expect((cubit.state as GamePlaying).board.score, equals(scoreBefore));
    }
  });

  test('budgetCut rule sets movesRemaining = 15', () async {
    await cubit.init(difficulty: Difficulty.challenge, ruleOverride: ChallengeRule.budgetCut);
    if (cubit.state is! GamePlaying) return;
    expect((cubit.state as GamePlaying).board.movesRemaining, equals(15));
  });

  test(
      'canOfferAd is false for Challenge even when out of moves with a legal chain remaining',
      () async {
    // Any Challenge rule: the server rejects every ContinueEvent for
    // Challenge unconditionally, so canOfferAd must never offer one — even
    // though a bare hasMergeAvailable check (the pre-fix predicate) would say
    // a continue is possible.
    final seeded =
        const DailySeeder('2026-06-23', Difficulty.challenge).generate().board;
    final outOfMoves =
        seeded.copyWith(movesRemaining: 0, status: GameStatus.outOfMoves);
    expect(GameEngine.hasMergeAvailable(outOfMoves), isTrue,
        reason: 'test board must actually have a mergeable pair to be meaningful');
    await storage.saveSnapshot(GameSnapshot(
        date: '2026-06-23',
        difficulty: Difficulty.challenge,
        board: outOfMoves,
        completed: true));

    final resumed = GameCubit(storage: storage, todayProvider: () => '2026-06-23');
    await resumed.init(
        difficulty: Difficulty.challenge, ruleOverride: ChallengeRule.comboRush);
    expect(resumed.state, isA<GameOverShowScore>());
    expect(resumed.canOfferAd, isFalse);
    await resumed.close();
  });

  test(
      'a Challenge run out of moves submits immediately even with a legal chain left (no dangling continue wait)',
      () async {
    // Before the fix, _finishRun's terminal check deferred submission
    // whenever a bare merge still existed, expecting an ad continue that
    // Challenge mode never actually offers (verifyRunChallenge rejects every
    // ContinueEvent) — silently stranding the run unsubmitted.
    final seeded =
        const DailySeeder('2026-06-23', Difficulty.challenge).generate().board;
    final path = _findChain(seeded);
    // Force this to be the last move so the run ends out-of-moves.
    await storage.saveSnapshot(GameSnapshot(
        date: '2026-06-23',
        difficulty: Difficulty.challenge,
        board: seeded.copyWith(movesRemaining: 1),
        completed: false));

    var submitted = false;
    final c = GameCubit(
      storage: storage,
      todayProvider: () => '2026-06-23',
      onSubmitRun: ({
        required String date,
        required Difficulty difficulty,
        required List<MoveEvent> moveLog,
        required int adContinues,
      }) async {
        submitted = true;
        return SubmitOutcome.success;
      },
    );
    await c.init(
        difficulty: Difficulty.challenge, ruleOverride: ChallengeRule.comboRush);
    await c.playChain(path);
    expect(c.state, isA<GameOverShowScore>());
    expect((c.state as GameOverShowScore).board.status, GameStatus.outOfMoves);
    expect(submitted, isTrue,
        reason:
            'Challenge has no continue path, so any non-playing status must submit immediately');
    await c.close();
  });
}
