import 'dart:convert';
import 'package:crypto/crypto.dart';

import '../constants.dart';
import '../models/board_state.dart';
import '../models/difficulty.dart';
import '../models/game_status.dart';
import '../models/tile.dart';
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

  DailyStart generate() {
    final a = Prng(_seedA);

    // Initial board: difficulty.startingFill tiles of tier 1-2 in
    // deterministic cells.
    final cells = List<Tile?>.filled(kCellCount, null);
    var nextId = 0;
    var placed = 0;
    final startingFill = difficulty.startingFill;
    while (placed < startingFill) {
      final idx = a.nextInt(kCellCount);
      if (cells[idx] != null) continue; // rejection sampling; deterministic
      cells[idx] = Tile(id: nextId++, tier: 1 + a.nextInt(2));
      placed++;
    }

    // Drop schedule: tiers only. Band widens by drop index n.
    final tiers = <int>[];
    for (var n = 0; n < kMaxDrops; n++) {
      tiers.add(1 + a.nextInt(dropCap(n)));
    }

    final board = BoardState(
      cells: cells,
      movesRemaining: kMovesPerDay,
      score: 0,
      nextTileId: nextId,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 0,
      status: GameStatus.playing,
    );
    return DailyStart(board, tiers);
  }

  /// Fresh landing stream (stream B). Advance it `board.dropIndex` times when
  /// resuming a saved game to reach the correct position.
  Prng landingPrng() => Prng(_seedB);
}
