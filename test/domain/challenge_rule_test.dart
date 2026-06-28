import 'package:connect_merge/domain/models/challenge_rule.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/weekly_prize.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('comboRushMultiplier', () {
    test('N=2 returns same as comboMultiplier (not doubled)', () {
      expect(comboRushMultiplier(2), equals(comboMultiplier(2)));
    });
    test('N=3 returns doubled multiplier', () {
      expect(comboRushMultiplier(3), equals(comboMultiplier(3) * 2));
    });
    test('N=4 returns doubled multiplier', () {
      expect(comboRushMultiplier(4), equals(comboMultiplier(4) * 2));
    });
    test('N=1 returns 0 (invalid chain)', () {
      expect(comboRushMultiplier(1), equals(0));
    });
  });

  group('ChallengeRule', () {
    test('has 6 values', () {
      expect(ChallengeRule.values.length, equals(6));
    });
    test('labels are non-empty', () {
      for (final rule in ChallengeRule.values) {
        expect(rule.label, isNotEmpty);
      }
    });
  });

  group('WeeklyPrize', () {
    test('round-trips through JSON', () {
      const prize = WeeklyPrize(
        weekStart: '2026-06-22',
        tier: Difficulty.hard,
        rank: 1,
      );
      final json = prize.toJson();
      final decoded = WeeklyPrize.fromJson(json);
      expect(decoded.weekStart, equals('2026-06-22'));
      expect(decoded.tier, equals(Difficulty.hard));
      expect(decoded.rank, equals(1));
    });
  });
}
