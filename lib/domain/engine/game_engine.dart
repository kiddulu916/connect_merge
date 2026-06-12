import '../constants.dart';
import '../models/board_state.dart';
import '../models/game_status.dart';
import '../models/tile.dart';
import 'prng.dart';

/// Pure game rules. Every method returns a NEW BoardState; nothing mutates.
class GameEngine {
  const GameEngine._();

  /// A legal merge: both cells hold tiles, distinct cells, equal tier, and the
  /// tier is below the cap (two max-tier tiles cannot fuse further).
  static bool canMerge(BoardState s, int fromIndex, int toIndex) {
    if (fromIndex == toIndex) return false;
    final from = s.cells[fromIndex];
    final to = s.cells[toIndex];
    if (from == null || to == null) return false;
    return from.tier == to.tier && from.tier < kMaxTier;
  }

  /// Fuse [fromIndex] into [toIndex]: destination becomes tier+1 (keeping its
  /// id for animation continuity), source empties, score += 2^newTier, one move
  /// is spent, movesMade increments.
  static BoardState merge(BoardState s,
      {required int fromIndex, required int toIndex}) {
    final to = s.cells[toIndex]!;
    final newTier = to.tier + 1;
    final cells = List<Tile?>.of(s.cells);
    cells[toIndex] = Tile(id: to.id, tier: newTier);
    cells[fromIndex] = null;
    return s.copyWith(
      cells: cells,
      score: s.score + (1 << newTier),
      movesRemaining: s.movesRemaining - 1,
      movesMade: s.movesMade + 1,
    );
  }

  /// Drop a tile of [tier] into a deterministically-chosen empty cell. The
  /// landing index is drawn from [landing] (stream B) mapped onto current
  /// empties, so the item is global but the position adapts to this board.
  ///
  /// When [golden] is true the dropped tile is marked golden (Phase 1): a
  /// purely visual/economy flag that credits bonus coins on merge and NEVER
  /// affects `score` or the move log. The landing draw is taken regardless of
  /// [golden] so the stream stays in lock-step for every player.
  static BoardState applyDrop(BoardState s, int tier, Prng landing,
      {bool golden = false}) {
    final empties = s.emptyIndices;
    if (empties.isEmpty) {
      // Invariant means this should never happen, but stay total.
      return s.copyWith(dropIndex: s.dropIndex + 1);
    }
    final idx = empties[landing.nextInt(empties.length)];
    final cells = List<Tile?>.of(s.cells);
    cells[idx] = Tile(id: s.nextTileId, tier: tier, golden: golden);
    return s.copyWith(
      cells: cells,
      nextTileId: s.nextTileId + 1,
      dropIndex: s.dropIndex + 1,
    );
  }

  /// Coins to credit when the merge of [fromIndex] into [toIndex] consumes one
  /// or more golden tiles. Pure and read-only — it inspects [before] (the board
  /// PRIOR to the merge) and returns a bonus; it NEVER mutates state or touches
  /// `score`. The cubit applies this to the client-side wallet, keeping the
  /// engine side-effect-free and replay fairness intact.
  static int goldenBonusFor(BoardState before, int fromIndex, int toIndex) {
    var golden = 0;
    final from = before.cells[fromIndex];
    final to = before.cells[toIndex];
    if (from != null && from.golden) golden++;
    if (to != null && to.golden) golden++;
    return golden * kGoldenMergeBonus;
  }

  /// True if any two live tiles share a tier below the cap (a legal merge).
  static bool hasMergeAvailable(BoardState s) {
    final seen = <int>{};
    for (final c in s.cells) {
      if (c == null || c.tier >= kMaxTier) continue;
      if (!seen.add(c.tier)) return true;
    }
    return false;
  }

  /// Resolve end-of-day status: out of moves first, then deadlock, else playing.
  static BoardState evaluateStatus(BoardState s) {
    if (s.movesRemaining <= 0) {
      return s.copyWith(status: GameStatus.outOfMoves);
    }
    if (!hasMergeAvailable(s)) {
      return s.copyWith(status: GameStatus.deadlocked);
    }
    return s.copyWith(status: GameStatus.playing);
  }
}
