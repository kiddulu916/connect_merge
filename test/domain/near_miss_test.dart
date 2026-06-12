import 'package:flutter_test/flutter_test.dart';
import 'package:merge_count/domain/constants.dart';
import 'package:merge_count/domain/engine/near_miss.dart';
import 'package:merge_count/domain/models/board_state.dart';
import 'package:merge_count/domain/models/game_status.dart';
import 'package:merge_count/domain/models/tile.dart';

BoardState _board(List<Tile?> cells, {int score = 0}) {
  final padded = List<Tile?>.of(cells);
  while (padded.length < kCellCount) {
    padded.add(null);
  }
  return BoardState(
    cells: padded,
    movesRemaining: 0,
    score: score,
    nextTileId: 100,
    dropIndex: 0,
    adContinuesUsed: 0,
    movesMade: 0,
    status: GameStatus.outOfMoves,
  );
}

void main() {
  group('NearMiss.message', () {
    test('two equal below-cap tiles -> "1 merge from tier 2^(tier+1)"', () {
      final b = _board([
        const Tile(id: 1, tier: 8),
        const Tile(id: 2, tier: 8),
      ]);
      expect(NearMiss.message(b), '1 merge from tier ${1 << 9}!');
    });

    test('picks the HIGHEST mergeable pair when several exist', () {
      final b = _board([
        const Tile(id: 1, tier: 3),
        const Tile(id: 2, tier: 3),
        const Tile(id: 3, tier: 7),
        const Tile(id: 4, tier: 7),
      ]);
      expect(NearMiss.message(b), '1 merge from tier ${1 << 8}!');
    });

    test('max-tier pairs are ignored (cannot merge further)', () {
      final b = _board([
        const Tile(id: 1, tier: kMaxTier),
        const Tile(id: 2, tier: kMaxTier),
      ]);
      expect(NearMiss.message(b), isNull);
    });

    test('no pair + no best -> null (does not fabricate pressure)', () {
      final b = _board([
        const Tile(id: 1, tier: 2),
        const Tile(id: 2, tier: 5),
      ]);
      expect(NearMiss.message(b), isNull);
    });

    test('within the score window below a best -> "N points from your best"',
        () {
      final b = _board([
        const Tile(id: 1, tier: 2),
        const Tile(id: 2, tier: 5),
      ], score: 480);
      expect(NearMiss.message(b, bestScore: 500), '20 points from your best');
    });

    test('beyond the score window -> null', () {
      final b = _board([
        const Tile(id: 1, tier: 2),
      ], score: 100);
      expect(
          NearMiss.message(b, bestScore: 100 + kNearMissScoreWindow + 1),
          isNull);
    });

    test('already at/above best -> null', () {
      final b = _board([const Tile(id: 1, tier: 2)], score: 500);
      expect(NearMiss.message(b, bestScore: 500), isNull);
      expect(NearMiss.message(b, bestScore: 400), isNull);
    });

    test('tile-pair near-miss takes priority over the score near-miss', () {
      final b = _board([
        const Tile(id: 1, tier: 6),
        const Tile(id: 2, tier: 6),
      ], score: 490);
      expect(NearMiss.message(b, bestScore: 500), '1 merge from tier ${1 << 7}!');
    });
  });
}
