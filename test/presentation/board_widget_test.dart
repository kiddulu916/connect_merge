import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/domain/models/tile.dart';
import 'package:connect_merge/presentation/widgets/board_widget.dart';

void main() {
  testWidgets('renders tiles on the board', (tester) async {
    final cells = List<Tile?>.filled(kCellCount, null);
    cells[0] = const Tile(id: 1, tier: 2);
    cells[1] = const Tile(id: 2, tier: 2);
    final board = BoardState(
      cells: cells,
      movesRemaining: 30,
      score: 0,
      nextTileId: 3,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 0,
      status: GameStatus.playing,
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BoardWidget(
          board: board,
          onChain: (_) {},
        ),
      ),
    ));

    // Tier 2 tiles display as "4" (2^2).
    expect(find.text('4'), findsNWidgets(2));
  });

  testWidgets('dragging across two adjacent equal tiles reports a 2-path',
      (tester) async {
    final cells = List<Tile?>.filled(kCellCount, null);
    cells[0] = const Tile(id: 1, tier: 2);
    cells[1] = const Tile(id: 2, tier: 2); // east neighbour, same tier
    final board = BoardState(
      cells: cells,
      movesRemaining: 30,
      score: 0,
      nextTileId: 3,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 0,
      status: GameStatus.playing,
    );

    List<int>? reported;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 350,
            height: 350,
            child: BoardWidget(board: board, onChain: (p) => reported = p),
          ),
        ),
      ),
    ));

    // Drag from the center of cell 0 to the center of cell 1.
    final box = tester.getRect(find.byType(BoardWidget));
    const gap = 8.0;
    final cell = (box.width - gap * (kGridSize + 1)) / kGridSize;
    Offset centerOf(int i) {
      final row = i ~/ kGridSize, col = i % kGridSize;
      return box.topLeft +
          Offset(gap + col * (cell + gap) + cell / 2,
              gap + row * (cell + gap) + cell / 2);
    }

    final g = await tester.startGesture(centerOf(0));
    await tester.pump();
    await g.moveTo(centerOf(1));
    await tester.pump();
    await g.up();
    await tester.pump();

    expect(reported, [0, 1]);
  });

  testWidgets('dragging from a lower tier onto an adjacent higher tier extends the path (ascend)',
      (tester) async {
    final cells = List<Tile?>.filled(kCellCount, null);
    cells[0] = const Tile(id: 1, tier: 2);
    cells[1] = const Tile(id: 2, tier: 3); // east neighbour, one tier higher
    final board = BoardState(
      cells: cells,
      movesRemaining: 30,
      score: 0,
      nextTileId: 3,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 0,
      status: GameStatus.playing,
    );

    List<int>? reported;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 350,
            height: 350,
            child: BoardWidget(board: board, onChain: (p) => reported = p),
          ),
        ),
      ),
    ));

    final box = tester.getRect(find.byType(BoardWidget));
    const gap = 8.0;
    final cell = (box.width - gap * (kGridSize + 1)) / kGridSize;
    Offset centerOf(int i) {
      final row = i ~/ kGridSize, col = i % kGridSize;
      return box.topLeft +
          Offset(gap + col * (cell + gap) + cell / 2,
              gap + row * (cell + gap) + cell / 2);
    }

    final g = await tester.startGesture(centerOf(0));
    await tester.pump();
    await g.moveTo(centerOf(1));
    await tester.pump();
    await g.up();
    await tester.pump();

    expect(reported, [0, 1]);
  });

  testWidgets('dragging from a higher tier onto an adjacent lower tier does NOT extend (descend)',
      (tester) async {
    final cells = List<Tile?>.filled(kCellCount, null);
    cells[0] = const Tile(id: 1, tier: 3);
    cells[1] = const Tile(id: 2, tier: 2); // east neighbour, one tier lower
    final board = BoardState(
      cells: cells,
      movesRemaining: 30,
      score: 0,
      nextTileId: 3,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 0,
      status: GameStatus.playing,
    );

    List<int>? reported;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 350,
            height: 350,
            child: BoardWidget(board: board, onChain: (p) => reported = p),
          ),
        ),
      ),
    ));

    final box = tester.getRect(find.byType(BoardWidget));
    const gap = 8.0;
    final cell = (box.width - gap * (kGridSize + 1)) / kGridSize;
    Offset centerOf(int i) {
      final row = i ~/ kGridSize, col = i % kGridSize;
      return box.topLeft +
          Offset(gap + col * (cell + gap) + cell / 2,
              gap + row * (cell + gap) + cell / 2);
    }

    final g = await tester.startGesture(centerOf(0));
    await tester.pump();
    await g.moveTo(centerOf(1));
    await tester.pump();
    await g.up();
    await tester.pump();

    // The drag never extended past the start cell, so a lone-cell path never
    // fires onChain (BoardWidget._onEnd requires length >= 2).
    expect(reported, isNull);
  });
}
