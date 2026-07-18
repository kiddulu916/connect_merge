import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/domain/models/tile.dart';
import 'package:connect_merge/infrastructure/hive_storage_service.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';

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
    expect(s.loadProfile().activity.dailyActiveStreak, 0);
    expect(s.loadProfile().cosmetics.selectedCosmetic, 'classic');

    // Phase 1 + Phase 2 fields default migration-free.
    expect(s.loadProfile().wallet.coins, 0);
    expect(s.loadProfile().cosmetics.purchasedCosmetics, isEmpty);
    expect(s.loadProfile().progression.lifetimeXp, 0);
    expect(s.loadProfile().progression.almanacCounts, isEmpty);

    const profile = PlayerProfile(
      activity: ActivityStreak(
        dailyActiveStreak: 7,
        lastActiveDate: '2026-06-07',
      ),
      progression: Progression(
        unlockedAchievements: {'sevenDayStreak'},
        bestRankByDifficulty: {'hard': 3},
        lifetimeXp: 1234,
        almanacCounts: {'9': 2, '11': 1},
      ),
      cosmetics: CosmeticsInventory(
        selectedCosmetic: 'ocean',
        adUnlockedCosmetics: {'neon'},
        purchasedCosmetics: {'forest'},
      ),
      settings: PlayerSettings(
        notificationsEnabled: true,
        reminderMinutes: 20 * 60,
      ),
      wallet: Wallet(coins: 250, lastLootClaimDate: '2026-06-07'),
    );
    await s.saveProfile(profile);

    final loaded = s.loadProfile();
    expect(loaded.activity.dailyActiveStreak, 7);
    expect(loaded.activity.lastActiveDate, '2026-06-07');
    expect(loaded.progression.unlockedAchievements, {'sevenDayStreak'});
    expect(loaded.cosmetics.selectedCosmetic, 'ocean');
    expect(loaded.cosmetics.adUnlockedCosmetics, {'neon'});
    expect(loaded.settings.notificationsEnabled, isTrue);
    expect(loaded.settings.reminderMinutes, 20 * 60);
    expect(loaded.progression.bestRankByDifficulty, {'hard': 3});
    // Phase 1 + Phase 2 round-trip.
    expect(loaded.wallet.coins, 250);
    expect(loaded.wallet.lastLootClaimDate, '2026-06-07');
    expect(loaded.cosmetics.purchasedCosmetics, {'forest'});
    expect(loaded.progression.lifetimeXp, 1234);
    expect(loaded.progression.almanacCounts, {'9': 2, '11': 1});
  });
}
