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

/// The replay-relevant shape of a cell: id + tier only. The server verifier
/// (and the `replay` helper below) reconstruct tiers + positions but NOT the
/// cosmetic `golden` flag — golden never affects score or the move log — so
/// invariant checks compare id/tier, not the full (golden-bearing) toJson.
(int, int)? _cellKey(Tile? t) => t == null ? null : (t.id, t.tier);
List<(int, int)?> _cellKeys(BoardState b) => b.cells.map(_cellKey).toList();

/// Replays a final [moveLog] against the regenerated `(date,difficulty)` board
/// the EXACT way the Phase 2 Supabase edge function does (see
/// supabase/functions/_shared/engine.ts `verifyRun`): collapse → refill →
/// evaluate, per chain event. Returns the reconstructed terminal board so a
/// test can assert the persisted moveLog reproduces the persisted board after
/// any undo sequence.
BoardState replay(String date, Difficulty difficulty, List<MoveEvent> log) {
  final seeder = DailySeeder(date, difficulty);
  final start = seeder.generate();
  final dropPrng = seeder.dropTierPrng();
  final landing = seeder.landingPrng();
  var board = start.board;

  for (final ev in log) {
    if (ev is ChainEvent) {
      expect(board.status, GameStatus.playing,
          reason: 'replay hit a non-playing chain — moveLog drifted');
      expect(GameEngine.isValidChain(board, ev.path), isTrue,
          reason: 'replay hit an invalid chain — moveLog drifted');
      board = GameEngine.collapseChain(board, ev.path);
      board = GameEngine.refill(
        board,
        targetFill: difficulty.startingFill,
        tierAt: (i) => seeder.dropTierAt(dropPrng, i),
        landing: landing,
      );
      board = GameEngine.evaluateStatus(board);
    } else if (ev is ContinueEvent) {
      board = board.copyWith(
        movesRemaining: board.movesRemaining + kAdMoveReward,
        adContinuesUsed: board.adContinuesUsed + 1,
        status: GameStatus.playing,
      );
    }
  }
  return board;
}

/// Finds an oriented, orthogonally-adjacent 2-cell chain. When [avoid] is
/// supplied, skips that undirected pair so undo tests can replay differently.
List<int> _findChain(BoardState b, {List<int>? avoid}) {
  for (var i = 0; i < b.cells.length; i++) {
    final col = i % b.gridSize;
    final row = i ~/ b.gridSize;
    for (final neighbor in [
      if (col + 1 < b.gridSize) i + 1,
      if (row + 1 < b.gridSize) i + b.gridSize,
    ]) {
      if (avoid != null &&
          avoid.length == 2 &&
          avoid.contains(i) &&
          avoid.contains(neighbor)) {
        continue;
      }
      for (final path in [
        [i, neighbor],
        [neighbor, i],
      ]) {
        if (GameEngine.isValidChain(b, path)) {
          expect(GameEngine.isValidChain(b, path), isTrue);
          return path;
        }
      }
    }
  }
  throw StateError('seeded board unexpectedly has no valid adjacent chain');
}

