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
      // The occupancy invariant (a merge always frees a cell before its drop)
      // guarantees this branch is unreachable. We assert loudly in debug because
      // taking it WITHOUT a landing draw would silently break the
      // `dropIndex == landing-draws` coupling that undo's `_rebuildLandingTo` and
      // init-on-resume both depend on (a latent PRNG desync vs the server replay).
      // We deliberately do NOT take a landing draw here (changing draw counts
      // would itself diverge from the server replay); we just stay total in
      // release by advancing dropIndex so the run can still finish.
      assert(
          empties.isNotEmpty,
          'occupancy invariant: a drop always has a landing cell; if this ever '
          'fires, the dropIndex==landing-draws coupling that undo/resume depend '
          'on is broken');
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

  /// True when cells [a] and [b] are orthogonal neighbours on the grid (no
  /// diagonals, no row wrap-around).
  static bool areOrthogonallyAdjacent(int a, int b) {
    final ra = a ~/ kGridSize, ca = a % kGridSize;
    final rb = b ~/ kGridSize, cb = b % kGridSize;
    final dr = (ra - rb).abs(), dc = (ca - cb).abs();
    return (dr + dc) == 1;
  }

  /// A legal Connect-Merge path: length >= 2, no repeated cells, each cell holds
  /// a live tile, all tiles share one tier below the cap, and consecutive cells
  /// are orthogonally adjacent. Walls hold no tile, so they are rejected by the
  /// null-cell check, but we never index a wall as a tile.
  static bool isValidChain(BoardState s, List<int> path) {
    if (path.length < 2) return false;
    final seen = <int>{};
    final first = s.cells[path.first];
    if (first == null || first.tier >= kMaxTier || s.walls.contains(path.first)) return false;
    final tier = first.tier;
    for (var i = 0; i < path.length; i++) {
      final idx = path[i];
      if (idx < 0 || idx >= kCellCount) return false;
      if (!seen.add(idx)) return false; // repeat
      if (s.walls.contains(idx)) return false; // reject walls
      final t = s.cells[idx];
      if (t == null || t.tier != tier) return false;
      if (i > 0 && !areOrthogonallyAdjacent(path[i - 1], idx)) return false;
    }
    return true;
  }

  /// Points for collapsing a chain of [chainLength] tiles of [mergedTier]. The
  /// base is the legacy `2^(mergedTier+1)` (so a 2-chain matches the old merge),
  /// scaled by the superlinear [comboMultiplier].
  static int comboScore(int mergedTier, int chainLength) =>
      (1 << (mergedTier + 1)) * comboMultiplier(chainLength);

  /// Collapse a validated Connect-Merge [path] onto its endpoint (`path.last`):
  /// the endpoint becomes tier+1 (keeping its id for animation continuity), all
  /// other path cells empty, score gains the combo total, one move is spent.
  /// Caller must have checked [isValidChain]. Mirrors [merge]: no drop, no log
  /// (the cubit applies the refill and records the [ChainEvent]).
  static BoardState collapseChain(BoardState s, List<int> path) {
    final endIdx = path.last;
    final endTile = s.cells[endIdx]!;
    final mergedTier = endTile.tier;
    final newTier = mergedTier + 1;
    final cells = List<Tile?>.of(s.cells);
    for (final idx in path) {
      cells[idx] = null;
    }
    cells[endIdx] = Tile(id: endTile.id, tier: newTier);
    return s.copyWith(
      cells: cells,
      score: s.score + comboScore(mergedTier, path.length),
      movesRemaining: s.movesRemaining - 1,
      movesMade: s.movesMade + 1,
    );
  }
}
