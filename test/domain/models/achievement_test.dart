import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/models/achievement.dart';
import 'package:connect_merge/domain/models/difficulty.dart';

void main() {
  group('Achievement unlock truth tables (pure)', () {
    test('firstLegendaryClear: needs tier 11 on legendary, not before', () {
      expect(
          Achievement.firstLegendaryClear.isUnlocked(const PlayerProgress(
              bestTierByDifficulty: {Difficulty.legendary: 10})),
          isFalse);
      expect(
          Achievement.firstLegendaryClear.isUnlocked(const PlayerProgress(
              bestTierByDifficulty: {Difficulty.legendary: 11})),
          isTrue);
      // tier 11 on a different difficulty does NOT unlock it.
      expect(
          Achievement.firstLegendaryClear.isUnlocked(const PlayerProgress(
              bestTierByDifficulty: {Difficulty.easy: 11})),
          isFalse);
    });

    test('sevenDayStreak: at exactly 7, not at 6', () {
      expect(
          Achievement.sevenDayStreak
              .isUnlocked(const PlayerProgress(dailyActiveStreak: 6)),
          isFalse);
      expect(
          Achievement.sevenDayStreak
              .isUnlocked(const PlayerProgress(dailyActiveStreak: 7)),
          isTrue);
    });

    test('thirtyDayStreak: at exactly 30, not at 29', () {
      expect(
          Achievement.thirtyDayStreak
              .isUnlocked(const PlayerProgress(dailyActiveStreak: 29)),
          isFalse);
      expect(
          Achievement.thirtyDayStreak
              .isUnlocked(const PlayerProgress(dailyActiveStreak: 30)),
          isTrue);
    });

    test('topTenFinish: locked while rank absent; unlocks at rank <= 10', () {
      // Absent rank (never fetched) -> stays locked, never errors.
      expect(
          Achievement.topTenFinish.isUnlocked(const PlayerProgress()), isFalse);
      expect(
          Achievement.topTenFinish.isUnlocked(const PlayerProgress(
              bestRankByDifficulty: {Difficulty.hard: 11})),
          isFalse);
      expect(
          Achievement.topTenFinish.isUnlocked(const PlayerProgress(
              bestRankByDifficulty: {Difficulty.hard: 10})),
          isTrue);
      expect(
          Achievement.topTenFinish.isUnlocked(const PlayerProgress(
              bestRankByDifficulty: {Difficulty.hard: 1})),
          isTrue);
    });

    test('tierMaster: needs >=7 streak on EVERY tier', () {
      final allSeven = {for (final d in Difficulty.values) d: 7};
      expect(
          Achievement.tierMaster
              .isUnlocked(PlayerProgress(perTierStreak: allSeven)),
          isTrue);
      // Drop one tier below 7 -> locked.
      final missingOne = Map<Difficulty, int>.from(allSeven)
        ..[Difficulty.legendary] = 6;
      expect(
          Achievement.tierMaster
              .isUnlocked(PlayerProgress(perTierStreak: missingOne)),
          isFalse);
    });

    test('highRoller: reach tier 10 on any tier', () {
      expect(
          Achievement.highRoller.isUnlocked(const PlayerProgress(
              bestTierByDifficulty: {Difficulty.easy: 9})),
          isFalse);
      expect(
          Achievement.highRoller.isUnlocked(const PlayerProgress(
              bestTierByDifficulty: {Difficulty.easy: 10})),
          isTrue);
    });
  });

  group('aggregate helpers', () {
    test('unlockedFor returns exactly the satisfied achievements', () {
      const p = PlayerProgress(dailyActiveStreak: 7);
      final set = unlockedFor(p);
      expect(set, contains(Achievement.sevenDayStreak));
      expect(set, isNot(contains(Achievement.thirtyDayStreak)));
      expect(set, isNot(contains(Achievement.firstLegendaryClear)));
    });

    test('newlyUnlocked is the difference vs already-unlocked', () {
      const p = PlayerProgress(dailyActiveStreak: 7);
      // Already had the 7-day badge -> nothing new.
      expect(newlyUnlocked(p, {Achievement.sevenDayStreak}), isEmpty);
      // Nothing recorded -> the 7-day badge is new.
      expect(newlyUnlocked(p, const {}), {Achievement.sevenDayStreak});
    });
  });
}
