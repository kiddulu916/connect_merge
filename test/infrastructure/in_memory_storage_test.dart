import 'package:flutter_test/flutter_test.dart';
import 'package:merge_loop/domain/constants.dart';
import 'package:merge_loop/domain/models/board_state.dart';
import 'package:merge_loop/domain/models/difficulty.dart';
import 'package:merge_loop/domain/models/game_status.dart';
import 'package:merge_loop/domain/models/tile.dart';
import 'package:merge_loop/infrastructure/storage_service.dart';

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
}
