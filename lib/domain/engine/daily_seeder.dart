import 'dart:convert';
import 'package:crypto/crypto.dart';

import '../constants.dart';
import '../models/board_state.dart';
import '../models/challenge_rule.dart';
import '../models/daily_objective.dart';
import '../models/difficulty.dart';
import '../models/game_status.dart';
import '../models/tile.dart';
import 'game_engine.dart';
import 'prng.dart';

/// Everything the day needs, derived deterministically from the date.
class DailyStart {
  final BoardState board;
  final List<int> dropTiers; // length kMaxDrops; dropTiers[n] = tier of drop n
  const DailyStart(this.board, this.dropTiers);
}

/// Turns a `(YYYY-MM-DD, Difficulty)` pair into the day's board and drop
/// schedule. Each tier is a fully independent deterministic stream keyed by
/// `"$date:${difficulty.name}"`.
///
/// Two independent PRNG streams keep concerns decoupled:
///  - stream A (seedA): initial board placement + drop tiers (the global item
///    sequence — identical for every player on the same date+tier).
///  - stream B (seedB): landing-cell selection at drop time (mapped onto each
///    player's own empty cells, so position adapts locally).
class DailySeeder {
  final String date; // UTC YYYY-MM-DD
  final Difficulty difficulty;
  const DailySeeder(this.date, this.difficulty);

