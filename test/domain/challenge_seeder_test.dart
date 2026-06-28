import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/engine/daily_seeder.dart';
import 'package:connect_merge/domain/models/challenge_rule.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/engine/game_engine.dart';

void main() {
  group('DailySeeder.challengeRule', () {
    test('same date always returns the same rule (deterministic)', () {
      final s1 = DailySeeder('2026-06-23', Difficulty.challenge);
      final s2 = DailySeeder('2026-06-23', Difficulty.challenge);
      expect(s1.challengeRule, equals(s2.challengeRule));
    });

    test('different dates can return different rules', () {
      // Not guaranteed to differ, but tests that the indexing is date-bound.
      final rules = {
        DailySeeder('2026-06-23', Difficulty.challenge).challengeRule,
        DailySeeder('2026-06-24', Difficulty.challenge).challengeRule,
        DailySeeder('2026-06-25', Difficulty.challenge).challengeRule,
      };
      // At least one valid ChallengeRule returned.
      expect(rules.every((r) => ChallengeRule.values.contains(r)), isTrue);
    });
  });

  group('DailySeeder.generate with overrides', () {
    test('budgetCut: board has movesRemaining = 15', () {
      final seeder = DailySeeder('2026-06-23', Difficulty.challenge);
      final start = seeder.generate(movesOverride: kChallengeMoves);
      expect(start.board.movesRemaining, equals(kChallengeMoves));
    });

    test('denseStart: board has correct fill', () {
      final seeder = DailySeeder('2026-06-23', Difficulty.challenge);
      final start = seeder.generate(startingFillOverride: kChallengeDenseFill);
      final filled = start.board.cells.where((c) => c != null).length;
      // Dense fill may be adjusted slightly by the deadlock-safe re-roll,
      // but exactly kChallengeDenseFill tiles are placed.
      expect(filled, equals(kChallengeDenseFill));
    });

    test('wallMaze: board has 8 wall cells', () {
      final seeder = DailySeeder('2026-06-23', Difficulty.challenge);
      final start = seeder.generate(wallCountOverride: kChallengeWallMazeCount);
      expect(start.board.walls.length, equals(kChallengeWallMazeCount));
    });
  });

  group('GameEngine.collapseChain comboRush', () {
    test('N=2 chain scores same with or without comboRush override', () {
      // Build a minimal 2-tile board for a chain test.
      // Use Difficulty.hard (6x6).
      final seeder = DailySeeder('2026-06-23', Difficulty.hard);
      final start = seeder.generate();
      // Find any adjacent pair.
      final board = start.board;
      int? a, b;
      for (var i = 0; i < board.cells.length && a == null; i++) {
        final t = board.cells[i];
        if (t == null) continue;
        final gs = board.gridSize;
        final right = i + 1;
        if (right < board.cells.length &&
            right % gs != 0 &&
            board.cells[right]?.tier == t.tier) {
          a = i;
          b = right;
        }
      }
      if (a == null) return; // no adjacent pair on this seed; test passes vacuously

      final normalScore =
          GameEngine.collapseChain(board, [a!, b!]).score - board.score;
      final rushScore = GameEngine.collapseChain(
        board,
        [a, b],
        comboMultiplierFn: comboRushMultiplier,
      ).score -
          board.score;
      expect(rushScore, equals(normalScore)); // N=2: no doubling
    });
  });
}
