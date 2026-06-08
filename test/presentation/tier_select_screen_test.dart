import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_loop/domain/constants.dart';
import 'package:merge_loop/domain/models/board_state.dart';
import 'package:merge_loop/domain/models/difficulty.dart';
import 'package:merge_loop/domain/models/game_status.dart';
import 'package:merge_loop/domain/models/tile.dart';
import 'package:merge_loop/infrastructure/ad_service.dart';
import 'package:merge_loop/infrastructure/storage_service.dart';
import 'package:merge_loop/presentation/screens/tier_select_screen.dart';

void main() {
  testWidgets('renders all four tiers with their tile counts', (tester) async {
    final storage = InMemoryStorageService();
    await tester.pumpWidget(MaterialApp(
      home: TierSelectScreen(
        storage: storage,
        adService: AdService(),
        todayProvider: () => '2026-06-07',
        onTierSelected: (_, __) {},
      ),
    ));

    for (final d in Difficulty.values) {
      expect(find.byKey(Key('tier-${d.name}')), findsOneWidget);
      expect(find.text(d.label), findsOneWidget);
      expect(find.text('${d.startingFill} starting tiles'), findsOneWidget);
    }
  });

  testWidgets('tapping a tier reports the chosen difficulty', (tester) async {
    final storage = InMemoryStorageService();
    Difficulty? chosen;
    await tester.pumpWidget(MaterialApp(
      home: TierSelectScreen(
        storage: storage,
        adService: AdService(),
        todayProvider: () => '2026-06-07',
        onTierSelected: (_, d) => chosen = d,
      ),
    ));

    await tester.tap(find.byKey(const Key('tier-hard')));
    await tester.pump();
    expect(chosen, Difficulty.hard);
  });

  testWidgets('a completed tier shows "Done today" and is not tappable',
      (tester) async {
    final storage = InMemoryStorageService();
    // Mark easy as completed today.
    await storage.saveSnapshot(GameSnapshot(
      date: '2026-06-07',
      difficulty: Difficulty.easy,
      board: _completedBoard(),
      completed: true,
    ));

    final tapped = <Difficulty>[];
    await tester.pumpWidget(MaterialApp(
      home: TierSelectScreen(
        storage: storage,
        adService: AdService(),
        todayProvider: () => '2026-06-07',
        onTierSelected: (_, d) => tapped.add(d),
      ),
    ));

    expect(find.text('Done today ✓'), findsOneWidget);

    // Tapping the completed easy tier does nothing (onTap is null).
    await tester.tap(find.byKey(const Key('tier-easy')));
    await tester.pump();
    expect(tapped, isEmpty);

    // Other tiers still route.
    await tester.tap(find.byKey(const Key('tier-medium')));
    await tester.pump();
    expect(tapped, [Difficulty.medium]);
  });

  testWidgets('shows a UTC reset countdown', (tester) async {
    final storage = InMemoryStorageService();
    await tester.pumpWidget(MaterialApp(
      home: TierSelectScreen(
        storage: storage,
        adService: AdService(),
        todayProvider: () => '2026-06-07',
        onTierSelected: (_, __) {},
      ),
    ));
    expect(find.byKey(const Key('reset-countdown')), findsOneWidget);
    expect(find.textContaining('Resets in'), findsOneWidget);
  });

  testWidgets('main-menu Leaderboard button is always visible', (tester) async {
    final storage = InMemoryStorageService();
    await tester.pumpWidget(MaterialApp(
      home: TierSelectScreen(
        storage: storage,
        adService: AdService(),
        todayProvider: () => '2026-06-07',
        onTierSelected: (_, __) {},
      ),
    ));
    expect(find.byKey(const Key('open-leaderboard-menu')), findsOneWidget);
  });

  testWidgets('offline, tapping Leaderboard shows an explanatory snackbar',
      (tester) async {
    final storage = InMemoryStorageService();
    await tester.pumpWidget(MaterialApp(
      home: TierSelectScreen(
        storage: storage,
        adService: AdService(),
        todayProvider: () => '2026-06-07',
        onTierSelected: (_, __) {},
      ),
    ));

    await tester.tap(find.byKey(const Key('open-leaderboard-menu')));
    await tester.pump(); // start the snackbar animation
    expect(find.text('Leaderboards need an internet connection.'),
        findsOneWidget);
  });
}

BoardState _completedBoard() => BoardState(
      cells: List<Tile?>.filled(kCellCount, null),
      movesRemaining: 0,
      score: 0,
      nextTileId: 0,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 0,
      status: GameStatus.outOfMoves,
    );
