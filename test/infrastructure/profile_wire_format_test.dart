import 'dart:convert';

import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('full profile wire format stays byte-identical', () {
    final fixture = <String, dynamic>{
      'dailyActiveStreak': 12,
      'lastActiveDate': '2026-07-17',
      'unlockedAchievements': ['firstMerge', 'sevenDayStreak'],
      'selectedCosmetic': 'ocean',
      'adUnlockedCosmetics': ['ember', 'forest'],
      'notificationsEnabled': true,
      'reminderMinutes': 615,
      'bestRankByDifficulty': {'easy': 2, 'hard': 7},
      'coins': 4321,
      'lastLootClaimDate': '2026-07-16',
      'purchasedCosmetics': ['royal', 'neon'],
      'lifetimeXp': 98765,
      'almanacCounts': {'3': 4, '11': 2},
      'rivalId': 'rival-42',
      'rivalName': 'Ada',
      'lastSeenRivalScoreByTier': {'medium': 2048, 'expert': 8192},
      'tutorialSeen': true,
      'colorblindMode': true,
      'lastWeeklyPrizeDate': '2026-07-13',
      'weeklyPrizes': [
        {'weekStart': '2026-07-13', 'tier': 'hard', 'rank': 2},
      ],
      'lastChallengeCheckDate': '2026-07-17',
      'lastDailyPrizeDate': '2026-07-17',
      'lastMonthlyPrizeMonth': '2026-06',
    };

    const golden =
        '{"dailyActiveStreak":12,"lastActiveDate":"2026-07-17","unlockedAchievements":["firstMerge","sevenDayStreak"],"selectedCosmetic":"ocean","adUnlockedCosmetics":["ember","forest"],"notificationsEnabled":true,"reminderMinutes":615,"bestRankByDifficulty":{"easy":2,"hard":7},"coins":4321,"lastLootClaimDate":"2026-07-16","purchasedCosmetics":["royal","neon"],"lifetimeXp":98765,"almanacCounts":{"3":4,"11":2},"rivalId":"rival-42","rivalName":"Ada","lastSeenRivalScoreByTier":{"medium":2048,"expert":8192},"tutorialSeen":true,"colorblindMode":true,"lastWeeklyPrizeDate":"2026-07-13","weeklyPrizes":[{"weekStart":"2026-07-13","tier":"hard","rank":2}],"lastChallengeCheckDate":"2026-07-17","lastDailyPrizeDate":"2026-07-17","lastMonthlyPrizeMonth":"2026-06"}';

    expect(jsonEncode(PlayerProfile.fromJson(fixture).toJson()), golden);
  });

  test('empty legacy profile keeps every migration-free default', () {
    expect(PlayerProfile.fromJson({}).toJson(), <String, dynamic>{
      'dailyActiveStreak': 0,
      'lastActiveDate': null,
      'unlockedAchievements': <String>[],
      'selectedCosmetic': 'classic',
      'adUnlockedCosmetics': <String>[],
      'notificationsEnabled': false,
      'reminderMinutes': 1140,
      'bestRankByDifficulty': <String, int>{},
      'coins': 0,
      'lastLootClaimDate': null,
      'purchasedCosmetics': <String>[],
      'lifetimeXp': 0,
      'almanacCounts': <String, int>{},
      'rivalId': null,
      'rivalName': null,
      'lastSeenRivalScoreByTier': <String, int>{},
      'tutorialSeen': false,
      'colorblindMode': false,
      'lastWeeklyPrizeDate': null,
      'weeklyPrizes': <Map<String, dynamic>>[],
      'lastChallengeCheckDate': null,
      'lastDailyPrizeDate': null,
      'lastMonthlyPrizeMonth': null,
    });
  });

  test('partial legacy profile defaults every later field', () {
    final fixture = <String, dynamic>{
      'dailyActiveStreak': 5,
      'lastActiveDate': '2026-07-01',
      'unlockedAchievements': ['firstMerge'],
      'selectedCosmetic': 'forest',
      'adUnlockedCosmetics': ['ember'],
      'notificationsEnabled': true,
      'reminderMinutes': 480,
      'bestRankByDifficulty': {'easy': 3},
    };

    expect(PlayerProfile.fromJson(fixture).toJson(), <String, dynamic>{
      'dailyActiveStreak': 5,
      'lastActiveDate': '2026-07-01',
      'unlockedAchievements': ['firstMerge'],
      'selectedCosmetic': 'forest',
      'adUnlockedCosmetics': ['ember'],
      'notificationsEnabled': true,
      'reminderMinutes': 480,
      'bestRankByDifficulty': {'easy': 3},
      'coins': 0,
      'lastLootClaimDate': null,
      'purchasedCosmetics': <String>[],
      'lifetimeXp': 0,
      'almanacCounts': <String, int>{},
      'rivalId': null,
      'rivalName': null,
      'lastSeenRivalScoreByTier': <String, int>{},
      'tutorialSeen': false,
      'colorblindMode': false,
      'lastWeeklyPrizeDate': null,
      'weeklyPrizes': <Map<String, dynamic>>[],
      'lastChallengeCheckDate': null,
      'lastDailyPrizeDate': null,
      'lastMonthlyPrizeMonth': null,
    });
  });
}
