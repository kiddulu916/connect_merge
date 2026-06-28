import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/engine/share_grid_builder.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/domain/models/tile.dart';

void main() {
  test('builds header lines and a 5x5 emoji grid', () {
    final cells = List<Tile?>.filled(kCellCount, null);
    cells[0] = const Tile(id: 1, tier: 1); // low -> blue
    cells[24] = const Tile(id: 2, tier: 11); // max -> purple
    final board = BoardState(
      cells: cells,
      movesRemaining: 6,
      score: 4096,
      nextTileId: 3,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 24,
      status: GameStatus.outOfMoves,
    );

    final out = ShareGridBuilder.build(date: '2026-06-06', board: board);
    final lines = out.split('\n');

    expect(lines[0], 'Connect Merge 2026-06-06');
    expect(lines[1], contains('Score 4096'));
    expect(lines[1], contains('24 moves'));
    expect(lines.length, 2 + kGridSize); // 2 header + 5 grid rows
    expect(lines[2].startsWith('🟦'), isTrue); // cell 0 low tier
    expect(lines.last.endsWith('🟪'), isTrue); // cell 24 max tier
  });
}
