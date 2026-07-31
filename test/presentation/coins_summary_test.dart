import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/domain/models/tile.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:connect_merge/presentation/screens/score_share_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'coins summary shows winnings + total and doubles reactively on reward',
      (tester) async {
    final coinsWon = ValueNotifier<int>(30);
    addTearDown(coinsWon.dispose);

    await tester.pumpWidget(MaterialApp(
      home: ScoreShareScreen(
        board: _outOfMovesBoard(),
        date: '2026-07-02',
        stats: LifetimeStats.empty,
        canOfferAd: false,
        onWatchAd: () {},
        adBusy: ValueNotifier(false),
        coinsEarned: 30,
        coinsWon: coinsWon,
        // Model the reward: double the winnings.
        onDoubleCoins: () => coinsWon.value = 60,
      ),
    ));

    // Before the reward: "+30" winnings and the double button.
    expect(find.text('Won: +30 coins'), findsOneWidget);
    expect(find.byKey(const Key('double-coins-button')), findsOneWidget);

    // Take the reward.
    await tester.ensureVisible(find.byKey(const Key('double-coins-button')));
    await tester.tap(find.byKey(const Key('double-coins-button')));
    await tester.pumpAndSettle();

    // Winnings flip to "+60" and the button is gone.
    expect(find.text('Won: +60 coins'), findsOneWidget);
    expect(find.byKey(const Key('double-coins-button')), findsNothing);
  });
}

BoardState _outOfMovesBoard() {
  final cells = List<Tile?>.filled(kCellCount, null);
  cells[0] = const Tile(id: 1, tier: 1);
  cells[1] = const Tile(id: 2, tier: 1);
  return BoardState(
    cells: cells,
    movesRemaining: 0,
    score: 100,
    nextTileId: 3,
    dropIndex: 0,
    adContinuesUsed: 0,
    movesMade: 1,
    status: GameStatus.outOfMoves,
  );
}