  /// Hashes an arbitrary seed key (e.g. `"2026-06-07:hard"`) to a 32-bit seed.
  static int seedForKey(String key) {
    final bytes = sha256.convert(utf8.encode(key)).bytes;
    return (bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)) &
        0xFFFFFFFF;
  }

  String get _key => '$date:${difficulty.name}';
  int get _seedA => seedForKey(_key);
  int get _seedB => seedForKey(_key) ^ 0x9E3779B9;

  /// The rule for today's Challenge board, derived from the `"$date:challenge"`
  /// seed. Deterministic — same date returns identical rule for every player.
  ChallengeRule get challengeRule {
    final idx = Prng(DailySeeder.seedForKey('$date:challenge')).nextInt(6);
    return ChallengeRule.values[idx];
  }

  /// The set of drop indices that are "golden" for this date+tier, derived from
  /// an independent `"$_key:gold"` sub-stream (decoupled from board placement,
  /// drop tiers, and landing). Same date+tier ⇒ identical set for every player.
  ///
  /// Golden is a purely visual/economy property carried on the dropped [Tile];
  /// it never affects `score` or the move log, so it cannot be forged for
  /// leaderboard gain (Phase 2 replay only sees tiers + moves).
  Set<int> goldenDropIndices() {
    final g = Prng(seedForKey('$_key:gold'));
    final out = <int>{};
    for (var n = 0; n < kMaxDrops; n++) {
      if (g.nextInt(100) < kGoldenDropPercent) out.add(n);
    }
    return out;
  }

  /// Private helper: draw [count] distinct wall indices from the walls stream.
  Set<int> _wallIndicesWithCount(int count) {
    if (count == 0) return const {};
    final w = Prng(seedForKey('$_key:walls'));
    final out = <int>{};
    while (out.length < count) {
      out.add(w.nextInt(difficulty.cellCount)); // rejection sampling; deterministic
    }
    return out;
  }

  /// Deterministic wall cells for this date+tier, drawn from an independent
  /// `'$_key:walls'` stream so it never perturbs board/drop/landing streams.
  Set<int> wallIndices() => _wallIndicesWithCount(wallCountFor(difficulty));

  DailyStart generate({
    int? startingFillOverride,
    int? wallCountOverride,
    int? movesOverride,
  }) {
    final a = Prng(_seedA);
    final walls = _wallIndicesWithCount(wallCountOverride ?? wallCountFor(difficulty));
    final startingFill = startingFillOverride ?? difficulty.startingFill;
    final cellCount = difficulty.cellCount;
    final movesRemaining = movesOverride ?? kMovesPerDay;

    // Re-roll loop: keep drawing placements from stream A until the resulting
    // board has at least one orthogonally-adjacent mergeable pair (same tier or
    // ascend-by-one — GameEngine.hasMergeAvailable) so no player ever starts on
    // a born-deadlocked board. Mirrored in supabase/functions/_shared/seeder.ts
    // (hasAdjacentMergeablePair).
    //
    // Determinism is preserved: same (date, difficulty) → same sequence of
    // re-roll attempts → same first valid board for every player.
    //
    // Already-playable dates exit on the first attempt and consume exactly the
    // same PRNG draws as before, so their boards are byte-identical to the
    // pre-fix output.
    //
    // A hard attempt cap surfaces pathological seeds loudly (in tests) rather
    // than hanging. It should never trigger in practice.
    const maxAttempts = 5000;

    List<Tile?> cells;
    int nextId;

    var attempts = 0;
    while (true) {
      attempts++;
      if (attempts > maxAttempts) {
        throw StateError(
          'DailySeeder.generate: could not find a non-deadlocked placement '
          'for $_key after $maxAttempts attempts. '
          'This indicates a pathological seed and must be investigated.',
        );
      }

      // Fresh placement attempt — reset counters each time so tile ids are clean.
      cells = List<Tile?>.filled(cellCount, null);
      nextId = 0;
      var placed = 0;
      while (placed < startingFill) {
        final idx = a.nextInt(cellCount);
        if (cells[idx] != null || walls.contains(idx)) continue;
        cells[idx] = Tile(id: nextId++, tier: 1 + a.nextInt(2));
        placed++;
      }

      // Quick validity check: build a candidate board and test adjacency.
      final candidate = BoardState(
        cells: cells,
        movesRemaining: movesRemaining,
        score: 0,
        nextTileId: nextId,
        dropIndex: 0,
        adContinuesUsed: 0,
        movesMade: 0,
        status: GameStatus.playing,
        walls: walls,
        gridSize: difficulty.gridSize,
      );
      if (GameEngine.hasMergeAvailable(candidate)) break;
      // Otherwise continue — stream A is already advanced; next loop attempt
      // picks up exactly where it left off (deterministic re-roll).
    }

    // Drop schedule: tiers only. Band widens by drop index n.
    // Generated AFTER placement on whatever stream-A position remains, exactly
    // as before. The daily cubit no longer uses it but practice/server/tests do.
    final tiers = <int>[];
    for (var n = 0; n < kMaxDrops; n++) {
      tiers.add(1 + a.nextInt(dropCap(n)));
    }

    final board = BoardState(
      cells: cells,
      movesRemaining: movesRemaining,
      score: 0,
      nextTileId: nextId,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 0,
      status: GameStatus.playing,
      walls: walls,
      gridSize: difficulty.gridSize,
    );
    return DailyStart(board, tiers);
  }

  /// Fresh landing stream (stream B). Advance it `board.dropIndex` times when
  /// resuming a saved game to reach the correct position.
  Prng landingPrng() => Prng(_seedB);

  /// Fresh on-demand drop-tier stream (decoupled from board placement so refills
  /// can be unbounded). Advance it in drop-index order via [dropTierAt].
  Prng dropTierPrng() => Prng(seedForKey('$_key:drops'));

  /// Tier for drop number [n], drawn from [p] (which the caller advances in
  /// index order). Band widens by drop index, identical for all players.
  int dropTierAt(Prng p, int n) => 1 + p.nextInt(dropCap(n));

  /// Deterministic daily objective from an independent `'$_key:obj'` stream.
  DailyObjective dailyObjective() {
    final o = Prng(seedForKey('$_key:obj'));
    final kind = ObjectiveKind.values[o.nextInt(ObjectiveKind.values.length)];
    final target = switch (kind) {
      ObjectiveKind.chainLength => 4 + o.nextInt(3), // 4..6
      ObjectiveKind.reachTier => 6 + o.nextInt(3), // 6..8
    };
    return DailyObjective(kind: kind, target: target);
  }
}
