import 'package:flutter_test/flutter_test.dart';
import 'package:merge_loop/application/game_cubit.dart';
import 'package:merge_loop/application/game_state.dart';
import 'package:merge_loop/domain/constants.dart';
import 'package:merge_loop/domain/engine/daily_seeder.dart';
import 'package:merge_loop/domain/engine/game_engine.dart';
import 'package:merge_loop/domain/models/board_state.dart';
import 'package:merge_loop/domain/models/difficulty.dart';
import 'package:merge_loop/domain/models/game_status.dart';
import 'package:merge_loop/domain/models/move.dart';
import 'package:merge_loop/infrastructure/storage_service.dart';

void main() {
  late InMemoryStorageService storage;
  GameCubit make(String date) =>
      GameCubit(storage: storage, todayProvider: () => date);

  setUp(() => storage = InMemoryStorageService());

  test('init on a fresh day seeds a playing board and persists it', () async {
    final c = make('2026-06-06');
    await c.init(difficulty: Difficulty.medium);
    expect(c.state, isA<GamePlaying>());
    final board = (c.state as GamePlaying).board;
    expect(board.filledCount, Difficulty.medium.startingFill);
    final snap = storage.loadSnapshot('2026-06-06', Difficulty.medium)!;
    expect(snap.date, '2026-06-06');
    expect(snap.difficulty, Difficulty.medium);
  });

  test('different tiers start with their own tile counts', () async {
    final easy = make('2026-06-06');
    await easy.init(difficulty: Difficulty.easy);
    expect((easy.state as GamePlaying).board.filledCount, 10);

    final legendary = make('2026-06-06');
    await legendary.init(difficulty: Difficulty.legendary);
    expect((legendary.state as GamePlaying).board.filledCount, 4);
  });

  test('uses the UTC date provider by default', () {
    final c = GameCubit(storage: storage);
    expect(c.todayProvider(), formatDate(DateTime.now().toUtc()));
  });

  test('completing a tier blocks a second run that day but leaves other tiers playable',
      () async {
    final seeded = const DailySeeder('2026-06-06', Difficulty.hard)
        .generate()
        .board
        .copyWith(status: GameStatus.outOfMoves, movesRemaining: 0);
    await storage.saveSnapshot(GameSnapshot(
        date: '2026-06-06',
        difficulty: Difficulty.hard,
        board: seeded,
        completed: true));

    final hard = make('2026-06-06');
    await hard.init(difficulty: Difficulty.hard);
    expect(hard.state, isA<GameOverShowScore>()); // blocked

    final easy = make('2026-06-06');
    await easy.init(difficulty: Difficulty.easy);
    expect(easy.state, isA<GamePlaying>()); // fresh
  });

  test('per-tier streaks increment independently', () async {
    // Complete easy on day 1, then day 2 -> easy streak 2.
    await _completeTier(storage, '2026-06-06', Difficulty.easy);
    await _completeTier(storage, '2026-06-07', Difficulty.easy);
    expect(storage.loadStats(Difficulty.easy).streak, 2);

    // Hard untouched -> streak 0. Complete hard once on day 2 -> streak 1.
    expect(storage.loadStats(Difficulty.hard).streak, 0);
    await _completeTier(storage, '2026-06-07', Difficulty.hard);
    expect(storage.loadStats(Difficulty.hard).streak, 1);
    // Easy streak unaffected.
    expect(storage.loadStats(Difficulty.easy).streak, 2);
  });

  test('a legal merge updates score, spends a move, triggers a drop, and logs a MergeEvent',
      () async {
    final c = make('2026-06-06');
    await c.init(difficulty: Difficulty.medium);
    final board = (c.state as GamePlaying).board;

    final pair = _findMergePair(board);
    await c.merge(fromIndex: pair.$1, toIndex: pair.$2);

    final after = (c.state as GamePlaying).board;
    expect(after.movesMade, 1);
    expect(after.movesRemaining, kMovesPerDay - 1);
    expect(after.dropIndex, 1);
    expect(after.score, greaterThan(0));
    expect(after.filledCount, board.filledCount);
    expect(after.moveLog, [MergeEvent(from: pair.$1, to: pair.$2)]);
  });

  test('move log records merges then a continue, in order, and survives snapshot json',
      () async {
    final c = make('2026-06-06');
    await c.init(difficulty: Difficulty.medium);

    final expected = <MoveEvent>[];
    for (var i = 0; i < 3; i++) {
      final board = (c.state as GamePlaying).board;
      final pair = _findMergePair(board);
      expected.add(MergeEvent(from: pair.$1, to: pair.$2));
      await c.merge(fromIndex: pair.$1, toIndex: pair.$2);
    }
    expect((c.state as GamePlaying).board.moveLog, expected);

    // Force an out-of-moves state, then grant an ad continue.
    final playing = (c.state as GamePlaying).board;
    final forced = playing.copyWith(
        movesRemaining: 0, status: GameStatus.outOfMoves);
    await storage.saveSnapshot(GameSnapshot(
        date: '2026-06-06',
        difficulty: Difficulty.medium,
        board: forced,
        completed: true));
    final c2 = make('2026-06-06');
    await c2.init(difficulty: Difficulty.medium);
    expect(c2.state, isA<GameOverShowScore>());

    if (c2.canOfferAd) {
      await c2.grantAdReward();
      expected.add(const ContinueEvent());
      expect((c2.state as GamePlaying).board.moveLog, expected);
    }

    // Round-trip the move log through snapshot json.
    final log = (c2.state is GamePlaying)
        ? (c2.state as GamePlaying).board.moveLog
        : forced.moveLog;
    final snap = GameSnapshot(
        date: '2026-06-06',
        difficulty: Difficulty.medium,
        board: BoardState(
          cells: List.filled(kCellCount, null),
          movesRemaining: 0,
          score: 0,
          nextTileId: 0,
          dropIndex: 0,
          adContinuesUsed: 0,
          movesMade: 0,
          status: GameStatus.playing,
          moveLog: log,
        ),
        completed: false);
    final restored = GameSnapshot.fromJson(snap.toJson());
    expect(restored.board.moveLog, log);
  });

  test('grantAdReward adds moves, increments continues, resumes play', () async {
    final start = const DailySeeder('2026-06-06', Difficulty.medium)
        .generate()
        .board;
    final outOfMoves =
        start.copyWith(movesRemaining: 0, status: GameStatus.outOfMoves);
    await storage.saveSnapshot(GameSnapshot(
        date: '2026-06-06',
        difficulty: Difficulty.medium,
        board: outOfMoves,
        completed: true));

    final c = make('2026-06-06');
    await c.init(difficulty: Difficulty.medium);
    expect(c.state, isA<GameOverShowScore>());
    expect(c.canOfferAd, GameEngine.hasMergeAvailable(outOfMoves));

    if (c.canOfferAd) {
      await c.grantAdReward();
      final board = (c.state as GamePlaying).board;
      expect(board.movesRemaining, kAdMoveReward);
      expect(board.adContinuesUsed, 1);
      expect(board.status, GameStatus.playing);
      expect(board.moveLog.last, const ContinueEvent());
    }
  });
}

