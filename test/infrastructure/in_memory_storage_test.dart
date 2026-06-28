import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/domain/models/tile.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';

BoardState sampleBoard({int score = 0}) => BoardState(
      cells: List<Tile?>.filled(kCellCount, null),
      movesRemaining: 30,
      score: score,
      nextTileId: 0,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 0,
      status: GameStatus.playing,
    );

void main() {
  test('snapshot is keyed by (date, difficulty)', () async {
    final s = InMemoryStorageService();
    await s.init();
    expect(s.loadSnapshot('2026-06-06', Difficulty.hard), isNull);

    final snap = GameSnapshot(
        date: '2026-06-06',
        difficulty: Difficulty.hard,
        board: sampleBoard(score: 42),
        completed: false);
    await s.saveSnapshot(snap);

    // Same date, different tier -> still missing.
    expect(s.loadSnapshot('2026-06-06', Difficulty.easy), isNull);
    // Same tier, different date -> still missing.
    expect(s.loadSnapshot('2026-06-07', Difficulty.hard), isNull);

    final loaded = s.loadSnapshot('2026-06-06', Difficulty.hard)!;
    expect(loaded.date, '2026-06-06');
    expect(loaded.difficulty, Difficulty.hard);
    expect(loaded.board.score, 42);
  });

  test('saving two tiers for the same date does not clobber', () async {
    final s = InMemoryStorageService();
    await s.init();
    await s.saveSnapshot(GameSnapshot(
        date: '2026-06-06',
        difficulty: Difficulty.easy,
        board: sampleBoard(score: 1),
        completed: false));
    await s.saveSnapshot(GameSnapshot(
        date: '2026-06-06',
        difficulty: Difficulty.legendary,
        board: sampleBoard(score: 2),
        completed: true));

    expect(s.loadSnapshot('2026-06-06', Difficulty.easy)!.board.score, 1);
    expect(s.loadSnapshot('2026-06-06', Difficulty.easy)!.completed, isFalse);
    expect(
        s.loadSnapshot('2026-06-06', Difficulty.legendary)!.board.score, 2);
    expect(
        s.loadSnapshot('2026-06-06', Difficulty.legendary)!.completed, isTrue);
  });

  test('stats are per-tier and default to zero', () async {
    final s = InMemoryStorageService();
    await s.init();
    expect(s.loadStats(Difficulty.hard).bestScore, 0);

    await s.saveStats(
        Difficulty.hard,
        const LifetimeStats(
            streak: 3,
            lastCompletedDate: '2026-06-06',
            bestScore: 999,
            bestTier: 7));

    expect(s.loadStats(Difficulty.hard).streak, 3);
    expect(s.loadStats(Difficulty.hard).bestScore, 999);
    // A different tier is unaffected.
    expect(s.loadStats(Difficulty.easy).streak, 0);
  });

  test('GameSnapshot and LifetimeStats round-trip through json', () {
    final snap = GameSnapshot(
        date: '2026-06-06',
        difficulty: Difficulty.legendary,
        board: sampleBoard(),
        completed: true);
    final decoded = GameSnapshot.fromJson(snap.toJson());
    expect(decoded.toJson(), snap.toJson());
    expect(decoded.difficulty, Difficulty.legendary);

    const stats = LifetimeStats(
        streak: 2,
        lastCompletedDate: '2026-06-05',
        bestScore: 50,
        bestTier: 4);
    expect(LifetimeStats.fromJson(stats.toJson()).toJson(), stats.toJson());
  });

  group('PlayerProfile wallet fields (Phase 1)', () {
    test('default to 0 / null (migration-free)', () {
      const p = PlayerProfile();
      expect(p.coins, 0);
      expect(p.lastLootClaimDate, isNull);
    });

    test('a pre-Phase-1 profile json (no wallet keys) decodes to defaults', () {
      final p = PlayerProfile.fromJson({
        'dailyActiveStreak': 5,
        'lastActiveDate': '2026-06-07',
        'unlockedAchievements': <String>[],
        'selectedCosmetic': 'classic',
        'adUnlockedCosmetics': <String>[],
        'notificationsEnabled': false,
        'reminderMinutes': 19 * 60,
        'bestRankByDifficulty': <String, int>{},
        // No 'coins' / 'lastLootClaimDate' keys.
      });
      expect(p.coins, 0);
      expect(p.lastLootClaimDate, isNull);
      // Existing fields are untouched.
      expect(p.dailyActiveStreak, 5);
    });

    test('round-trips coins + lastLootClaimDate through json', () {
      const p = PlayerProfile(coins: 175, lastLootClaimDate: '2026-06-11');
      final decoded = PlayerProfile.fromJson(p.toJson());
      expect(decoded.coins, 175);
      expect(decoded.lastLootClaimDate, '2026-06-11');
    });

    test('copyWith updates the wallet fields', () {
      final p = const PlayerProfile()
          .copyWith(coins: 30, lastLootClaimDate: '2026-06-11');
      expect(p.coins, 30);
      expect(p.lastLootClaimDate, '2026-06-11');
    });

    test('Phase 3 rival fields default to null / empty (migration-free)', () {
      const p = PlayerProfile();
      expect(p.rivalId, isNull);
      expect(p.rivalName, isNull);
      expect(p.lastSeenRivalScoreByTier, isEmpty);
    });

    test('a pre-Phase-3 profile json (no rival keys) decodes to defaults', () {
      final p = PlayerProfile.fromJson({
        'dailyActiveStreak': 5,
        'lastActiveDate': '2026-06-07',
        'coins': 42,
        // No 'rivalId' / 'rivalName' / 'lastSeenRivalScoreByTier' keys.
      });
      expect(p.rivalId, isNull);
      expect(p.rivalName, isNull);
      expect(p.lastSeenRivalScoreByTier, isEmpty);
      // Existing fields are untouched.
      expect(p.dailyActiveStreak, 5);
      expect(p.coins, 42);
    });

    test('round-trips the rival fields through json', () {
      const p = PlayerProfile(
        rivalId: 'p1',
        rivalName: 'Ann',
        lastSeenRivalScoreByTier: {'hard': 4096, 'easy': 100},
      );
      final decoded = PlayerProfile.fromJson(p.toJson());
      expect(decoded.rivalId, 'p1');
      expect(decoded.rivalName, 'Ann');
      expect(decoded.lastSeenRivalScoreByTier, {'hard': 4096, 'easy': 100});
    });

    test('copyWith clearRival removes the rival', () {
      const p = PlayerProfile(rivalId: 'p1', rivalName: 'Ann');
      final cleared = p.copyWith(clearRival: true);
      expect(cleared.rivalId, isNull);
      expect(cleared.rivalName, isNull);
    });
  });

  test('GameSnapshot carries a version that round-trips; legacy json is v1', () {
    final cells = List<Tile?>.filled(kCellCount, null);
    final snap = GameSnapshot(
      date: '2026-06-20',
      difficulty: Difficulty.easy,
      board: BoardState(
        cells: cells,
        movesRemaining: 30,
        score: 0,
        nextTileId: 0,
        dropIndex: 0,
        adContinuesUsed: 0,
        movesMade: 0,
        status: GameStatus.playing,
      ),
      completed: false,
    );
    expect(snap.version, kSnapshotVersion);
    expect(GameSnapshot.fromJson(snap.toJson()).version, kSnapshotVersion);

    final legacy = snap.toJson()..remove('v');
    expect(GameSnapshot.fromJson(legacy).version, 1);
  });
}