void main() {
  late InMemoryStorageService storage;
  GameCubit make(String date) =>
      GameCubit(storage: storage, todayProvider: () => date);
  setUp(() => storage = InMemoryStorageService());

  group('UNDO INVARIANT: run stays replay-consistent', () {
    test(
        'chain → undo → re-chain-differently: final moveLog replays to the '
        'final board (no PRNG desync)', () async {
      const date = '2026-06-09';
      const diff = Difficulty.easy;
      final c = make(date);
      await c.init(difficulty: diff);

      final start = (c.state as GamePlaying).board;
      final firstPath = _findChain(start);
      final otherPath = _findChain(start, avoid: firstPath);

      // Play one way...
      await c.playChain(firstPath);
      // ...undo it...
      await c.undo();
      expect((c.state as GamePlaying).board.toJson(), start.toJson());
      // ...then play a DIFFERENT path.
      await c.playChain(otherPath);

      final finalBoard = (c.state as GamePlaying).board;

      // THE CRITICAL ASSERTION: the persisted moveLog replays (server-style)
      // to EXACTLY the persisted board. A landing-PRNG desync after undo would
      // place a post-chain refill tile in a different cell and break this.
      final replayed = replay(date, diff, finalBoard.moveLog);
      expect(_cellKeys(replayed), _cellKeys(finalBoard));
      expect(replayed.score, finalBoard.score);
      expect(replayed.dropIndex, finalBoard.dropIndex);
      expect(replayed.highestTier, finalBoard.highestTier);

      // The move log holds exactly the single re-played chain — the undone one is
      // gone, so the persisted log equals the real board history.
      expect(finalBoard.moveLog, [ChainEvent(path: otherPath)]);
    });

    test('multiple chains then multiple undos all stay replay-consistent',
        () async {
      const date = '2026-06-10';
      const diff = Difficulty.medium;
      final c = make(date);
      await c.init(difficulty: diff);

      // Play three chains.
      for (var i = 0; i < 3; i++) {
        final b = (c.state as GamePlaying).board;
        await c.playChain(_findChain(b));
      }
      // Undo two of them (depth is bounded at kUndoStackDepth >= 3).
      await c.undoAfterReward();
      await c.undoAfterReward();

      final board = (c.state as GamePlaying).board;
      expect(board.moveLog.length, 1, reason: 'two of three chains undone');

      final replayed = replay(date, diff, board.moveLog);
      expect(_cellKeys(replayed), _cellKeys(board));
      expect(replayed.score, board.score);
      expect(replayed.dropIndex, board.dropIndex);
    });
  });

  group('UNDO refunds golden coins (no farming)', () {
    /// Resume a board with two golden tier-2 tiles in cells 0/1 so a 2-chain
    /// credits a golden bonus without ending the day.
    Future<GameCubit> goldenCubit(String date, Difficulty diff,
        Future<void> Function(int delta) onCoins) async {
      final base = DailySeeder(date, diff).generate().board;
      final cells = List<Tile?>.of(base.cells);
      cells[0] = const Tile(id: 900, tier: 2, golden: true);
      cells[1] = const Tile(id: 901, tier: 2, golden: true);
      await storage.saveSnapshot(GameSnapshot(
          date: date,
          difficulty: diff,
          board: base.copyWith(cells: cells),
          completed: false));
      final c = GameCubit(
          storage: storage, todayProvider: () => date, onCoinsEarned: onCoins);
      await c.init(difficulty: diff);
      return c;
    }

    test(
        'golden chain credits N, undo refunds N (wallet net 0), re-play '
        'credits once', () async {
      const date = '2026-06-06';
      const diff = Difficulty.medium;
      // The wallet mutates through the single addCoins path (signed delta).
      Future<void> onCoins(int delta) => storage.addCoins(delta);
      final c = await goldenCubit(date, diff, onCoins);

      final board = (c.state as GamePlaying).board;
      final path = [0, 1];
      expect(GameEngine.isValidChain(board, path), isTrue);
      final n =
          path.where((i) => board.cells[i]!.golden).length * kGoldenMergeBonus;
      expect(storage.loadProfile().wallet.coins, 0);

      // Play the two golden tiles -> wallet credited N, run tally N.
      await c.playChain(path);
      expect(c.coinsEarnedThisRun, n);
      expect(storage.loadProfile().wallet.coins, n);

      // Undo -> wallet refunded back to 0, run tally back to 0.
      await c.undo();
      expect(c.coinsEarnedThisRun, 0);
      expect(storage.loadProfile().wallet.coins, 0,
          reason: 'undo must refund the golden coins (no farming)');

      // Re-play the SAME golden tiles -> credits exactly once more, not twice.
      await c.playChain(path);
      expect(c.coinsEarnedThisRun, n);
      expect(storage.loadProfile().wallet.coins, n,
          reason: 'play→undo→re-play nets a single credit, never farmed');
    });
  });

  group('UNDO refunds objective-reward coins (no farming)', () {
    // Date + difficulty where dailyObjective() == chainLength target 4,
    // walls are {6, 14} (never touching cells 0-3), confirmed above.
    const objDate = '2026-06-04';
    const objDiff = Difficulty.medium;

    /// Returns a cubit resumed on a board whose cells 0-3 are all tier-1
    /// (a valid 4-chain) while the rest of the base board is untouched so
    /// the game stays alive after the chain.  The chain will be the FIRST
    /// move that meets the chainLength=4 objective.
    Future<GameCubit> objectiveCubit(
        Future<void> Function(int delta) onCoins) async {
      final base = const DailySeeder(objDate, objDiff).generate().board;
      final cells = List<Tile?>.of(base.cells);
      // Four orthogonally adjacent tier-1 tiles in row 0, cols 0-3.
      cells[0] = const Tile(id: 800, tier: 1);
      cells[1] = const Tile(id: 801, tier: 1);
      cells[2] = const Tile(id: 802, tier: 1);
      cells[3] = const Tile(id: 803, tier: 1);
      await storage.saveSnapshot(GameSnapshot(
          date: objDate,
          difficulty: objDiff,
          board: base.copyWith(cells: cells),
          completed: false));
      final c = GameCubit(
          storage: storage,
          todayProvider: () => objDate,
          onCoinsEarned: onCoins);
      await c.init(difficulty: objDiff);
      return c;
    }

    test(
        'objective-meeting chain credits kObjectiveRewardCoins, undo refunds '
        'it (wallet net 0), re-play credits it exactly once', () async {
      Future<void> onCoins(int delta) => storage.addCoins(delta);
      final c = await objectiveCubit(onCoins);

      // Sanity: objective should be chainLength=4 for this date+diff.
      expect(c.objective.target, 4,
          reason: 'seed mismatch — test setup requires target==4');

      expect(storage.loadProfile().wallet.coins, 0);

      // Play the 4-tile chain — this is the first chain that meets the
      // objective, so it earns kObjectiveRewardCoins.
      await c.playChain([0, 1, 2, 3]);
      expect(c.coinsEarnedThisRun, greaterThanOrEqualTo(kObjectiveRewardCoins),
          reason: 'objective reward must be credited');
      final walletAfterPlay = storage.loadProfile().wallet.coins;
      expect(walletAfterPlay, greaterThanOrEqualTo(kObjectiveRewardCoins));

      // Undo — wallet must be refunded exactly to the pre-play amount (0).
      expect(c.canUndo, isTrue);
      await c.undo();
      expect(storage.loadProfile().wallet.coins, 0,
          reason: 'undo must refund the objective reward (no farming)');
      expect(c.coinsEarnedThisRun, 0,
          reason: 'run tally must be back to 0 after undo');

      // Re-play the same chain — objective is re-earned exactly once.
      await c.playChain([0, 1, 2, 3]);
      expect(c.coinsEarnedThisRun, greaterThanOrEqualTo(kObjectiveRewardCoins),
          reason: 're-play must re-credit the objective reward exactly once');
      expect(storage.loadProfile().wallet.coins, walletAfterPlay,
          reason: 'net wallet after undo + re-play == single objective credit');
    });
  });

  test('undo after a chain restores board, score, and drop streams', () async {
    final storage = InMemoryStorageService();
    final cubit =
        GameCubit(storage: storage, todayProvider: () => '2026-06-20');
    await cubit.init(difficulty: Difficulty.easy);
    final before = (cubit.state as GamePlaying).board;

    final path = _findChain(before);
    await cubit.playChain(path);
    final played = (cubit.state as GamePlaying).board;
    final replayed = replay('2026-06-20', Difficulty.easy, played.moveLog);
    expect(_cellKeys(replayed), _cellKeys(played));
    expect(replayed.score, played.score);
    expect(replayed.dropIndex, played.dropIndex);
    expect(cubit.canUndo, isTrue);
    await cubit.undo();
    final restored = (cubit.state as GamePlaying).board;
    expect(restored.toJson(), before.toJson());
    expect(restored.score, before.score);
    expect(restored.movesRemaining, before.movesRemaining);
    expect(restored.dropIndex, before.dropIndex);
  });

  group('UNDO gating + bounds', () {
    test('free undo cap: exactly kFreeUndosPerDay free undos, then no-op',
        () async {
      // Date chosen to give enough chains with the on-demand drop-tier stream.
      const date = '2026-07-02';
      final c = make(date);
      await c.init(difficulty: Difficulty.medium);

      // Build a stack with several chains so frames exist beyond the free cap.
      for (var i = 0; i < kFreeUndosPerDay + 2; i++) {
        final b = (c.state as GamePlaying).board;
        await c.playChain(_findChain(b));
      }

      var freeUndos = 0;
      while (c.canUndoFree) {
        await c.undo();
        freeUndos++;
      }
      expect(freeUndos, kFreeUndosPerDay);
      // canUndo is still true (frames remain) but no FREE undo is left.
      expect(c.canUndo, isTrue);
      expect(c.canUndoFree, isFalse);

      // A bare undo() past the free cap is a no-op (log unchanged).
      final logBefore = (c.state as GamePlaying).board.moveLog.length;
      await c.undo();
      expect((c.state as GamePlaying).board.moveLog.length, logBefore);
    });

    test('rewarded undo grants exactly one extra past the free cap', () async {
      // Date chosen to give enough chains with the on-demand drop-tier stream.
      const date = '2026-07-02';
      final c = make(date);
      await c.init(difficulty: Difficulty.medium);

      for (var i = 0; i < kFreeUndosPerDay + 1; i++) {
        final b = (c.state as GamePlaying).board;
        await c.playChain(_findChain(b));
      }
      // Spend the free undo(s).
      while (c.canUndoFree) {
        await c.undo();
      }
      final logBefore = (c.state as GamePlaying).board.moveLog.length;

      // The rewarded path grants ONE more undo even though the free cap is hit.
      await c.undoAfterReward();
      expect((c.state as GamePlaying).board.moveLog.length, logBefore - 1);
    });

    test('overlapping rewarded undo callbacks grant one undo', () async {
      const date = '2026-07-02';
      final c = make(date);
      await c.init(difficulty: Difficulty.medium);

      for (var i = 0; i < 3; i++) {
        final b = (c.state as GamePlaying).board;
        await c.playChain(_findChain(b));
      }
      final logBefore = (c.state as GamePlaying).board.moveLog.length;

      final first = c.undoAfterReward();
      final second = c.undoAfterReward();
      await Future.wait([first, second]);

      expect((c.state as GamePlaying).board.moveLog.length, logBefore - 1);
    });

    test('undo is a no-op with an empty stack', () async {
      const date = '2026-06-02';
      final c = make(date);
      await c.init(difficulty: Difficulty.medium);
      expect(c.canUndo, isFalse);
      final before = (c.state as GamePlaying).board.toJson();
      await c.undo();
      await c.undoAfterReward();
      expect((c.state as GamePlaying).board.toJson(), before);
    });

    test('undo stack is bounded at kUndoStackDepth', () async {
      // Date chosen to give enough chains with the on-demand drop-tier stream.
      const date = '2026-07-02';
      final c = make(date);
      await c.init(difficulty: Difficulty.medium);

      // Make more chains than the stack depth.
      for (var i = 0; i < kUndoStackDepth + 3; i++) {
        final b = (c.state as GamePlaying).board;
        await c.playChain(_findChain(b));
      }
      // Only kUndoStackDepth frames are rewindable (oldest dropped).
      var undos = 0;
      while (c.canUndo) {
        await c.undoAfterReward();
        undos++;
      }
      expect(undos, kUndoStackDepth);
    });

    test('undo only valid in GamePlaying (not after the run is locked)',
        () async {
      const date = '2026-06-06';
      const diff = Difficulty.medium;
      // Resume a near-complete board (1 move left), play once to lock the day.
      final start = const DailySeeder(date, diff).generate().board;
      await storage.saveSnapshot(GameSnapshot(
          date: date,
          difficulty: diff,
          board: start.copyWith(movesRemaining: 1),
          completed: false));
      final c = make(date);
      await c.init(difficulty: diff);
      final b = (c.state as GamePlaying).board;
      await c.playChain(_findChain(b));

      expect(c.state, isA<GameOverShowScore>());
      // No undo once locked, even though a chain just happened.
      expect(c.canUndo, isFalse);
      await c.undo();
      await c.undoAfterReward();
      expect(c.state, isA<GameOverShowScore>(),
          reason: 'undo must not revive a locked run');
    });
  });
}
