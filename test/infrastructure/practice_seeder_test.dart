import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/infrastructure/practice_seeder.dart';

void main() {
  group('PracticeSeeder produces valid, playable boards', () {
    test('each tier gets its correct starting fill + a full drop schedule', () {
      final seeder = PracticeSeeder(random: Random(123));
      for (final d in Difficulty.values) {
        final round = seeder.generate(d);
        final board = round.start.board;
        expect(board.filledCount, d.startingFill,
            reason: 'starting fill for ${d.name}');
        expect(board.movesRemaining, kMovesPerDay);
        expect(board.status, GameStatus.playing);
        expect(round.start.dropTiers.length, kMaxDrops);
        // All drop tiers are within the legal band.
        for (final t in round.start.dropTiers) {
          expect(t, inInclusiveRange(1, 6));
        }
      }
    });

    test('successive rounds use different random seed keys (endless variety)',
        () {
      final seeder = PracticeSeeder(random: Random(7));
      final a = seeder.generate(Difficulty.medium);
      final b = seeder.generate(Difficulty.medium);
      expect(a.seedKey, isNot(equals(b.seedKey)));
    });

    test('seed key is prefixed "practice:" so it can never be a daily key', () {
      final seeder = PracticeSeeder(random: Random(1));
      expect(seeder.nextSeedKey(Difficulty.easy), startsWith('practice:'));
    });
  });

  group('FAIRNESS INVARIANT #2: practice mode has NO submit/score path', () {
    // Static guarantee: neither the practice seeder nor the practice screen
    // reference any leaderboard-submit / score-write CODE path. A regression
    // that wired practice into the leaderboard would import one of these types
    // or call one of these methods and fail the test. We scan for code tokens
    // (not prose) so documentation can still describe the invariant.

    /// Strip Dart line + block comments so prose can't trip the scan.
    String stripComments(String src) {
      final noBlock =
          src.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
      final lines = noBlock
          .split('\n')
          .map((l) {
            final i = l.indexOf('//');
            return i >= 0 ? l.substring(0, i) : l;
          });
      return lines.join('\n');
    }

    test('practice_seeder.dart has no submit/leaderboard/score-write code', () {
      final code =
          stripComments(File('lib/infrastructure/practice_seeder.dart')
              .readAsStringSync());
      for (final token in const [
        'submitRun',
        'onSubmitRun',
        'LeaderboardService',
        'FriendsService',
        'saveStats',
        'saveSnapshot',
      ]) {
        expect(code.contains(token), isFalse, reason: 'must not use $token');
      }
    });

    test('practice_screen.dart has no submit/leaderboard/score-write code', () {
      final code =
          stripComments(File('lib/presentation/screens/practice_screen.dart')
              .readAsStringSync());
      for (final token in const [
        'submitRun',
        'onSubmitRun',
        'LeaderboardService',
        'FriendsService',
        'saveStats',
        'saveSnapshot',
        'onTierCompleted',
      ]) {
        expect(code.contains(token), isFalse, reason: 'must not use $token');
      }
    });
  });
}
