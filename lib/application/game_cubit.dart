import 'package:flutter_bloc/flutter_bloc.dart';

import '../domain/constants.dart';
import '../domain/engine/daily_seeder.dart';
import '../domain/engine/game_engine.dart';
import '../domain/engine/prng.dart';
import '../domain/models/board_state.dart';
import '../domain/models/difficulty.dart';
import '../domain/models/game_status.dart';
import '../domain/models/move.dart';
import '../infrastructure/storage_service.dart';
import 'game_state.dart';

/// Formats a DateTime as the canonical YYYY-MM-DD seeding key.
String formatDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// The canonical UTC date string used for seeding and storage everywhere.
/// A single helper avoids local/UTC mixing (off-by-one near midnight).
String utcToday() => formatDate(DateTime.now().toUtc());

/// Orchestrates the daily game for one difficulty tier. **Call [init] before any
/// other method** — `merge`/`grantAdReward` rely on fields set up there (they
/// are also guarded by the state machine, which starts in [GameInitial]).
/// Hands a finalized day off to the online submit flow (Phase 2). Called once
/// when a tier's day is locked. Decoupled from supabase_flutter so the cubit
/// stays plugin-free and unit-testable.
typedef SubmitRun = Future<void> Function({
  required String date,
  required Difficulty difficulty,
  required List<MoveEvent> moveLog,
  required int adContinues,
});

class GameCubit extends Cubit<GameState> {
  final StorageService storage;
  final String Function() todayProvider;

  /// Optional online submit hook. Null when offline / not signed in.
  final SubmitRun? onSubmitRun;

  /// Optional completion hook (Phase 4). Fired once per locked day, after stats
  /// are recorded, so the engagement layer can advance the headline streak,
  /// evaluate achievements, and reschedule notifications. Decoupled (a plain
  /// callback) so the cubit stays plugin-free and unit-testable.
  final Future<void> Function()? onTierCompleted;

  /// Optional coins hook (Phase 1). Fired with the bonus when a merge consumes a
  /// golden tile, so the client-side wallet is credited. Decoupled (a plain
  /// callback, like [onTierCompleted]) — golden coins NEVER touch `score`.
  final void Function(int coins)? onCoinsEarned;

  late Difficulty _difficulty;
  late String _date;
  late List<int> _dropTiers;
  late Prng _landing;

  /// Drop indices that are golden for this date+tier (seed-derived).
  late Set<int> _goldenDrops;

  /// Rewarded-hint usage this cubit lifetime (one tier's day). Gates the
  /// per-day cap on the reveal-next-drop hint.
  int _hintsUsed = 0;

  GameCubit({
    required this.storage,
    String Function()? todayProvider,
    this.onSubmitRun,
    this.onTierCompleted,
    this.onCoinsEarned,
  })  : todayProvider = todayProvider ?? utcToday,
        super(const GameInitial());

  Future<void> init({required Difficulty difficulty}) async {
    _difficulty = difficulty;
    _date = todayProvider();
    final seeder = DailySeeder(_date, difficulty);
    final start = seeder.generate();
    _dropTiers = start.dropTiers;
    _goldenDrops = seeder.goldenDropIndices();

    final snap = storage.loadSnapshot(_date, difficulty);
    if (snap != null && snap.date == _date) {
      // Resume today: rebuild the landing stream to the saved position.
      _landing = seeder.landingPrng();
      for (var i = 0; i < snap.board.dropIndex; i++) {
        _landing.nextU32();
      }
      if (snap.completed || snap.board.status != GameStatus.playing) {
        // Once-per-tier-per-day: a completed tier is locked, show the result.
        emit(GameOverShowScore(
            board: snap.board,
            date: _date,
            difficulty: difficulty,
            stats: storage.loadStats(difficulty)));
      } else {
        emit(GamePlaying(board: snap.board, difficulty: difficulty));
      }
      return;
    }

    // Fresh day for this tier.
    _landing = seeder.landingPrng();
    await storage.saveSnapshot(GameSnapshot(
        date: _date,
        difficulty: difficulty,
        board: start.board,
        completed: false));
    emit(GamePlaying(board: start.board, difficulty: difficulty));
  }

  Future<void> merge({required int fromIndex, required int toIndex}) async {
    final s = state;
    if (s is! GamePlaying) return;
    if (!GameEngine.canMerge(s.board, fromIndex, toIndex)) return;

    // Record the accepted move (same guard as the state change).
    final log = List<MoveEvent>.of(s.board.moveLog)
      ..add(MergeEvent(from: fromIndex, to: toIndex));

    // Golden bonus is computed against the PRE-merge board, then credited to the
    // wallet via the decoupled callback. It NEVER touches score or the move log.
    final goldenBonus =
        GameEngine.goldenBonusFor(s.board, fromIndex, toIndex);

    var board = GameEngine.merge(s.board, fromIndex: fromIndex, toIndex: toIndex)
        .copyWith(moveLog: log);
    if (board.dropIndex < _dropTiers.length) {
      board = GameEngine.applyDrop(
        board,
        _dropTiers[board.dropIndex],
        _landing,
        golden: _goldenDrops.contains(board.dropIndex),
      );
    }
    board = GameEngine.evaluateStatus(board);

    if (goldenBonus > 0) onCoinsEarned?.call(goldenBonus);

    final done = board.status != GameStatus.playing;
    await storage.saveSnapshot(GameSnapshot(
        date: _date,
        difficulty: _difficulty,
        board: board,
        completed: done));

    if (done) {
      final stats = await _recordCompletion(board);
      await _fireCompletionHook();
      emit(GameOverShowScore(
          board: board, date: _date, difficulty: _difficulty, stats: stats));
      // Submit to the leaderboard only when the day is genuinely terminal:
      // deadlocked, or out of moves with no remaining ad-continue offer. This
      // avoids submitting before the player takes an available ad continue.
      final terminal = board.status == GameStatus.deadlocked ||
          board.adContinuesUsed >= kMaxAdContinuesPerDay ||
          !GameEngine.hasMergeAvailable(board);
      if (terminal) {
        await _submit(board);
      }
    } else {
      emit(GamePlaying(board: board, difficulty: _difficulty));
    }
  }

