import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/domain/models/tile.dart';
import 'package:connect_merge/infrastructure/share_card_renderer.dart';
import 'package:connect_merge/presentation/widgets/share_card.dart';

BoardState _board(List<Tile?> cells, {int score = 1234}) => BoardState(
      cells: cells,
      movesRemaining: 0,
      score: score,
      nextTileId: 99,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 30,
      status: GameStatus.outOfMoves,
    );

Future<void> _pumpCard(WidgetTester tester, ShareCard card) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      backgroundColor: const Color(0xFF12141C),
      body: Center(child: card),
    ),
  ));
}

void main() {
  group('ShareCard extreme layouts (no overflow / clipping)', () {
    testWidgets('all-empty board renders without overflow', (tester) async {
      final empty = List<Tile?>.filled(kCellCount, null);
      await _pumpCard(
        tester,
        ShareCard(
          board: _board(empty, score: 0),
          difficulty: Difficulty.easy,
          score: 0,
          highestTier: 0,
          streak: 0,
          level: 0,
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('share-card')), findsOneWidget);
      expect(find.byKey(const Key('share-card-score')), findsOneWidget);
    });

    testWidgets('jackpot board (every cell a high tile) fits', (tester) async {
      final full = List<Tile?>.generate(
          kCellCount, (i) => Tile(id: i, tier: kMaxTier));
      await _pumpCard(
        tester,
        ShareCard(
          board: _board(full, score: 999999),
          difficulty: Difficulty.legendary,
          score: 999999,
          highestTier: kMaxTier,
          streak: 365,
          level: 99,
          rank: 1,
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('share-card-score')), findsOneWidget);
    });

    testWidgets('long display name ellipsizes (no overflow)', (tester) async {
      final cells = List<Tile?>.filled(kCellCount, null);
      cells[0] = const Tile(id: 1, tier: 6);
      await _pumpCard(
        tester,
        ShareCard(
          board: _board(cells),
          difficulty: Difficulty.hard,
          score: 1234,
          highestTier: 6,
          streak: 4,
          level: 12,
          displayName:
              'A really absurdly long display name that should ellipsize 🎮🦊🚀',
          rank: 42,
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('share-card-name')), findsOneWidget);
    });
  });

  group('ShareCardRenderer seam', () {
    testWidgets('FakeShareCardRenderer returns canned bytes', (tester) async {
      final fake = FakeShareCardRenderer(
          Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]));
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      ));
      final bytes = await fake.capture(ctx);
      expect(bytes, isNotNull);
      expect(bytes!.length, 4);
    });

    testWidgets('FakeShareCardRenderer(null) signals a failed capture so the '
        'caller can fall back', (tester) async {
      const fake = FakeShareCardRenderer(null);
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      ));
      expect(await fake.capture(ctx), isNull);
    });

    testWidgets('production renderer returns null when context is not a '
        'RepaintBoundary (graceful, no throw)', (tester) async {
      const renderer = RepaintBoundaryShareCardRenderer();
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      ));
      // The Builder's context render object is not a RepaintBoundary.
      expect(await renderer.capture(ctx), isNull);
    });
  });
}
