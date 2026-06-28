import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/domain/models/tile.dart';
import 'package:connect_merge/infrastructure/score_sharer.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:connect_merge/presentation/screens/score_share_screen.dart';

BoardState _board() {
  final cells = List<Tile?>.filled(kCellCount, null);
  cells[0] = const Tile(id: 1, tier: 6);
  return BoardState(
    cells: cells,
    movesRemaining: 0,
    score: 1234,
    nextTileId: 2,
    dropIndex: 0,
    adContinuesUsed: 0,
    movesMade: 30,
    status: GameStatus.outOfMoves,
  );
}

const _stats = LifetimeStats(
    streak: 4, lastCompletedDate: '2026-06-06', bestScore: 5000, bestTier: 9);

class _FakeSharer implements ScoreSharer {
  _FakeSharer(this.facebookSucceeds);
  final bool facebookSucceeds;
  int fbCalls = 0;
  int sheetCalls = 0;

  @override
  Future<bool> shareToFacebook(Uint8List pngBytes) async {
    fbCalls++;
    return facebookSucceeds;
  }

  @override
  Future<void> shareToSheet(Uint8List pngBytes) async {
    sheetCalls++;
  }
}

void main() {
  testWidgets('shows the core stats', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ScoreShareScreen(
        board: _board(),
        date: '2026-06-06',
        stats: _stats,
        canOfferAd: false,
        onWatchAd: () {},
      ),
    ));
    expect(find.text('1234'), findsWidgets); // score
    expect(find.textContaining('4'), findsWidgets); // streak
  });

  testWidgets('Main Menu button invokes onMainMenu', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(MaterialApp(
      home: ScoreShareScreen(
        board: _board(),
        date: '2026-06-06',
        stats: _stats,
        canOfferAd: false,
        onWatchAd: () {},
        onMainMenu: () => tapped++,
      ),
    ));

    expect(find.byKey(const Key('main-menu-button')), findsOneWidget);
    // The richer share card makes the result content scrollable; bring the
    // button into view before tapping it.
    await tester.ensureVisible(find.byKey(const Key('main-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('main-menu-button')));
    await tester.pump();
    expect(tapped, 1);
  });

  testWidgets('Main Menu button is hidden when no callback given',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ScoreShareScreen(
        board: _board(),
        date: '2026-06-06',
        stats: _stats,
        canOfferAd: false,
        onWatchAd: () {},
      ),
    ));
    expect(find.byKey(const Key('main-menu-button')), findsNothing);
  });

  testWidgets('Share sends the screenshot to Facebook', (tester) async {
    final sharer = _FakeSharer(true);
    await tester.pumpWidget(MaterialApp(
      home: ScoreShareScreen(
        board: _board(),
        date: '2026-06-06',
        stats: _stats,
        canOfferAd: false,
        onWatchAd: () {},
        sharer: sharer,
        captureOverride: () async => Uint8List.fromList([1, 2, 3]),
      ),
    ));

    await tester.tap(find.byKey(const Key('share-card-button')));
    await tester.pumpAndSettle();

    expect(sharer.fbCalls, 1);
    expect(sharer.sheetCalls, 0);
  });

  testWidgets('Share falls back to the OS sheet when Facebook is absent',
      (tester) async {
    final sharer = _FakeSharer(false);
    await tester.pumpWidget(MaterialApp(
      home: ScoreShareScreen(
        board: _board(),
        date: '2026-06-06',
        stats: _stats,
        canOfferAd: false,
        onWatchAd: () {},
        sharer: sharer,
        captureOverride: () async => Uint8List.fromList([1, 2, 3]),
      ),
    ));

    await tester.tap(find.byKey(const Key('share-card-button')));
    await tester.pumpAndSettle();

    expect(sharer.fbCalls, 1);
    expect(sharer.sheetCalls, 1);
  });

  testWidgets('falls back to a TEXT share when the card render fails',
      (tester) async {
    final sharer = _FakeSharer(true);
    String? shared;
    await tester.pumpWidget(MaterialApp(
      home: ScoreShareScreen(
        board: _board(),
        date: '2026-06-06',
        stats: _stats,
        canOfferAd: false,
        onWatchAd: () {},
        sharer: sharer,
        // Render fails -> null bytes.
        captureOverride: () async => null,
        shareText: (t) async => shared = t,
      ),
    ));

    await tester.tap(find.byKey(const Key('share-card-button')));
    await tester.pumpAndSettle();

    // No image share attempted; text fallback carried the result.
    expect(sharer.fbCalls, 0);
    expect(sharer.sheetCalls, 0);
    expect(shared, isNotNull);
    expect(shared, contains('1234'));
  });
}
