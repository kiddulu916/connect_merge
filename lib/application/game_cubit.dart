import 'package:flutter_bloc/flutter_bloc.dart';

import '../domain/constants.dart';
import '../domain/date_utils.dart' as date_utils;
import '../domain/engine/daily_seeder.dart';
import '../domain/engine/game_engine.dart';
import '../domain/engine/prng.dart';
import '../domain/models/board_state.dart';
import '../domain/models/challenge_rule.dart';
import '../domain/models/daily_objective.dart';
import '../domain/models/difficulty.dart';
import '../domain/models/day_result.dart';
import '../domain/models/game_status.dart';
import '../domain/models/move.dart';
import '../domain/models/streak.dart' show nextStreak;
import '../infrastructure/storage_service.dart';
import 'game_state.dart';

/// One entry in the bounded undo history (Phase 4). Captures the FULL pre-merge
/// [board] (cells, score, moves, dropIndex, AND moveLog) so [GameCubit.undo]
/// can restore the run atomically. [landingDraws] is the number of landing-PRNG
/// draws taken before that merge (== the pre-merge `board.dropIndex`), used to
/// deterministically rewind the landing stream by rebuild-and-advance.
class _UndoFrame {
  final BoardState board;
  final int landingDraws;

  /// Coins this move credited to the wallet (golden bonus + objective reward if
  /// applicable). Refunded on undo so move→undo→re-move cannot farm coins.
  /// 0 when the move credited nothing.
  final int coinsCredited;

  /// Whether this move was the one that first met the daily objective and
  /// credited [kObjectiveRewardCoins]. When true, [_applyUndo] resets
  /// [_objectiveMet] so the objective can be re-earned exactly once after undo
  /// — identical anti-farming invariant as golden coins.
  final bool objectiveCredited;

  const _UndoFrame({
    required this.board,
    required this.landingDraws,
    this.coinsCredited = 0,
    this.objectiveCredited = false,
  });
}

/// Formats a DateTime as the canonical YYYY-MM-DD seeding key.
/// Delegates to [domain/date_utils.dart]; kept here so callers that already
/// `import 'game_cubit.dart' show formatDate` continue to compile unchanged.
String formatDate(DateTime d) => date_utils.formatDate(d);

