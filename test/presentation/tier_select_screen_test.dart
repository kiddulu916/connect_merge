import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/application/duel_cubit.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/duel_challenge.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/domain/models/tile.dart';
import 'package:connect_merge/infrastructure/ad_service.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:connect_merge/presentation/screens/tier_select_screen.dart';

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

    // The tier list is a scrollable ListView, so a lower tier may start below
    // the fold; scroll each card into view before asserting on it.
    final tierList = find.byType(Scrollable).last;
    final regularTiers =
        Difficulty.values.where((d) => d != Difficulty.challenge);
    for (final d in regularTiers) {
      final card = find.byKey(Key('tier-${d.name}'));
      await tester.scrollUntilVisible(card, 100, scrollable: tierList);
      expect(card, findsOneWidget);
      expect(find.text(d.label), findsOneWidget);
      expect(find.text('${d.startingFill} starting tiles'), findsOneWidget);
    }
    // The challenge card is a separate widget below the four tier cards.
    final challengeCard = find.byKey(const Key('tier-challenge'));
    await tester.scrollUntilVisible(challengeCard, 100, scrollable: tierList);
    expect(challengeCard, findsOneWidget);
    expect(find.text('Daily Challenge'), findsOneWidget);
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

  testWidgets(
      'given a DuelCubit with a today challenge, renders the duel banner',
      (tester) async {
    final storage = InMemoryStorageService();
    final duels = DuelCubit(todayProvider: () => '2026-06-07')
      ..receiveChallenge(const DuelChallenge(
        date: '2026-06-07',
        difficulty: Difficulty.hard,
        challengerName: 'Ann',
        challengerScore: 1000,
      ));
    addTearDown(duels.close);

    await tester.pumpWidget(MaterialApp(
      home: TierSelectScreen(
        storage: storage,
        adService: AdService(),
        todayProvider: () => '2026-06-07',
        duels: duels,
        onTierSelected: (_, __) {},
      ),
    ));
    await tester.pump();

    expect(find.byKey(const Key('duel-banner')), findsOneWidget);
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