/// Persist a completed snapshot + run completion bookkeeping for [tier] on
/// [date] by driving a cubit through init on an already out-of-moves board.
Future<void> _completeTier(
    InMemoryStorageService storage, String date, Difficulty tier) async {
  // Seed a fresh board, then play it to completion by forcing out-of-moves
  // through the cubit's merge path is heavy; instead simulate completion the way
  // _recordCompletion does, by running a single merge that ends the day.
  final start = DailySeeder(date, tier).generate().board;
  // Drive to out-of-moves by saving a near-complete snapshot then merging once.
  final nearDone = start.copyWith(movesRemaining: 1);
  await storage.saveSnapshot(GameSnapshot(
      date: date, difficulty: tier, board: nearDone, completed: false));

  final c = GameCubit(storage: storage, todayProvider: () => date);
  await c.init(difficulty: tier);
  final board = (c.state as GamePlaying).board;
  final pair = _findMergePair(board);
  await c.merge(fromIndex: pair.$1, toIndex: pair.$2);
  // After spending the last move, status becomes outOfMoves and completion is
  // recorded.
  expect(c.state, isA<GameOverShowScore>());
}

(int, int) _findMergePair(BoardState b) {
  final byTier = <int, int>{};
  for (var i = 0; i < b.cells.length; i++) {
    final t = b.cells[i];
    if (t == null || t.tier >= kMaxTier) continue;
    if (byTier.containsKey(t.tier)) return (byTier[t.tier]!, i);
    byTier[t.tier] = i;
  }
  throw StateError('seeded board unexpectedly has no merge pair');
}