/// The canonical UTC date string used for seeding and storage everywhere.
/// Delegates to [domain/date_utils.dart]; kept here for backward compatibility.
String utcToday() => date_utils.utcToday();

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

  /// Optional completion hook (Phase 4 / Phase 2). Fired once per locked day,
  /// after stats are recorded, so the engagement layer can advance the headline
  /// streak, evaluate achievements, fold meta-progression (XP + almanac), and
  /// reschedule notifications. Receives the finished run's [score] and
  /// [highestTier] for the Phase-2 XP/almanac fold — these are read-only run
  /// summaries; the hook is purely client-side and NEVER affects score/replay.
  /// Decoupled (a plain callback) so the cubit stays plugin-free + testable.
  final Future<void> Function({int score, int highestTier})? onTierCompleted;

  /// Optional coins hook (Phase 1). Fired with a SIGNED [delta] (positive to
  /// credit, negative to refund) so the client-side wallet can be both credited
  /// on a golden merge / completion AND refunded when that merge is undone
  /// (preventing merge→undo→re-merge coin farming). Awaited so the wallet write
  /// is durable. Decoupled (like [onTierCompleted]) — coins NEVER touch `score`.
  final Future<void> Function(int delta)? onCoinsEarned;

  late Difficulty _difficulty;
  late String _date;

  /// The active challenge rule (non-null only in challenge mode).
  ChallengeRule? _activeRule;

  /// Effective starting fill, accounting for challenge rule overrides.
  late int _targetFill;

  /// On-demand drop-tier stream (stream "drops"), advanced in lock-step with
  /// dropIndex exactly like [_landing]. Rebuilt by replay on resume/undo.
  late Prng _dropTier;

  /// The day's objective (seed-derived). Read by the UI and tracked per chain.
  late DailyObjective _objective;
  DailyObjective get objective => _objective;

  /// The active challenge rule, or null when not in challenge mode.
  ChallengeRule? get activeRule => _activeRule;

  late Prng _landing;

  /// The day's seeder, retained so the landing PRNG can be rebuilt from seed and
  /// advanced to an arbitrary draw count (the deterministic rewind used by both
  /// [init] on resume and [undo]).
  late DailySeeder _seeder;

  /// Drop indices that are golden for this date+tier (seed-derived).
  late Set<int> _goldenDrops;

  /// Bounded undo history (Phase 4): pre-merge frames, most-recent last. Capped
  /// at [kUndoStackDepth] so memory stays trivial and a player can never rewind
  /// to the start of the run.
  final List<_UndoFrame> _undoStack = [];

  /// Undos consumed this cubit lifetime (one tier's day). Gates the
  /// [kFreeUndosPerDay] free cap; further undos require a rewarded-ad grant.
  int _undosUsed = 0;

  /// Whether the player may undo right now: there is a frame to pop and the run
  /// is still live ([GamePlaying]). Free/ad gating is enforced separately in
  /// [undo] / [undoAfterReward].
  bool get canUndo => state is GamePlaying && _undoStack.isNotEmpty;

  /// Whether an undo is available WITHOUT a rewarded ad (a free undo remains).
  bool get canUndoFree => canUndo && _undosUsed < kFreeUndosPerDay;

  /// Rewarded-hint usage this cubit lifetime (one tier's day). Gates the
  /// per-day cap on the reveal-next-drop hint.
  int _hintsUsed = 0;

  /// Coins earned this run (golden merges + completion bonus). Tracked so the
  /// result screen can offer a rewarded "double coins" that credits the same
  /// amount again. Purely client-side bookkeeping — never affects score.
  int _coinsEarnedThisRun = 0;

  /// Whether the rewarded "double coins" reward has already been taken this run
  /// (idempotency guard, so the double can't be claimed twice).
  bool _coinsDoubled = false;

  /// Total coins earned this run so far (golden + completion). Read by the
  /// result screen to offer the double-coins ad.
  int get coinsEarnedThisRun => _coinsEarnedThisRun;

  /// Whether the double-coins reward has already been claimed this run.
  bool get coinsDoubled => _coinsDoubled;

  /// Whether the objective reward has already been paid this run (idempotency).
  bool _objectiveMet = false;

  /// Prevent overlapping rewarded-ad callbacks from granting twice while the
  /// first snapshot write is still in flight.
  bool _grantingAd = false;

  /// Optional error-reporting hook (observability). Fired for exceptions that
  /// are currently swallowed silently (best-effort background work — a
  /// failing hook never blocks gameplay). Signature matches
  /// `CrashReportingService.recordError` exactly, so callers can pass the
  /// method directly (e.g. `onError: crashReporting.recordError`).
  ///
  /// Stored as a private field (`_onError`) rather than `this.onError`
  /// because `Cubit`/`BlocBase` already declares an inherited instance
  /// method named `onError` (its internal stream-error hook) — a field of
  /// the same name is not a compatible override and fails to compile. The
  /// public constructor parameter is still named `onError` so callers are
  /// unaffected.
  final void Function(Object error, StackTrace? stack, {bool fatal})?
      _onError;

  /// Optional analytics hook (observability). Signature matches
  /// `AnalyticsService.logEvent` exactly, so callers can pass the method
  /// directly (e.g. `onAnalyticsEvent: analytics.logEvent`).
  final void Function(String name, [Map<String, Object?>? params])?
      onAnalyticsEvent;

  GameCubit({
    required this.storage,
    String Function()? todayProvider,
    this.onSubmitRun,
    this.onTierCompleted,
    this.onCoinsEarned,
    void Function(Object error, StackTrace? stack, {bool fatal})? onError,
    this.onAnalyticsEvent,
  })  : todayProvider = todayProvider ?? utcToday,
        _onError = onError,
        super(const GameInitial());

  Future<void> init({
    required Difficulty difficulty,
    ChallengeRule? ruleOverride, // for testing; production derives from seeder
  }) async {
    _difficulty = difficulty;
    _date = todayProvider();
    _seeder = DailySeeder(_date, difficulty);
    _goldenDrops = _seeder.goldenDropIndices();
    _objective = _seeder.dailyObjective();
    // A fresh init (or resume) starts with no rewindable history.
    _undoStack.clear();
    _undosUsed = 0;
    _objectiveMet = false;

    // Derive rule + generate board BEFORE snapshot check so a resumed challenge
    // game also has correct _activeRule / _targetFill when playChain is called.
    final DailyStart start;
    if (difficulty == Difficulty.challenge) {
      _activeRule = ruleOverride ?? _seeder.challengeRule;
      final rule = _activeRule!;
      final fill = switch (rule) {
        ChallengeRule.denseStart => kChallengeDenseFill,
        ChallengeRule.sparseStart => kChallengeSparseFill,
        _ => difficulty.startingFill,
      };
      final wallCount =
          rule == ChallengeRule.wallMaze ? kChallengeWallMazeCount : null;
      final moves =
          rule == ChallengeRule.budgetCut ? kChallengeMoves : null;
      _targetFill = fill;
      start = _seeder.generate(
        startingFillOverride: fill,
        wallCountOverride: wallCount,
        movesOverride: moves,
      );
    } else {
      _activeRule = null;
      _targetFill = difficulty.startingFill;
      start = _seeder.generate();
    }

    final snap = storage.loadSnapshot(_date, difficulty);
    if (snap != null && snap.date == _date && snap.version == kSnapshotVersion) {
      // Resume today: rebuild both streams to the saved position.
      _dropTier = _rebuildDropTierTo(snap.board.dropIndex);
      _landing = _rebuildLandingTo(snap.board.dropIndex);
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
    _landing = _seeder.landingPrng();
    _dropTier = _seeder.dropTierPrng();
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

    // Golden bonus is computed against the PRE-merge board, then credited to the
    // wallet via the decoupled callback. It NEVER touches score or the move log.
    // Computed BEFORE pushing the undo frame so the frame can carry the credited
    // amount for an exact refund on undo.
    final goldenBonus =
        GameEngine.goldenBonusFor(s.board, fromIndex, toIndex);

    // Push a pre-merge frame so this merge can be undone. The landing PRNG has
    // taken exactly `dropIndex` draws at this point (one per applied drop), so
    // that count is the deterministic rewind target. Bounded depth. The frame
    // records the golden coins this merge credited so undo refunds them.
    _undoStack.add(_UndoFrame(
      board: s.board,
      landingDraws: s.board.dropIndex,
      coinsCredited: goldenBonus,
    ));
    if (_undoStack.length > kUndoStackDepth) {
      _undoStack.removeAt(0);
    }

    // Record the accepted move (same guard as the state change).
    final log = List<MoveEvent>.of(s.board.moveLog)
      ..add(MergeEvent(from: fromIndex, to: toIndex));

    var board = GameEngine.merge(s.board, fromIndex: fromIndex, toIndex: toIndex)
        .copyWith(moveLog: log);
    // Use the on-demand drop-tier stream (unbounded, no guard needed).
    board = GameEngine.applyDrop(
      board,
      _seeder.dropTierAt(_dropTier, board.dropIndex),
      _landing,
      golden: _goldenDrops.contains(board.dropIndex),
    );
    board = GameEngine.evaluateStatus(board);

    if (goldenBonus > 0) {
      _coinsEarnedThisRun += goldenBonus;
      await onCoinsEarned?.call(goldenBonus);
    }

    final done = board.status != GameStatus.playing;
    await storage.saveSnapshot(GameSnapshot(
        date: _date,
        difficulty: _difficulty,
        board: board,
        completed: done));

    if (done) {
      await _finishRun(board);
    } else {
      emit(GamePlaying(board: board, difficulty: _difficulty));
    }
  }

  /// Play a Connect-Merge: validate [path], collapse it, refill the board to the
  /// difficulty's starting fill, track the daily objective, then persist/emit.
  /// Mirrors [merge]'s lifecycle (undo frame, golden bonus, completion hooks).
  Future<void> playChain(List<int> path) async {
    final s = state;
    if (s is! GamePlaying) return;
    // Long Chains Only rule: reject chains shorter than 3 tiles.
    if (_activeRule == ChallengeRule.longChainsOnly && path.length < 3) return;
    if (!GameEngine.isValidChain(s.board, path)) return;

    // Golden bonus: every golden tile consumed anywhere in the path pays out.
    // Computed on the PRE-collapse board; never touches score/log.
    var goldenBonus = 0;
    for (final idx in path) {
      if (s.board.cells[idx]?.golden ?? false) goldenBonus += kGoldenMergeBonus;
    }

    // Capture the pre-move board for the undo frame (must happen before any
    // mutations). The frame is pushed AFTER computing justMet so it can record
    // the full refundable amount (golden + objective) and the objective flag.
    final preBoard = s.board;
    final preLandingDraws = s.board.dropIndex;

    final log = List<MoveEvent>.of(s.board.moveLog)..add(ChainEvent(path: path));

    var board = GameEngine.collapseChain(
      s.board,
      path,
      comboMultiplierFn: _activeRule == ChallengeRule.comboRush
          ? comboRushMultiplier
          : null,
    ).copyWith(moveLog: log);

    // GameEngine owns the mirrored refill policy; the cubit supplies only the
    // seed-fixed tier schedule, landing stream, and cosmetic golden indices.
    board = GameEngine.refill(
      board,
      targetFill: _targetFill,
      tierAt: (i) => _seeder.dropTierAt(_dropTier, i),
      landing: _landing,
      goldenDrops: _goldenDrops,
    );

    // Track the daily objective (monotonic; recomputable on replay).
    final newProgress = _objective.progressAfter(
      board.objectiveProgress,
      chainLength: path.length,
      highestTier: board.highestTier,
    );
    final justMet = !_objectiveMet &&
        !_objective.isMet(board.objectiveProgress) &&
        _objective.isMet(newProgress);
    board = board.copyWith(objectiveProgress: newProgress);

    board = GameEngine.evaluateStatus(board);

    // Push the undo frame now that we know the full economic effect of this
    // move. The frame carries both the golden bonus and the objective reward
    // (if just earned) so _applyUndo can refund the exact credited amount and
    // reset the _objectiveMet flag — identical anti-farming invariant as golden.
    _undoStack.add(_UndoFrame(
      board: preBoard,
      landingDraws: preLandingDraws,
      coinsCredited: goldenBonus + (justMet ? kObjectiveRewardCoins : 0),
      objectiveCredited: justMet,
    ));
    if (_undoStack.length > kUndoStackDepth) _undoStack.removeAt(0);

    if (goldenBonus > 0) {
      _coinsEarnedThisRun += goldenBonus;
      await onCoinsEarned?.call(goldenBonus);
    }
    if (justMet) {
      _objectiveMet = true;
      _coinsEarnedThisRun += kObjectiveRewardCoins;
      await onCoinsEarned?.call(kObjectiveRewardCoins);
    }

    final done = board.status != GameStatus.playing;
    await storage.saveSnapshot(GameSnapshot(
        date: _date,
        difficulty: _difficulty,
        board: board,
        completed: done));

    if (done) {
      await _finishRun(board);
    } else {
      emit(GamePlaying(board: board, difficulty: _difficulty));
    }
  }

  /// The next [count] drop tiers, peeked without consuming the live stream.
  /// Returns fewer only at the theoretical schedule edge (never in practice —
  /// the stream is unbounded). Powers the visible planning queue.
  List<int> peekDropTiers([int count = kDropQueueVisible]) {
    final s = state;
    final dropIndex = s is GamePlaying ? s.board.dropIndex : 0;
    final p = _rebuildDropTierTo(dropIndex);
    return [for (var k = 0; k < count; k++) _seeder.dropTierAt(p, dropIndex + k)];
  }

  /// Shared completion tail: record stats, emit result screen, fire hooks.
  /// Called by both [merge] and [playChain] when the run terminates.
  Future<void> _finishRun(BoardState board) async {
    final firstCompletionToday =
        storage.loadStats(_difficulty).lastCompletedDate != _date;
    final stats = await _recordCompletion(board);
    // Flat completion reward, credited once per locked day via the wallet hook
    // — never touches score. Tracked so it can be doubled.
    if (firstCompletionToday && kCompletionCoinReward > 0) {
      _coinsEarnedThisRun += kCompletionCoinReward;
      await onCoinsEarned?.call(kCompletionCoinReward);
    }
    // Record the day's result in the append-only history, once per locked
    // tier-day (same guard as the stats fold). Clear the rewindable history too.
    if (firstCompletionToday) {
      await storage.appendResult(DayResult(
        date: _date,
        difficulty: _difficulty,
        score: board.score,
        highestTier: board.highestTier,
        // Factual end state (not a win/loss): out-of-moves vs deadlocked.
        endedOutOfMoves: board.status == GameStatus.outOfMoves,
      ));
    }
    _undoStack.clear();
    await _fireCompletionHook(board);
    emit(GameOverShowScore(
        board: board, date: _date, difficulty: _difficulty, stats: stats));
    // Submit to the leaderboard (and fire the run_completed analytics event)
    // only when the day is genuinely terminal: deadlocked, or out of moves
    // with no remaining ad-continue offer. This avoids submitting — and
    // double-counting analytics — before the player takes an available ad
    // continue; _finishRun can otherwise run once per ad continue taken.
    final terminal = board.status == GameStatus.deadlocked ||
        board.adContinuesUsed >= kMaxAdContinuesPerDay ||
        !GameEngine.hasMergeAvailable(board);
    if (terminal) {
      onAnalyticsEvent?.call('run_completed', {
        'difficulty': _difficulty.name,
        'score': board.score,
        'highestTier': board.highestTier,
        'moveCount': board.movesMade,
      });
      await _submit(board);
    }
  }

  /// Deterministically rebuild the landing PRNG (stream B) and advance it to
  /// [draws] draws taken. This is the exact rewind technique [init] uses on
  /// resume: the stream is reproducible, so rebuilding from seed and re-drawing
  /// N times lands on the same position as having drawn N times originally —
  /// never reverse a PRNG.
  Prng _rebuildLandingTo(int draws) {
    final p = _seeder.landingPrng();
    for (var i = 0; i < draws; i++) {
      p.nextU32();
    }
    return p;
  }

  /// Rebuild the drop-tier stream and advance it to [draws] taken (one draw per
  /// applied drop), mirroring [_rebuildLandingTo]. Deterministic rewind.
  Prng _rebuildDropTierTo(int draws) {
    final p = _seeder.dropTierPrng();
    for (var i = 0; i < draws; i++) {
      _seeder.dropTierAt(p, i);
    }
    return p;
  }

  /// Undo the last merge (Phase 4), keeping the run replay-consistent. Restores
  /// the pre-merge [BoardState] (cells, score, moves, dropIndex, AND moveLog —
  /// so the trailing [MergeEvent] and the drop it caused are popped together),
  /// then rewinds the landing PRNG to the saved draw count by deterministic
  /// rebuild. Only valid during [GamePlaying]; no-op on an empty stack. Gated by
  /// [kFreeUndosPerDay]; further undos require [undoAfterReward].
  ///
  /// INVARIANT: because the popped frame's board carries the pre-merge moveLog,
  /// the persisted moveLog always equals the real board history after any
  /// merge/undo sequence ⇒ Phase 2 server replay still reproduces the board.
  Future<void> undo() async {
    if (!canUndoFree) return;
    _undosUsed++;
    await _applyUndo();
  }

  /// Grant exactly one extra undo after a rewarded ad (call AFTER the ad's
  /// reward fires). No-op if no frame is available or the run is locked. Does
  /// NOT consume a free undo — it bypasses the [kFreeUndosPerDay] cap.
  Future<void> undoAfterReward() async {
    if (!canUndo) return;
    await _applyUndo();
  }

  /// Pop the most-recent frame and restore board + landing-PRNG + drop-tier-PRNG
  /// together.
  Future<void> _applyUndo() async {
    final frame = _undoStack.removeLast();
    // Refund any coins this move credited (golden bonus + objective reward),
    // so move→undo→re-move can't farm coins. Floor the run tally at 0 and
    // refund the wallet (signed delta).
    if (frame.coinsCredited > 0) {
      _coinsEarnedThisRun -= frame.coinsCredited;
      if (_coinsEarnedThisRun < 0) _coinsEarnedThisRun = 0;
      await onCoinsEarned?.call(-frame.coinsCredited);
    }
    // If this frame was the one that first met the daily objective, reset the
    // flag so it can be legitimately re-earned after the undo — exactly once,
    // never farmed (same invariant as golden coins).
    if (frame.objectiveCredited) _objectiveMet = false;
    // Rewind stream B and drop-tier stream to the saved position (deterministic
    // rebuild). Both streams must be rewound in lock-step to prevent PRNG desync.
    _landing = _rebuildLandingTo(frame.landingDraws);
    _dropTier = _rebuildDropTierTo(frame.landingDraws);
    // Persist the restored (not-completed) board so a resume sees the rewind.
    await storage.saveSnapshot(GameSnapshot(
        date: _date,
        difficulty: _difficulty,
        board: frame.board,
        completed: false));
    emit(GamePlaying(board: frame.board, difficulty: _difficulty));
  }

  /// Whether another rewarded hint may be shown today (per-tier-day cap).
  bool get canUseHint {
    final s = state;
    return s is GamePlaying && _hintsUsed < kMaxHintsPerDay;
  }

  /// The next drop tier the seed will deliver. READ-ONLY: peeked from the
  /// on-demand stream without consuming it. Returns null if no live board.
  int? peekNextDropTier() {
    final s = state;
    if (s is! GamePlaying) return null;
    final tiers = peekDropTiers(1);
    return tiers.isEmpty ? null : tiers.first;
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

  /// Fire the completion hook at most once per cubit lifetime, passing the
  /// finished [board]'s `score` + `highestTier` so the engagement layer can fold
  /// XP and the almanac. Off the critical path: a failing hook never blocks the
  /// result screen, and the run summary is read-only (never mutates the board).
  Future<void> _fireCompletionHook(BoardState board) async {
    final hook = onTierCompleted;
    if (hook == null || _completionFired) return;
    _completionFired = true;
    try {
      await hook(score: board.score, highestTier: board.highestTier);
    } catch (e, st) {
      // Engagement bookkeeping is best-effort; play is never blocked by it.
      _onError?.call(e, st);
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
    } catch (e, st) {
      // Submission is off the critical path; the result screen never blocks.
      // Offline queue/retry is handled by the caller's service (future work).
      _onError?.call(e, st);
    }
  }

  /// Submit the current finished score when the player explicitly exits without
  /// taking an ad continue. Safe to call even if the score was already submitted
  /// (the [_submitted] guard makes [_submit] idempotent). No-op outside of
  /// [GameOverShowScore] state.
  Future<void> submitIfPending() async {
    final s = state;
    if (s is GameOverShowScore) await _submit(s.board);
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
    if (!canOfferAd) return;
    if (_grantingAd) return;
    try {
      _grantingAd = true;
      final s = state as GameOverShowScore;
      final log = List<MoveEvent>.of(s.board.moveLog)
        ..add(const ContinueEvent());
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
    } finally {
      _grantingAd = false;
    }
  }

  /// Double the coins earned this run (Phase 2). Call AFTER a rewarded ad
  /// grants. Credits the run's earned coins a second time via the same wallet
  /// hook. Idempotent: a no-op if already doubled or nothing was earned. Returns
  /// the amount credited (0 when nothing happened). NEVER affects score.
  Future<int> doubleRunCoins() async {
    if (_coinsDoubled || _coinsEarnedThisRun <= 0) return 0;
    _coinsDoubled = true;
    final bonus = _coinsEarnedThisRun;
    await onCoinsEarned?.call(bonus);
    return bonus;
  }

  /// Update per-tier lifetime stats once per completed day (idempotent within a
  /// day via lastCompletedDate guard).
  Future<LifetimeStats> _recordCompletion(BoardState board) async {
    final prev = storage.loadStats(_difficulty);
    if (prev.lastCompletedDate == _date) return prev;

    final yesterday = date_utils.previousUtcDay(_date);
    final streak = nextStreak(
      prev: prev.streak,
      last: prev.lastCompletedDate,
      today: _date,
      hasFreeze: false,
    ).streak;

    // A genuine gap (a prior completion date exists, isn't today, isn't
    // yesterday) resets this per-tier streak with no freeze support (unlike
    // the headline streak in EngagementCubit) — that reset is a churn signal
    // worth surfacing once, using the streak value BEFORE the reset.
    if (prev.lastCompletedDate != null &&
        prev.lastCompletedDate != yesterday &&
        prev.streak > 0) {
      onAnalyticsEvent?.call('streak_broken', {
        'streakType': 'perTier',
        'difficulty': _difficulty.name,
        'length': prev.streak,
      });
    }

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
