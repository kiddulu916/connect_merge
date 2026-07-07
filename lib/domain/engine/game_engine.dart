import '../constants.dart';
import '../models/board_state.dart';
import '../models/game_status.dart';
import '../models/tile.dart';
import 'prng.dart';

/// Pure game rules. Every method returns a NEW BoardState; nothing mutates.
class GameEngine {
  const GameEngine._();

  /// A legal merge: both cells hold tiles, distinct cells, and [toIndex]'s
  /// tier is either equal to or exactly one higher than [fromIndex]'s tier
  /// (same-tier merge, or ascend-by-1 into the destination), below the cap.
  static bool canMerge(BoardState s, int fromIndex, int toIndex) {
    if (fromIndex == toIndex) return false;
    final from = s.cells[fromIndex];
    final to = s.cells[toIndex];
    if (from == null || to == null) return false;
    final delta = to.tier - from.tier;
    return delta >= 0 && delta <= 1 && to.tier < kMaxTier;
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

  /// True if any two orthogonally-adjacent live tiles could legally merge in
  /// SOME direction (a legal Connect-Merge of length 2): their tiers differ by
  /// at most one, and the higher of the two is below the cap. Position matters:
  /// a mergeable pair that is not adjacent does NOT count, so a player can
  /// strand tiles into a deadlock.
  static bool hasMergeAvailable(BoardState s) {
    final gs = s.gridSize;
    for (var i = 0; i < s.cells.length; i++) {
      final t = s.cells[i];
      if (t == null) continue;
      final row = i ~/ gs, col = i % gs;
      // Check east and south neighbours only (covers every adjacency once).
      if (col + 1 < gs) {
        final e = s.cells[i + 1];
        if (e != null && _pairMergeable(t, e)) return true;
      }
      if (row + 1 < gs) {
        final so = s.cells[i + gs];
        if (so != null && _pairMergeable(t, so)) return true;
      }
    }
    return false;
  }

  /// True if two adjacent tiles could legally merge in SOME direction: their
  /// tiers differ by at most one, and the higher of the two is below the cap
  /// (the higher tile is always the destination, per [canMerge]/[isValidChain]).
  static bool _pairMergeable(Tile a, Tile b) {
    final delta = (a.tier - b.tier).abs();
    if (delta > 1) return false;
    final higher = a.tier > b.tier ? a.tier : b.tier;
    return higher < kMaxTier;
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
  static bool areOrthogonallyAdjacent(int a, int b, int gridSize) {
    final ra = a ~/ gridSize, ca = a % gridSize;
    final rb = b ~/ gridSize, cb = b % gridSize;
    final dr = (ra - rb).abs(), dc = (ca - cb).abs();
    return (dr + dc) == 1;
  }

  /// A legal Connect-Merge path: length >= 2, no repeated cells, each cell
  /// holds a live tile, consecutive cells are orthogonally adjacent, and each
  /// step's tier is either equal to or exactly one higher than the previous
  /// tile's tier (never descends, never skips a tier). Since the path is thus
  /// non-decreasing, [path.last] is always the peak tile, and it alone must
  /// sit below the cap. Walls hold no tile, so they are rejected by the
  /// null-cell check, but we never index a wall as a tile.
  static bool isValidChain(BoardState s, List<int> path) {
    if (path.length < 2) return false;
    final seen = <int>{};
    Tile? prevTile;
    for (var i = 0; i < path.length; i++) {
      final idx = path[i];
      if (idx < 0 || idx >= s.cells.length) return false;
      if (!seen.add(idx)) return false; // repeat
      if (s.walls.contains(idx)) return false; // reject walls
      final t = s.cells[idx];
      if (t == null) return false;
      if (prevTile != null) {
        final delta = t.tier - prevTile.tier;
        if (delta < 0 || delta > 1) return false; // no descend, no tier skip
        if (!areOrthogonallyAdjacent(path[i - 1], idx, s.gridSize)) return false;
      }
      prevTile = t;
    }
    if (prevTile!.tier >= kMaxTier) return false; // peak tile must be below cap
    return true;
  }

  /// Points for collapsing a chain of [chainLength] tiles of [mergedTier]. The
  /// base is the legacy `2^(mergedTier+1)` (so a 2-chain matches the old merge),
  /// scaled by the superlinear [comboMultiplier].
  static int comboScore(int mergedTier, int chainLength) =>
      (1 << (mergedTier + 1)) * comboMultiplier(chainLength);

  /// Collapse a validated Connect-Merge [path] onto its endpoint (`path.last`):
  /// the endpoint becomes tier+1 (keeping its id for animation continuity), all
  /// other path cells empty, score gains the combo total PLUS an
  /// [ascendBonus] for every ascend transition in the path, one move is spent.
  /// Caller must have checked [isValidChain]. Mirrors [merge]: no drop, no log
  /// (the cubit applies the refill and records the [ChainEvent]).
  ///
  /// [comboMultiplierFn] overrides the default [comboMultiplier] for challenge
  /// rules (e.g. [comboRushMultiplier] for the Combo Rush rule).
  static BoardState collapseChain(
    BoardState s,
    List<int> path, {
    int Function(int)? comboMultiplierFn,
  }) {
    final endIdx = path.last;
    final endTile = s.cells[endIdx]!;
    final mergedTier = endTile.tier;
    final newTier = mergedTier + 1;
    var ascendTotal = 0;
    for (var i = 1; i < path.length; i++) {
      final prevTier = s.cells[path[i - 1]]!.tier;
      final curTier = s.cells[path[i]]!.tier;
      if (curTier == prevTier + 1) {
        ascendTotal += ascendBonus(curTier);
      }
    }
    final cells = List<Tile?>.of(s.cells);
    for (final idx in path) {
      cells[idx] = null;
    }
    cells[endIdx] = Tile(id: endTile.id, tier: newTier);
    final fn = comboMultiplierFn ?? comboMultiplier;
    return s.copyWith(
      cells: cells,
      score: s.score + (1 << (mergedTier + 1)) * fn(path.length) + ascendTotal,
      movesRemaining: s.movesRemaining - 1,
      movesMade: s.movesMade + 1,
    );
  }
}
