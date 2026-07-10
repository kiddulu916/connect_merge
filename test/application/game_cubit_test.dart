import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/application/game_cubit.dart';
import 'package:connect_merge/application/game_state.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/engine/daily_seeder.dart';
import 'package:connect_merge/domain/engine/game_engine.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/domain/models/move.dart';
import 'package:connect_merge/domain/models/tile.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';

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
    expect((easy.state as GamePlaying).board.filledCount, Difficulty.easy.startingFill);

    final legendary = make('2026-06-06');
    await legendary.init(difficulty: Difficulty.legendary);
    expect((legendary.state as GamePlaying).board.filledCount, Difficulty.legendary.startingFill);
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

  test('onAnalyticsEvent fires run_completed exactly once with the terminal board\'s stats',
      () async {
    final events = <MapEntry<String, Map<String, Object?>?>>[];
    await _completeTier(
      storage,
      '2026-06-06',
      Difficulty.easy,
      onAnalyticsEvent: (name, [params]) =>
          events.add(MapEntry(name, params)),
    );

    final runCompleted =
        events.where((e) => e.key == 'run_completed').toList();
    expect(runCompleted, hasLength(1));
    final params = runCompleted.single.value!;
    expect(params['difficulty'], 'easy');
    expect(params.containsKey('score'), isTrue);
    expect(params.containsKey('highestTier'), isTrue);
    expect(params.containsKey('moveCount'), isTrue);
  });

  test('per-tier streak_broken fires on a genuine gap, using the pre-reset length',
      () async {
    await _completeTier(storage, '2026-06-01', Difficulty.easy);
    final events = <MapEntry<String, Map<String, Object?>?>>[];
    await _completeTier(
      storage,
      '2026-06-07', // 6-day gap since 2026-06-01; no freeze support at this layer
      Difficulty.easy,
      onAnalyticsEvent: (name, [params]) =>
          events.add(MapEntry(name, params)),
    );

    final broken = events.where((e) => e.key == 'streak_broken').toList();
    // MapEntry has no value equality — compare .value on the single match.
    expect(broken, hasLength(1));
    expect(broken.single.value,
        {'streakType': 'perTier', 'difficulty': 'easy', 'length': 1});
  });

  test('per-tier streak_broken does NOT fire on a first-ever completion',
      () async {
    final events = <MapEntry<String, Map<String, Object?>?>>[];
    await _completeTier(
      storage,
      '2026-06-01',
      Difficulty.easy,
      onAnalyticsEvent: (name, [params]) =>
          events.add(MapEntry(name, params)),
    );

    expect(events.where((e) => e.key == 'streak_broken'), isEmpty);
  });

  test('onError fires when onTierCompleted throws', () async {
    Object? capturedError;
    await _completeTier(
      storage,
      '2026-06-06',
      Difficulty.easy,
      onTierCompleted: ({int score = 0, int highestTier = 0}) async =>
          throw StateError('engagement bookkeeping failed'),
      onError: (error, stack, {fatal = false}) => capturedError = error,
    );

    expect(capturedError, isA<StateError>());
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
    // Drive merge loop by availability: only call _findMergePair when a pair is
    // known to exist (so it never throws in normal flow).
    var merges = 0;
    while (merges < 3) {
      if (c.state is! GamePlaying) break;
      final board = (c.state as GamePlaying).board;
      if (!GameEngine.hasMergeAvailable(board)) break;
      final pair = _findMergePair(board);
      expected.add(MergeEvent(from: pair.$1, to: pair.$2));
      await c.merge(fromIndex: pair.$1, toIndex: pair.$2);
      merges++;
    }
    // Verify at least one merge was recorded.
    expect(expected.isNotEmpty, isTrue);
    // Assert moveLog unconditionally — read board from whichever state is current.
    final boardAfterMerges = c.state is GamePlaying
        ? (c.state as GamePlaying).board
        : (c.state as GameOverShowScore).board;
    expect(boardAfterMerges.moveLog, expected);

    // Force an out-of-moves state, then grant an ad continue.
    // The board might be deadlocked or completed; get its current state.
    final board = c.state is GamePlaying
        ? (c.state as GamePlaying).board
        : (c.state as GameOverShowScore).board;
    final forced = board.copyWith(
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

  group('golden tiles credit coins (Phase 1)', () {
    test('merging golden tiles fires onCoinsEarned without changing score',
        () async {
      // Resume a seeded board with two golden, equal-tier tiles in cells 0/1.
      final base =
          const DailySeeder('2026-06-06', Difficulty.medium).generate().board;
      final cells = List<Tile?>.of(base.cells);
      cells[0] = const Tile(id: 900, tier: 2, golden: true);
      cells[1] = const Tile(id: 901, tier: 2, golden: true);
      await storage.saveSnapshot(GameSnapshot(
          date: '2026-06-06',
          difficulty: Difficulty.medium,
          board: base.copyWith(cells: cells),
          completed: false));

      var credited = 0;
      final c = GameCubit(
        storage: storage,
        todayProvider: () => '2026-06-06',
        onCoinsEarned: (delta) async => credited += delta,
      );
      await c.init(difficulty: Difficulty.medium);

      final before = (c.state as GamePlaying).board;
      await c.merge(fromIndex: 0, toIndex: 1);
      final after = (c.state as GamePlaying).board;

      // Two golden tiles consumed => bonus credited; score is the merge only.
      expect(credited, 2 * kGoldenMergeBonus);
      expect(after.score, before.score + (1 << 3)); // tier 2 -> tier 3
      // The move log records only the merge (no golden/coin artifacts).
      expect(after.moveLog.last, const MergeEvent(from: 0, to: 1));
    });

    test('merging non-golden tiles credits nothing', () async {
      final base =
          const DailySeeder('2026-06-06', Difficulty.medium).generate().board;
      final cells = List<Tile?>.of(base.cells);
      cells[0] = const Tile(id: 900, tier: 2);
      cells[1] = const Tile(id: 901, tier: 2);
      await storage.saveSnapshot(GameSnapshot(
          date: '2026-06-06',
          difficulty: Difficulty.medium,
          board: base.copyWith(cells: cells),
          completed: false));

      var credited = 0;
      final c = GameCubit(
        storage: storage,
        todayProvider: () => '2026-06-06',
        onCoinsEarned: (delta) async => credited += delta,
      );
      await c.init(difficulty: Difficulty.medium);
      await c.merge(fromIndex: 0, toIndex: 1);
      expect(credited, 0);
    });
  });

  group('double coins on completion (Phase 2)', () {
    /// Resume a board with two golden tier-2 tiles so a single merge credits
    /// run coins without ending the day; returns the wired cubit + a coin sink.
    Future<(GameCubit, List<int>)> goldenRun() async {
      final base =
          const DailySeeder('2026-06-06', Difficulty.medium).generate().board;
      final cells = List<Tile?>.of(base.cells);
      cells[0] = const Tile(id: 900, tier: 2, golden: true);
      cells[1] = const Tile(id: 901, tier: 2, golden: true);
      await storage.saveSnapshot(GameSnapshot(
          date: '2026-06-06',
          difficulty: Difficulty.medium,
          board: base.copyWith(cells: cells),
          completed: false));
      final credits = <int>[];
      final c = GameCubit(
        storage: storage,
        todayProvider: () => '2026-06-06',
        onCoinsEarned: (delta) async => credits.add(delta),
      );
      await c.init(difficulty: Difficulty.medium);
      return (c, credits);
    }

    test('tracks coins earned this run and doubles them once', () async {
      final (c, credits) = await goldenRun();
      await c.merge(fromIndex: 0, toIndex: 1);

      final earned = c.coinsEarnedThisRun;
      expect(earned, 2 * kGoldenMergeBonus);
      expect(c.coinsDoubled, isFalse);

      final bonus = await c.doubleRunCoins();
      expect(bonus, earned); // credits the same amount again
      expect(c.coinsDoubled, isTrue);
      // The wallet hook saw the golden credit then the double of the same total.
      expect(credits, [earned, earned]);
    });

    test('doubleRunCoins is idempotent (no triple credit)', () async {
      final (c, _) = await goldenRun();
      await c.merge(fromIndex: 0, toIndex: 1);
      final first = await c.doubleRunCoins();
      final second = await c.doubleRunCoins(); // second call is a no-op
      expect(first, greaterThan(0));
      expect(second, 0);
    });

    test('doubleRunCoins with no earned coins is a no-op', () async {
      final c = make('2026-06-06');
      await c.init(difficulty: Difficulty.medium);
      expect(c.coinsEarnedThisRun, 0);
      expect(await c.doubleRunCoins(), 0);
      expect(c.coinsDoubled, isFalse);
    });
  });

  test('playChain collapses a valid 2-path, scores, and tops the board back up',
      () async {
    final storage = InMemoryStorageService();
    final cubit = GameCubit(storage: storage, todayProvider: () => '2026-06-20');
    await cubit.init(difficulty: Difficulty.easy);
    final before = (cubit.state as GamePlaying).board;

    // Find any orthogonally-adjacent equal-tier pair on the seeded board.
    int? from, to;
    for (var i = 0; i < kCellCount && from == null; i++) {
      final t = before.cells[i];
      if (t == null || t.tier >= kMaxTier) continue;
      for (final n in [i + 1, i + kGridSize]) {
        if (n >= kCellCount) continue;
        if (n == i + 1 && (i % kGridSize) == kGridSize - 1) continue; // row wrap
        final u = before.cells[n];
        if (u != null && u.tier == t.tier) {
          from = i;
          to = n;
          break;
        }
      }
    }
    expect(from, isNotNull, reason: 'seeded easy board should have a merge');

    await cubit.playChain([from!, to!]);
    final after = (cubit.state as GamePlaying).board;

    expect(after.score, greaterThan(before.score));
    expect(after.movesRemaining, before.movesRemaining - 1);
    // Board topped back up to the difficulty fill (a 2-chain frees 1, drops 1).
    expect(after.filledCount, Difficulty.easy.startingFill);
    expect(after.moveLog.last, isA<ChainEvent>());
  });

  test('playChain rejects an invalid path (no state change)', () async {
    final storage = InMemoryStorageService();
    final cubit = GameCubit(storage: storage, todayProvider: () => '2026-06-20');
    await cubit.init(difficulty: Difficulty.easy);
    final before = (cubit.state as GamePlaying).board;
    await cubit.playChain([0, 24]); // not adjacent / likely empty
    final after = (cubit.state as GamePlaying).board;
    expect(after.score, before.score);
    expect(after.movesRemaining, before.movesRemaining);
  });

  test('peekDropTiers returns the next tiers without consuming them', () async {
    final storage = InMemoryStorageService();
    final cubit = GameCubit(storage: storage, todayProvider: () => '2026-06-20');
    await cubit.init(difficulty: Difficulty.easy);
    final a = cubit.peekDropTiers();
    final b = cubit.peekDropTiers();
    expect(a.length, kDropQueueVisible);
    expect(a, b); // idempotent (no consumption)
  });

  test('refill guarantee: board always has a merge after each chain play', () async {
    // Helper: find any 2-cell chain (east or south neighbour) on the board.
    List<int>? findChain(BoardState board) {
      final gs = board.gridSize;
      final count = board.cells.length;
      for (var i = 0; i < count; i++) {
        final t = board.cells[i];
        if (t == null || t.tier >= kMaxTier) continue;
        final col = i % gs;
        final row = i ~/ gs;
        if (col + 1 < gs) {
          final e = board.cells[i + 1];
          if (e != null && e.tier == t.tier) return [i, i + 1];
        }
        if (row + 1 < gs) {
          final s = board.cells[i + gs];
          if (s != null && s.tier == t.tier) return [i, i + gs];
        }
      }
      return null;
    }

    // Play 8 chains from an Easy game (largest board, most tiles).
    // After each playChain, if the board is still "playing",
    // hasMergeAvailable MUST be true.
    final storage = InMemoryStorageService();
    final cubit = GameCubit(storage: storage, todayProvider: () => '2026-06-20');
    await cubit.init(difficulty: Difficulty.easy);
    for (var move = 0; move < 8; move++) {
      final s = cubit.state;
      if (s is! GamePlaying) break;
      final chain = findChain(s.board);
      if (chain == null) {
        fail('Board deadlocked at move $move — refill guarantee failed');
      }
      await cubit.playChain(chain);
      final after = cubit.state;
      if (after is GamePlaying) {
        expect(
          GameEngine.hasMergeAvailable(after.board),
          isTrue,
          reason: 'hasMergeAvailable must be true after refill (move $move)',
        );
      }
    }
  });
}

/// Persist a completed snapshot + run completion bookkeeping for [tier] on
/// [date] by driving a cubit through init on an already out-of-moves board.
Future<void> _completeTier(
  InMemoryStorageService storage,
  String date,
  Difficulty tier, {
  void Function(Object error, StackTrace? stack, {bool fatal})? onError,
  void Function(String name, [Map<String, Object?>? params])? onAnalyticsEvent,
  Future<void> Function({int score, int highestTier})? onTierCompleted,
}) async {
  // Seed a fresh board, then play it to completion by forcing out-of-moves
  // through the cubit's merge path is heavy; instead simulate completion the way
  // _recordCompletion does, by running a single merge that ends the day.
  final start = DailySeeder(date, tier).generate().board;
  // Drive to out-of-moves by saving a near-complete snapshot then merging once.
  final nearDone = start.copyWith(movesRemaining: 1);
  await storage.saveSnapshot(GameSnapshot(
      date: date, difficulty: tier, board: nearDone, completed: false));

  final c = GameCubit(
    storage: storage,
    todayProvider: () => date,
    onError: onError,
    onAnalyticsEvent: onAnalyticsEvent,
    onTierCompleted: onTierCompleted,
  );
  await c.init(difficulty: tier);
  final board = (c.state as GamePlaying).board;
  final pair = _findMergePair(board);
  await c.merge(fromIndex: pair.$1, toIndex: pair.$2);
  // After spending the last move, status becomes outOfMoves and completion is
  // recorded.
  expect(c.state, isA<GameOverShowScore>());
}

(int, int) _findMergePair(BoardState b) {
  // Find two ADJACENT tiles of the same tier (new spatial deadlock semantics).
  for (var i = 0; i < b.cells.length; i++) {
    final t = b.cells[i];
    if (t == null || t.tier >= kMaxTier) continue;
    final row = i ~/ kGridSize, col = i % kGridSize;
    // Check east and south neighbours.
    if (col + 1 < kGridSize) {
      final e = b.cells[i + 1];
      if (e != null && e.tier == t.tier) return (i, i + 1);
    }
    if (row + 1 < kGridSize) {
      final so = b.cells[i + kGridSize];
      if (so != null && so.tier == t.tier) return (i, i + kGridSize);
    }
  }
  throw StateError('seeded board unexpectedly has no adjacent merge pair');
}
