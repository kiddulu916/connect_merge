import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/engine/game_engine.dart';
import 'package:connect_merge/domain/engine/prng.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/domain/models/tile.dart';

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

BoardState smallBoard(List<Tile?> cells, {int dropIndex = 0}) => BoardState(
      cells: cells,
      movesRemaining: kMovesPerDay,
      score: 0,
      nextTileId: 100,
      dropIndex: dropIndex,
      adContinuesUsed: 0,
      movesMade: 0,
      status: GameStatus.playing,
      gridSize: 2,
    );

void main() {
  test('canFollow: accepts equal/ascend and rejects descend/skip', () {
    expect(GameEngine.canFollow(3, 3), isTrue);
    expect(GameEngine.canFollow(3, 4), isTrue);
    expect(GameEngine.canFollow(3, 2), isFalse);
    expect(GameEngine.canFollow(3, 5), isFalse);
  });

  test('canMerge: same tier or ascend-by-1 into a higher-tier destination, below max tier', () {
    final b = boardWith({
      0: const Tile(id: 1, tier: 3),
      1: const Tile(id: 2, tier: 3),
      2: const Tile(id: 3, tier: 4),
      3: const Tile(id: 4, tier: kMaxTier),
      4: const Tile(id: 5, tier: kMaxTier),
      5: const Tile(id: 6, tier: 6),
    });
    expect(GameEngine.canMerge(b, 0, 1), isTrue); // same tier
    expect(GameEngine.canMerge(b, 0, 2), isTrue); // ascend by 1 (3 -> 4)
    expect(GameEngine.canMerge(b, 2, 0), isFalse); // descend (4 -> 3)
    expect(GameEngine.canMerge(b, 0, 5), isFalse); // skips a tier (3 -> 6)
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

  group('refill', () {
    test('fills to target when a merge already exists', () {
      final board = smallBoard([
        const Tile(id: 1, tier: 1),
        const Tile(id: 2, tier: 1),
        null,
        null,
      ]);
      final result = GameEngine.refill(
        board,
        targetFill: 3,
        tierAt: (_) => 4,
        landing: Prng(1),
      );
      expect(result.filledCount, 3);
      expect(result.dropIndex, 1);
    });

    test('tops up beyond target until full when no merge appears', () {
      final board = smallBoard([
        const Tile(id: 1, tier: 1),
        const Tile(id: 2, tier: 3),
        const Tile(id: 3, tier: 3),
        null,
      ]);
      final result = GameEngine.refill(
        board,
        targetFill: 3,
        tierAt: (_) => 5,
        landing: Prng(1),
      );
      expect(result.filledCount, 4);
      expect(result.dropIndex, 1);
      expect(GameEngine.hasMergeAvailable(result), isFalse);
    });

    test('stops without reading tierAt when the board is full', () {
      var reads = 0;
      final board = smallBoard([
        const Tile(id: 1, tier: 1),
        const Tile(id: 2, tier: 3),
        const Tile(id: 3, tier: 3),
        const Tile(id: 4, tier: 1),
      ]);
      final result = GameEngine.refill(
        board,
        targetFill: 4,
        tierAt: (_) {
          reads++;
          return 1;
        },
        landing: Prng(1),
      );
      expect(result, same(board));
      expect(reads, 0);
    });

    test('reads the current dropIndex once per applied drop', () {
      final reads = <int>[];
      final board = smallBoard([
        const Tile(id: 1, tier: 1),
        const Tile(id: 2, tier: 1),
        null,
        null,
      ], dropIndex: 7);
      final result = GameEngine.refill(
        board,
        targetFill: 4,
        tierAt: (dropIndex) {
          reads.add(dropIndex);
          return 1;
        },
        landing: Prng(1),
      );
      expect(reads, [7, 8]);
      expect(result.dropIndex, 9);
    });

    test('marks only configured drop indices golden', () {
      final board = smallBoard([
        const Tile(id: 1, tier: 1),
        const Tile(id: 2, tier: 1),
        null,
        null,
      ], dropIndex: 7);
      final result = GameEngine.refill(
        board,
        targetFill: 4,
        tierAt: (_) => 1,
        landing: Prng(1),
        goldenDrops: const {8},
      );
      expect(result.cells.singleWhere((tile) => tile?.id == 100)!.golden,
          isFalse);
      expect(result.cells.singleWhere((tile) => tile?.id == 101)!.golden,
          isTrue);
    });
  });

  test('hasMergeAvailable: needs ADJACENT equal tiers, not just any pair', () {
    // Two tier-1 tiles exist but are NOT orthogonally adjacent => deadlock.
    final apart = boardWith({
      0: const Tile(id: 1, tier: 1),
      2: const Tile(id: 2, tier: 1), // same row, gap at index 1
      8: const Tile(id: 3, tier: 3),
    });
    expect(GameEngine.hasMergeAvailable(apart), isFalse);
    expect(GameEngine.evaluateStatus(apart).status, GameStatus.deadlocked);

    // Make them adjacent => a merge is available again.
    final together = boardWith({
      0: const Tile(id: 1, tier: 1),
      1: const Tile(id: 2, tier: 1),
    });
    expect(GameEngine.hasMergeAvailable(together), isTrue);
    expect(GameEngine.evaluateStatus(together).status, GameStatus.playing);
  });

  test('hasMergeAvailable: also finds an ascend-adjacent pair (differs by exactly 1 tier)', () {
    final b = boardWith({
      0: const Tile(id: 1, tier: 2),
      1: const Tile(id: 2, tier: 3), // east neighbour, one tier higher
    });
    expect(GameEngine.hasMergeAvailable(b), isTrue);
    expect(GameEngine.evaluateStatus(b).status, GameStatus.playing);
  });

  test('hasMergeAvailable: does NOT treat a 2-tier gap as available', () {
    final b = boardWith({
      0: const Tile(id: 1, tier: 2),
      1: const Tile(id: 2, tier: 4), // east neighbour, two tiers higher
    });
    expect(GameEngine.hasMergeAvailable(b), isFalse);
    expect(GameEngine.evaluateStatus(b).status, GameStatus.deadlocked);
  });

  test('hasMergeAvailable: an ascend pair sitting at the cap is NOT available', () {
    final b = boardWith({
      0: const Tile(id: 1, tier: kMaxTier - 1),
      1: const Tile(id: 2, tier: kMaxTier),
    });
    expect(GameEngine.hasMergeAvailable(b), isFalse);
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
      expect(GameEngine.areOrthogonallyAdjacent(0, 1, 5), isTrue);          // E
      expect(GameEngine.areOrthogonallyAdjacent(0, kGridSize, 5), isTrue);  // S
      expect(GameEngine.areOrthogonallyAdjacent(0, kGridSize + 1, 5), isFalse); // diag
      expect(GameEngine.areOrthogonallyAdjacent(4, 5, 5), isFalse);        // row wrap
    });

    test('isValidChain: accepts a connected same-tier run', () {
      final b = boardWith({
        0: const Tile(id: 1, tier: 2),
        1: const Tile(id: 2, tier: 2),
        6: const Tile(id: 3, tier: 2), // index 6 = row1,col1, adjacent to 1
      });
      expect(GameEngine.isValidChain(b, [0, 1, 6]), isTrue);
    });

    test('isValidChain: rejects length<2, non-adjacent, repeats, empty cells', () {
      final b = boardWith({
        0: const Tile(id: 1, tier: 2),
        1: const Tile(id: 2, tier: 2),
        6: const Tile(id: 4, tier: 2),
      });
      expect(GameEngine.isValidChain(b, [0]), isFalse); // too short
      expect(GameEngine.isValidChain(b, [0, 6]), isFalse); // not adjacent
      expect(GameEngine.isValidChain(b, [0, 1, 0]), isFalse); // repeat
      final empty = boardWith({0: const Tile(id: 1, tier: 2)});
      expect(GameEngine.isValidChain(empty, [0, 1]), isFalse); // cell 1 empty
    });

    test('isValidChain: accepts an ascend-by-1 step, rejects descend and skip', () {
      final b = boardWith({
        0: const Tile(id: 1, tier: 2),
        1: const Tile(id: 2, tier: 3), // east of 0, one tier higher
        2: const Tile(id: 3, tier: 5), // east of 1, skips a tier
      });
      expect(GameEngine.isValidChain(b, [0, 1]), isTrue); // ascend by 1
      expect(GameEngine.isValidChain(b, [1, 0]), isFalse); // descend (3 -> 2)
      expect(GameEngine.isValidChain(b, [1, 2]), isFalse); // skip (3 -> 5)
    });

    test('isValidChain: accepts a run-then-ascend-then-run chain', () {
      // tier1 run (0,1,6) -> ascend -> tier2 run (7,8) -> ascend -> tier3 peak (13)
      final b = boardWith({
        0: const Tile(id: 1, tier: 1),
        1: const Tile(id: 2, tier: 1),
        6: const Tile(id: 3, tier: 1),
        7: const Tile(id: 4, tier: 2),
        8: const Tile(id: 5, tier: 2),
        13: const Tile(id: 6, tier: 3),
      });
      expect(GameEngine.isValidChain(b, [0, 1, 6, 7, 8, 13]), isTrue);
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

    test('isValidChain: rejects an ascend chain whose peak sits at max tier', () {
      final b = boardWith({
        0: const Tile(id: 1, tier: kMaxTier - 1),
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

    test('collapse: ascending chain scores base combo PLUS an ascend bonus per transition', () {
      final b = boardWith({
        0: const Tile(id: 10, tier: 1),
        1: const Tile(id: 11, tier: 1),
        6: const Tile(id: 12, tier: 2), // ascend into tier 2
        7: const Tile(id: 13, tier: 2),
        8: const Tile(id: 14, tier: 3), // ascend into tier 3 (endpoint)
      });
      final r = GameEngine.collapseChain(b, [0, 1, 6, 7, 8]);
      expect(r.cells[8]!.tier, 4); // peak tier 3 + 1
      final expectedBase = GameEngine.comboScore(3, 5);
      final expectedAscend = ascendBonus(2) + ascendBonus(3);
      expect(r.score, expectedBase + expectedAscend);
    });

    test('collapse: a flat (same-tier) chain has zero ascend bonus', () {
      final b = boardWith({
        0: const Tile(id: 10, tier: 2),
        1: const Tile(id: 11, tier: 2),
      });
      final r = GameEngine.collapseChain(b, [0, 1]);
      expect(r.score, GameEngine.comboScore(2, 2));
    });
  });
}
