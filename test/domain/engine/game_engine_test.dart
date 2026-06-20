import 'package:flutter_test/flutter_test.dart';
import 'package:merge_count/domain/constants.dart';
import 'package:merge_count/domain/engine/game_engine.dart';
import 'package:merge_count/domain/engine/prng.dart';
import 'package:merge_count/domain/models/board_state.dart';
import 'package:merge_count/domain/models/game_status.dart';
import 'package:merge_count/domain/models/tile.dart';

BoardState boardWith(Map<int, Tile> tiles, {int moves = kMovesPerDay}) {
  final cells = List<Tile?>.filled(kCellCount, null);
  tiles.forEach((i, t) => cells[i] = t);
  return BoardState(
    cells: cells,
    movesRemaining: moves,
    score: 0,
    nextTileId: 100,
    dropIndex: 0,
    adContinuesUsed: 0,
    movesMade: 0,
    status: GameStatus.playing,
  );
}

void main() {
  test('canMerge: same tier, distinct cells, below max tier', () {
    final b = boardWith({
      0: const Tile(id: 1, tier: 3),
      1: const Tile(id: 2, tier: 3),
      2: const Tile(id: 3, tier: 4),
      3: const Tile(id: 4, tier: kMaxTier),
      4: const Tile(id: 5, tier: kMaxTier),
    });
    expect(GameEngine.canMerge(b, 0, 1), isTrue);
    expect(GameEngine.canMerge(b, 0, 2), isFalse); // different tier
    expect(GameEngine.canMerge(b, 0, 0), isFalse); // same cell
    expect(GameEngine.canMerge(b, 3, 4), isFalse); // at max tier
  });

  test('merge: destination becomes tier+1, source empties, scores 2^newTier, spends a move', () {
    final b = boardWith({
      0: const Tile(id: 1, tier: 3),
      1: const Tile(id: 2, tier: 3),
    });
    final r = GameEngine.merge(b, fromIndex: 0, toIndex: 1);
    expect(r.cells[0], isNull);
    expect(r.cells[1]!.tier, 4);
    expect(r.cells[1]!.id, 2); // destination id preserved for animation
    expect(r.score, 1 << 4); // 16
    expect(r.movesRemaining, kMovesPerDay - 1);
    expect(r.movesMade, 1);
  });

  test('applyDrop: places dropped tier at a deterministic empty cell, advances dropIndex', () {
    final b = boardWith({0: const Tile(id: 1, tier: 1)});
    final landing = Prng(42);
    final r = GameEngine.applyDrop(b, 2, landing);
    expect(r.filledCount, 2);
    expect(r.dropIndex, 1);
    final dropped = r.cells.firstWhere((c) => c != null && c.id == 100);
    expect(dropped!.tier, 2);
  });

  test('hasMergeAvailable: false when all tiers unique => deadlock', () {
    final dead = boardWith({
      0: const Tile(id: 1, tier: 1),
      1: const Tile(id: 2, tier: 2),
      2: const Tile(id: 3, tier: 3),
    });
    expect(GameEngine.hasMergeAvailable(dead), isFalse);
    expect(GameEngine.evaluateStatus(dead).status, GameStatus.deadlocked);
  });

  test('evaluateStatus: zero moves => outOfMoves even if a merge exists', () {
    final b = boardWith({
      0: const Tile(id: 1, tier: 1),
      1: const Tile(id: 2, tier: 1),
    }, moves: 0);
    expect(GameEngine.evaluateStatus(b).status, GameStatus.outOfMoves);
  });

  group('golden tiles (Phase 1) — economy only, never scoring', () {
    test('applyDrop stamps golden only when requested', () {
      final b = boardWith({0: const Tile(id: 1, tier: 3)});
      final plain = GameEngine.applyDrop(b, 2, Prng(7));
      final gold = GameEngine.applyDrop(b, 2, Prng(7), golden: true);
      // Same landing draw (same seed) => same landed cell index.
      final plainCell = plain.cells.indexWhere((c) => c?.id == b.nextTileId);
      final goldCell = gold.cells.indexWhere((c) => c?.id == b.nextTileId);
      expect(goldCell, plainCell);
      expect(plain.cells[plainCell]!.golden, isFalse);
      expect(gold.cells[goldCell]!.golden, isTrue);
    });

    test('goldenBonusFor pays per golden tile consumed', () {
      final none = boardWith({
        0: const Tile(id: 1, tier: 2),
        1: const Tile(id: 2, tier: 2),
      });
      expect(GameEngine.goldenBonusFor(none, 0, 1), 0);

      final one = boardWith({
        0: const Tile(id: 1, tier: 2, golden: true),
        1: const Tile(id: 2, tier: 2),
      });
      expect(GameEngine.goldenBonusFor(one, 0, 1), kGoldenMergeBonus);

      final both = boardWith({
        0: const Tile(id: 1, tier: 2, golden: true),
        1: const Tile(id: 2, tier: 2, golden: true),
      });
      expect(GameEngine.goldenBonusFor(both, 0, 1), 2 * kGoldenMergeBonus);
    });

    test('merging golden tiles yields the SAME score as a non-golden control',
        () {
      final golden = boardWith({
        0: const Tile(id: 1, tier: 4, golden: true),
        1: const Tile(id: 2, tier: 4, golden: true),
      });
      final control = boardWith({
        0: const Tile(id: 1, tier: 4),
        1: const Tile(id: 2, tier: 4),
      });
      final gMerged = GameEngine.merge(golden, fromIndex: 0, toIndex: 1);
      final cMerged = GameEngine.merge(control, fromIndex: 0, toIndex: 1);
      expect(gMerged.score, cMerged.score);
      expect(gMerged.moveLog, cMerged.moveLog);
      // The merged tile is no longer golden (the flag is consumed, not carried).
      expect(gMerged.cells[1]!.golden, isFalse);
    });
  });

  group('Connect-Merge path validation', () {
    test('areOrthogonallyAdjacent: true for N/S/E/W, false for diagonal/wrap', () {
      expect(GameEngine.areOrthogonallyAdjacent(0, 1), isTrue); // E
      expect(GameEngine.areOrthogonallyAdjacent(0, kGridSize), isTrue); // S
      expect(GameEngine.areOrthogonallyAdjacent(0, kGridSize + 1), isFalse); // diag
      expect(GameEngine.areOrthogonallyAdjacent(4, 5), isFalse); // row wrap (col4->col0)
    });

    test('isValidChain: accepts a connected same-tier run', () {
      final b = boardWith({
        0: const Tile(id: 1, tier: 2),
        1: const Tile(id: 2, tier: 2),
        6: const Tile(id: 3, tier: 2), // index 6 = row1,col1, adjacent to 1
      });
      expect(GameEngine.isValidChain(b, [0, 1, 6]), isTrue);
    });

    test('isValidChain: rejects length<2, mixed tier, gaps, repeats, walls', () {
      final b = boardWith({
        0: const Tile(id: 1, tier: 2),
        1: const Tile(id: 2, tier: 2),
        2: const Tile(id: 3, tier: 3), // different tier
        6: const Tile(id: 4, tier: 2),
      });
      expect(GameEngine.isValidChain(b, [0]), isFalse); // too short
      expect(GameEngine.isValidChain(b, [0, 2]), isFalse); // tier mismatch
      expect(GameEngine.isValidChain(b, [0, 6]), isFalse); // not adjacent
      expect(GameEngine.isValidChain(b, [0, 1, 0]), isFalse); // repeat
      final empty = boardWith({0: const Tile(id: 1, tier: 2)});
      expect(GameEngine.isValidChain(empty, [0, 1]), isFalse); // cell 1 empty
    });

    test('isValidChain: rejects a path stepping onto a wall', () {
      final cells = List<Tile?>.filled(kCellCount, null);
      cells[0] = const Tile(id: 1, tier: 2);
      cells[1] = const Tile(id: 2, tier: 2);
      final b = BoardState(
        cells: cells,
        movesRemaining: 30,
        score: 0,
        nextTileId: 3,
        dropIndex: 0,
        adContinuesUsed: 0,
        movesMade: 0,
        status: GameStatus.playing,
        walls: const {1},
      );
      expect(GameEngine.isValidChain(b, [0, 1]), isFalse);
    });

    test('isValidChain: rejects a chain at max tier', () {
      final b = boardWith({
        0: const Tile(id: 1, tier: kMaxTier),
        1: const Tile(id: 2, tier: kMaxTier),
      });
      expect(GameEngine.isValidChain(b, [0, 1]), isFalse);
    });
  });

  group('Connect-Merge scoring', () {
    test('comboScore: 2-chain equals the legacy single-merge score', () {
      // legacy merge of two tier-3 tiles scored 1 << 4 = 16
      expect(GameEngine.comboScore(3, 2), 1 << 4);
    });

    test('comboScore: longer chains apply the superlinear multiplier', () {
      // tier 2 -> result value 8; multipliers 1,2,4,7,11
      expect(GameEngine.comboScore(2, 2), 8);
      expect(GameEngine.comboScore(2, 3), 16);
      expect(GameEngine.comboScore(2, 4), 32);
      expect(GameEngine.comboScore(2, 5), 56);
      expect(GameEngine.comboScore(2, 6), 88);
    });
  });

  group('Connect-Merge collapse', () {
    test('collapse: endpoint climbs +1 keeping its id; others empty; scores combo', () {
      final b = boardWith({
        0: const Tile(id: 10, tier: 2),
        1: const Tile(id: 11, tier: 2),
        6: const Tile(id: 12, tier: 2), // endpoint
      });
      final r = GameEngine.collapseChain(b, [0, 1, 6]);
      expect(r.cells[0], isNull);
      expect(r.cells[1], isNull);
      expect(r.cells[6]!.tier, 3);
      expect(r.cells[6]!.id, 12); // endpoint id preserved for animation
      expect(r.score, GameEngine.comboScore(2, 3)); // 16
      expect(r.movesRemaining, kMovesPerDay - 1);
      expect(r.movesMade, 1);
      expect(r.filledCount, 1); // only the endpoint remains
    });

    test('collapse: a 2-path matches the legacy merge result', () {
      final b = boardWith({
        0: const Tile(id: 1, tier: 3),
        1: const Tile(id: 2, tier: 3),
      });
      final chain = GameEngine.collapseChain(b, [0, 1]);
      final legacy = GameEngine.merge(b, fromIndex: 0, toIndex: 1);
      expect(chain.cells[1]!.tier, legacy.cells[1]!.tier);
      expect(chain.cells[1]!.id, legacy.cells[1]!.id);
      expect(chain.score, legacy.score);
      expect(chain.movesRemaining, legacy.movesRemaining);
    });
  });
}
