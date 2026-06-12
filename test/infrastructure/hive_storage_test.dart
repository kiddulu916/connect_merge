import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:merge_count/domain/constants.dart';
import 'package:merge_count/domain/models/board_state.dart';
import 'package:merge_count/domain/models/difficulty.dart';
import 'package:merge_count/domain/models/game_status.dart';
import 'package:merge_count/domain/models/tile.dart';
import 'package:merge_count/infrastructure/hive_storage_service.dart';
import 'package:merge_count/infrastructure/storage_service.dart';

void main() {
  setUp(() {
    // Use a unique temp dir so each test run is isolated.
    Hive.init('${Directory.systemTemp.path}/merge_count_test_${DateTime.now().microsecondsSinceEpoch}');
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
  });

  test('persists and reloads a snapshot via Hive', () async {
    final s = HiveStorageService();
    await s.init();

    final board = BoardState(
      cells: List<Tile?>.filled(kCellCount, null),
      movesRemaining: 29,
      score: 16,
      nextTileId: 9,
      dropIndex: 1,
      adContinuesUsed: 0,
      movesMade: 1,
      status: GameStatus.playing,
    );
    await s.saveSnapshot(GameSnapshot(
        date: '2026-06-06',
        difficulty: Difficulty.hard,
        board: board,
        completed: false));

    final loaded = s.loadSnapshot('2026-06-06', Difficulty.hard)!;
    expect(loaded.date, '2026-06-06');
    expect(loaded.difficulty, Difficulty.hard);
    expect(loaded.board.score, 16);
    expect(loaded.board.dropIndex, 1);
    // A different tier on the same date is independent.
    expect(s.loadSnapshot('2026-06-06', Difficulty.easy), isNull);
  });

  test('stats persist per tier via Hive', () async {
    final s = HiveStorageService();
    await s.init();
    await s.saveStats(
        Difficulty.legendary,
        const LifetimeStats(
            streak: 5,
            lastCompletedDate: '2026-06-06',
            bestScore: 321,
            bestTier: 8));
    expect(s.loadStats(Difficulty.legendary).streak, 5);
    expect(s.loadStats(Difficulty.legendary).bestScore, 321);
    expect(s.loadStats(Difficulty.easy).streak, 0);
  });

  test('json encoding is stable', () {
    const stats = LifetimeStats(streak: 1, lastCompletedDate: '2026-06-06', bestScore: 10, bestTier: 3);
    expect(LifetimeStats.fromJson(jsonDecode(jsonEncode(stats.toJson())) as Map<String, dynamic>).bestScore, 10);
  });

  test('PlayerProfile persists and reloads via Hive (Phase 4)', () async {
    final s = HiveStorageService();
    await s.init();
    // Empty by default (migration-free).
    expect(s.loadProfile().dailyActiveStreak, 0);
    expect(s.loadProfile().selectedCosmetic, 'classic');

    // Phase 1 + Phase 2 fields default migration-free.
    expect(s.loadProfile().coins, 0);
    expect(s.loadProfile().purchasedCosmetics, isEmpty);
    expect(s.loadProfile().lifetimeXp, 0);
    expect(s.loadProfile().almanacCounts, isEmpty);

    const profile = PlayerProfile(
      dailyActiveStreak: 7,
      lastActiveDate: '2026-06-07',
      unlockedAchievements: {'sevenDayStreak'},
      selectedCosmetic: 'ocean',
      adUnlockedCosmetics: {'neon'},
      notificationsEnabled: true,
      reminderMinutes: 20 * 60,
      bestRankByDifficulty: {'hard': 3},
      coins: 250,
      lastLootClaimDate: '2026-06-07',
      purchasedCosmetics: {'forest'},
      lifetimeXp: 1234,
      almanacCounts: {'9': 2, '11': 1},
    );
    await s.saveProfile(profile);

    final loaded = s.loadProfile();
    expect(loaded.dailyActiveStreak, 7);
    expect(loaded.lastActiveDate, '2026-06-07');
    expect(loaded.unlockedAchievements, {'sevenDayStreak'});
    expect(loaded.selectedCosmetic, 'ocean');
    expect(loaded.adUnlockedCosmetics, {'neon'});
    expect(loaded.notificationsEnabled, isTrue);
    expect(loaded.reminderMinutes, 20 * 60);
    expect(loaded.bestRankByDifficulty, {'hard': 3});
    // Phase 1 + Phase 2 round-trip.
    expect(loaded.coins, 250);
    expect(loaded.lastLootClaimDate, '2026-06-07');
    expect(loaded.purchasedCosmetics, {'forest'});
    expect(loaded.lifetimeXp, 1234);
    expect(loaded.almanacCounts, {'9': 2, '11': 1});
  });
}
