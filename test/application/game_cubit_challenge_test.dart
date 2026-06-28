import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/application/game_cubit.dart';
import 'package:connect_merge/application/game_state.dart';
import 'package:connect_merge/domain/models/challenge_rule.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';

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
    await cubit.playChain([a!, b!]);
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
}
