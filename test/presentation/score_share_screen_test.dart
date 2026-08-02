import 'dart:async';

import 'package:flutter/foundation.dart';
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
  String? facebookText;
  String? sheetText;

  @override
  Future<bool> shareToFacebook(Uint8List pngBytes, {String? text}) async {
    fbCalls++;
    facebookText = text;
    return facebookSucceeds;
  }

  @override
  Future<void> shareToSheet(Uint8List pngBytes, {String? text}) async {
    sheetCalls++;
    sheetText = text;
  }
}

void main() {
  testWidgets('shows the core stats', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ScoreShareScreen(
        adBusy: ValueNotifier(false),
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
        adBusy: ValueNotifier(false),
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
        adBusy: ValueNotifier(false),
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
        adBusy: ValueNotifier(false),
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
        adBusy: ValueNotifier(false),
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

  testWidgets('image share sends the invite caption through both seams',
      (tester) async {
    final sharer = _FakeSharer(false);
    await tester.pumpWidget(MaterialApp(
      home: ScoreShareScreen(
        adBusy: ValueNotifier(false),
        board: _board(),
        date: '2026-06-06',
        stats: _stats,
        canOfferAd: false,
        onWatchAd: () {},
        friendCode: 'ABCD2345',
        sharer: sharer,
        captureOverride: () async => Uint8List.fromList([1, 2, 3]),
      ),
    ));

    final shareButton = find.byKey(const Key('share-card-button'));
    await tester.ensureVisible(shareButton);
    await tester.tap(shareButton);
    await tester.pumpAndSettle();

    expect(sharer.facebookText, contains('ABCD2345'));
    expect(
      sharer.facebookText,
      contains('https://www.connectmerge.app/invite/ABCD2345'),
    );
    expect(sharer.sheetText, sharer.facebookText);
  });

  testWidgets('falls back to a TEXT share when the card render fails',
      (tester) async {
    final sharer = _FakeSharer(true);
    String? shared;
    await tester.pumpWidget(MaterialApp(
      home: ScoreShareScreen(
        adBusy: ValueNotifier(false),
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

  testWidgets('awaits a fresh friend code and rebuilt frame before capture',
      (tester) async {
    final code = Completer<String>();
    final sharer = _FakeSharer(true);
    var captureCalls = 0;
    await tester.pumpWidget(MaterialApp(
      home: ScoreShareScreen(
        adBusy: ValueNotifier(false),
        board: _board(),
        date: '2026-06-06',
        stats: _stats,
        canOfferAd: false,
        onWatchAd: () {},
        ensureFriendCode: () => code.future,
        sharer: sharer,
        captureOverride: () async {
          captureCalls++;
          return Uint8List.fromList([1, 2, 3]);
        },
      ),
    ));

    await tester.tap(find.byKey(const Key('share-card-button')));
    await tester.pump();
    expect(captureCalls, 0);

    code.complete('ABCD2345');
    await tester.pumpAndSettle();

    expect(find.text('ABCD2345'), findsOneWidget);
    expect(captureCalls, 1);
    expect(sharer.fbCalls, 1);
  });

  testWidgets('render-failure fallback carries the share-time code and link',
      (tester) async {
    String? shared;
    await tester.pumpWidget(MaterialApp(
      home: ScoreShareScreen(
        adBusy: ValueNotifier(false),
        board: _board(),
        date: '2026-06-06',
        stats: _stats,
        canOfferAd: false,
        onWatchAd: () {},
        ensureFriendCode: () async => 'ABCD2345',
        captureOverride: () async => null,
        shareText: (text) async => shared = text,
      ),
    ));

    await tester.tap(find.byKey(const Key('share-card-button')));
    await tester.pumpAndSettle();

    expect(shared, contains('ABCD2345'));
    expect(
      shared,
      contains('https://www.connectmerge.app/invite/ABCD2345'),
    );
  });
}
