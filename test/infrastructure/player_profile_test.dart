import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/weekly_prize.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PlayerProfile weekly prize fields', () {
    test('empty profile has null lastWeeklyPrizeDate', () {
      expect(PlayerProfile.empty.prizes.lastWeeklyPrizeDate, isNull);
    });

    test('empty profile has empty weeklyPrizes', () {
      expect(PlayerProfile.empty.prizes.weeklyPrizes, isEmpty);
    });

    test('empty profile has null lastChallengeCheckDate', () {
      expect(PlayerProfile.empty.prizes.lastChallengeCheckDate, isNull);
    });

    test('copyWith updates lastWeeklyPrizeDate', () {
      final p = PlayerProfile.empty.copyWith(
        prizes: PlayerProfile.empty.prizes.copyWith(
          lastWeeklyPrizeDate: '2026-06-22',
        ),
      );
      expect(p.prizes.lastWeeklyPrizeDate, equals('2026-06-22'));
    });

    test('copyWith updates weeklyPrizes', () {
      const prize = WeeklyPrize(weekStart: '2026-06-22', tier: Difficulty.hard, rank: 1);
      final p = PlayerProfile.empty.copyWith(
        prizes: PlayerProfile.empty.prizes.copyWith(weeklyPrizes: [prize]),
      );
      expect(p.prizes.weeklyPrizes.length, equals(1));
      expect(p.prizes.weeklyPrizes.first.rank, equals(1));
    });

    test('copyWith updates lastChallengeCheckDate', () {
      final p = PlayerProfile.empty.copyWith(
        prizes: PlayerProfile.empty.prizes.copyWith(
          lastChallengeCheckDate: '2026-06-22',
        ),
      );
      expect(p.prizes.lastChallengeCheckDate, equals('2026-06-22'));
    });

    test('JSON round-trip preserves weekly prizes', () {
      const prize = WeeklyPrize(weekStart: '2026-06-22', tier: Difficulty.hard, rank: 2);
      final p = PlayerProfile.empty.copyWith(
        prizes: PlayerProfile.empty.prizes.copyWith(
          lastWeeklyPrizeDate: '2026-06-22',
          weeklyPrizes: [prize],
          lastChallengeCheckDate: '2026-06-21',
        ),
      );
      final decoded = PlayerProfile.fromJson(p.toJson());
      expect(decoded.prizes.lastWeeklyPrizeDate, equals('2026-06-22'));
      expect(decoded.prizes.weeklyPrizes.length, equals(1));
      expect(decoded.prizes.weeklyPrizes.first.tier, equals(Difficulty.hard));
      expect(decoded.prizes.lastChallengeCheckDate, equals('2026-06-21'));
    });

    test('fromJson with missing fields uses migration-free defaults', () {
      final p = PlayerProfile.fromJson({});
      expect(p.prizes.lastWeeklyPrizeDate, isNull);
      expect(p.prizes.weeklyPrizes, isEmpty);
      expect(p.prizes.lastChallengeCheckDate, isNull);
    });
  });
}