  /// Whether another rewarded hint may be shown today (per-tier-day cap).
  bool get canUseHint {
    final s = state;
    return s is GamePlaying &&
        _hintsUsed < kMaxHintsPerDay &&
        s.board.dropIndex < _dropTiers.length;
  }

  /// The next drop tier the seed will deliver, or null if none remain.
  /// READ-ONLY: derived purely from the seed-fixed [_dropTiers] schedule indexed
  /// by the board's current `dropIndex`. It does NOT read or write board state
  /// beyond `dropIndex`, and emits no new state — so it cannot affect the run or
  /// leaderboard fairness. Returns null if the player has no live board.
  int? peekNextDropTier() {
    final s = state;
    if (s is! GamePlaying) return null;
    final i = s.board.dropIndex;
    if (i < 0 || i >= _dropTiers.length) return null;
    return _dropTiers[i];
  }

  /// Consume a rewarded-hint use and return the next drop tier. Call AFTER the
  /// rewarded ad grants its reward. Returns null (and consumes nothing) if no
  /// hint is available. FAIRNESS: this never mutates [BoardState]; it only reads
  /// the seed-fixed drop schedule and bumps an ad-frequency counter.
  int? revealNextDropAfterReward() {
    if (!canUseHint) return null;
    _hintsUsed++;
    return peekNextDropTier();
  }

  bool _completionFired = false;

  /// Fire the Phase 4 completion hook at most once per cubit lifetime. Off the
  /// critical path: a failing hook never blocks the result screen.
  Future<void> _fireCompletionHook() async {
    final hook = onTierCompleted;
    if (hook == null || _completionFired) return;
    _completionFired = true;
    try {
      await hook();
    } catch (_) {
      // Engagement bookkeeping is best-effort; play is never blocked by it.
    }
  }

  bool _submitted = false;

  /// Fire the online submit hook at most once per cubit lifetime.
  Future<void> _submit(BoardState board) async {
    final hook = onSubmitRun;
    if (hook == null || _submitted) return;
    _submitted = true;
    try {
      await hook(
        date: _date,
        difficulty: _difficulty,
        moveLog: board.moveLog,
        adContinues: board.adContinuesUsed,
      );
    } catch (_) {
      // Submission is off the critical path; the result screen never blocks.
      // Offline queue/retry is handled by the caller's service (future work).
    }
  }

  /// True when the player ran out of moves, a merge still exists, and the daily
  /// ad-continue allowance is not exhausted. Deadlock is never ad-revivable.
  bool get canOfferAd {
    final s = state;
    return s is GameOverShowScore &&
        s.board.status == GameStatus.outOfMoves &&
        s.board.adContinuesUsed < kMaxAdContinuesPerDay &&
        GameEngine.hasMergeAvailable(s.board);
  }

  Future<void> grantAdReward() async {
    final s = state;
    if (s is! GameOverShowScore) return;
    final log = List<MoveEvent>.of(s.board.moveLog)..add(const ContinueEvent());
    final board = s.board.copyWith(
      movesRemaining: s.board.movesRemaining + kAdMoveReward,
      adContinuesUsed: s.board.adContinuesUsed + 1,
      status: GameStatus.playing,
      moveLog: log,
    );
    await storage.saveSnapshot(GameSnapshot(
        date: _date,
        difficulty: _difficulty,
        board: board,
        completed: false));
    emit(GameAdRewardGranted(board: board, difficulty: _difficulty));
    emit(GamePlaying(board: board, difficulty: _difficulty));
  }

  /// Update per-tier lifetime stats once per completed day (idempotent within a
  /// day via lastCompletedDate guard).
  Future<LifetimeStats> _recordCompletion(BoardState board) async {
    final prev = storage.loadStats(_difficulty);
    if (prev.lastCompletedDate == _date) return prev;

    final yesterday = formatDate(
        DateTime.parse(_date).subtract(const Duration(days: 1)));
    final streak = prev.lastCompletedDate == yesterday ? prev.streak + 1 : 1;

    final updated = prev.copyWith(
      streak: streak,
      lastCompletedDate: _date,
      bestScore: board.score > prev.bestScore ? board.score : prev.bestScore,
      bestTier:
          board.highestTier > prev.bestTier ? board.highestTier : prev.bestTier,
    );
    await storage.saveStats(_difficulty, updated);
    return updated;
  }
}
