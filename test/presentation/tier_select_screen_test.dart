import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/application/engagement_cubit.dart';
import 'package:connect_merge/application/duel_cubit.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/duel_challenge.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/domain/models/tile.dart';
import 'package:connect_merge/infrastructure/ad_service.dart';
import 'package:connect_merge/infrastructure/analytics_service.dart';
import 'package:connect_merge/infrastructure/leaderboard_service.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:connect_merge/presentation/screens/tier_select_screen.dart';
import 'package:connect_merge/presentation/widgets/tutorial_spotlight.dart';

void main() {
  testWidgets('renders all four tiers with their tile counts', (tester) async {
    final storage = await _storageWithTutorialSeen();
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
    final storage = await _storageWithTutorialSeen();
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
    final storage = await _storageWithTutorialSeen();
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
    final storage = await _storageWithTutorialSeen();
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
    final storage = await _storageWithTutorialSeen();
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
    final storage = await _storageWithTutorialSeen();
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
    expect(
        find.text('Leaderboards need an internet connection.'), findsOneWidget);
  });

  testWidgets(
      'given a DuelCubit with a today challenge, renders the duel banner',
      (tester) async {
    final storage = await _storageWithTutorialSeen();
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

  testWidgets('fresh profiles auto-launch the mechanics tour', (tester) async {
    final storage = InMemoryStorageService();
    await tester.pumpWidget(_tierSelect(storage));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tutorial-tour')), findsOneWidget);
    expect(find.byKey(const Key('tier-easy')), findsNothing);
  });

  testWidgets('Skip persists completion before returning to plain tier select',
      (tester) async {
    final storage = InMemoryStorageService();
    await tester.pumpWidget(_tierSelect(storage));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tutorial-skip')));
    await tester.pumpAndSettle();

    expect(storage.loadProfile().settings.tutorialSeen, isTrue);
    expect(find.byKey(const Key('tutorial-tour')), findsNothing);
    expect(find.byKey(const Key('tier-easy')), findsOneWidget);
  });

  testWidgets('system back completes durably instead of abandoning the tour',
      (tester) async {
    final storage = InMemoryStorageService();
    await tester.pumpWidget(_tierSelect(storage));
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(storage.loadProfile().settings.tutorialSeen, isTrue);
    expect(find.byKey(const Key('tutorial-tour')), findsNothing);
  });

  testWidgets('tour stays modal until tutorialSeen is durably written',
      (tester) async {
    final storage = _DelayedTutorialStorage();
    await tester.pumpWidget(_tierSelect(storage));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tutorial-skip')));
    await tester.pump();
    await storage.saveStarted.future;
    expect(find.byKey(const Key('tutorial-completing')), findsOneWidget);
    expect(storage.loadProfile().settings.tutorialSeen, isFalse);

    storage.releaseSave.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tutorial-completing')), findsNothing);
    expect(storage.loadProfile().settings.tutorialSeen, isTrue);
  });

  testWidgets('failed completion remains open and retryable', (tester) async {
    final storage = _FailTutorialOnceStorage();
    await tester.pumpWidget(_tierSelect(storage));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tutorial-skip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tutorial-retry')), findsOneWidget);
    expect(storage.loadProfile().settings.tutorialSeen, isFalse);

    await tester.tap(find.byKey(const Key('tutorial-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tutorial-retry')), findsNothing);
    expect(storage.loadProfile().settings.tutorialSeen, isTrue);
  });

  testWidgets('step 6 scrolls an initially unmounted difficulty into view',
      (tester) async {
    final storage = InMemoryStorageService();
    await tester.pumpWidget(_tierSelect(storage));
    await tester.pumpAndSettle();
    await _finishMechanics(tester);

    for (var i = 0; i < 6; i++) {
      await tester.tap(find.byKey(const Key('tutorial-next')));
      await tester.pumpAndSettle();
    }

    expect(find.text('Legendary difficulty'), findsOneWidget);
    expect(find.byKey(const Key('tier-legendary')), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const Key('tier-legendary'))).dy,
        inInclusiveRange(0, 600));
    final spotlight =
        tester.widget<TutorialSpotlight>(find.byType(TutorialSpotlight));
    expect(
      spotlight.targetRect!
          .overlaps(tester.getRect(find.byKey(const Key('tier-legendary')))),
      isTrue,
    );
  });

  testWidgets('step 6 blocks real tier interaction beneath the coachmark',
      (tester) async {
    final storage = InMemoryStorageService();
    Difficulty? chosen;
    await tester.pumpWidget(MaterialApp(
      home: TierSelectScreen(
        storage: storage,
        adService: AdService(),
        todayProvider: () => '2026-06-07',
        onTierSelected: (_, difficulty) => chosen = difficulty,
      ),
    ));
    await tester.pumpAndSettle();
    await _finishMechanics(tester);

    await tester.tap(
      find.byKey(const Key('tier-easy')),
      warnIfMissed: false,
    );
    await tester.pump();

    expect(chosen, isNull);
    expect(find.byKey(const Key('tutorial-step-6')), findsOneWidget);
  });

  testWidgets('step 6 ignores rapid Next taps while measuring a new target',
      (tester) async {
    final storage = InMemoryStorageService();
    await tester.pumpWidget(_tierSelect(storage));
    await tester.pumpAndSettle();
    await _finishMechanics(tester);

    final next = find.byKey(const Key('tutorial-next'));
    await tester.tap(next);
    await tester.tap(next);
    await tester.pumpAndSettle();

    expect(find.text('Easy practice'), findsOneWidget);
    expect(find.text('Medium difficulty'), findsNothing);
  });

  testWidgets('Skip from step 6 persists and returns to plain tier select',
      (tester) async {
    final storage = InMemoryStorageService();
    await tester.pumpWidget(_tierSelect(storage));
    await tester.pumpAndSettle();
    await _finishMechanics(tester);

    await tester.tap(find.byKey(const Key('tutorial-skip')));
    await tester.pumpAndSettle();

    expect(storage.loadProfile().settings.tutorialSeen, isTrue);
    expect(find.byKey(const Key('tutorial-step-6')), findsNothing);
    expect(find.byKey(const Key('tier-easy')), findsOneWidget);
  });

  testWidgets('dismissal waits for an earlier queued prize commit too',
      (tester) async {
    final storage = _DelayedPrizeStorage();
    final engagement = EngagementCubit(
      storage: storage,
      todayProvider: () => '2026-06-24',
    )..load();
    addTearDown(engagement.close);
    final prize = engagement.checkDailyPrizes(
      ({required from, required to}) async => {
        from: {Difficulty.easy: 1},
      },
    );
    await storage.prizeSaveStarted.future;

    await tester.pumpWidget(MaterialApp(
      home: TierSelectScreen(
        storage: storage,
        adService: AdService(),
        engagement: engagement,
        todayProvider: () => '2026-06-24',
        onTierSelected: (_, __) {},
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tutorial-skip')));
    await tester.pump();
    expect(find.byKey(const Key('tutorial-completing')), findsOneWidget);

    storage.releasePrizeSave.complete();
    await prize;
    await tester.pumpAndSettle();

    final profile = storage.loadProfile();
    expect(profile.prizes.lastDailyPrizeDate, '2026-06-23');
    expect(profile.settings.tutorialSeen, isTrue);
    expect(find.byKey(const Key('tutorial-tour')), findsNothing);
  });

  testWidgets('natural step 7 completion returns and persists the tour',
      (tester) async {
    final storage = InMemoryStorageService();
    final leaderboard = LeaderboardService.withSeams(
      invoke: (_, __) async => const {},
      rpc: (_, __) async => const [],
    );
    await tester.pumpWidget(MaterialApp(
      home: TierSelectScreen(
        storage: storage,
        adService: AdService(),
        leaderboard: leaderboard,
        todayProvider: () => '2026-06-07',
        onTierSelected: (_, __) {},
      ),
    ));
    await tester.pumpAndSettle();
    await _finishMechanics(tester);
    for (var i = 0; i < 9; i++) {
      await tester.tap(find.byKey(const Key('tutorial-next')));
      await tester.pumpAndSettle();
    }

    expect(find.text('Choose a time period'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pumpAndSettle();
    expect(find.text('How rankings work'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pumpAndSettle();

    expect(storage.loadProfile().settings.tutorialSeen, isTrue);
    expect(find.byKey(const Key('tutorial-step-7')), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const Key('tier-easy')),
      -300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.byKey(const Key('tier-easy')), findsOneWidget);
  });

  testWidgets('tour analytics record start, skipped step, then durable finish',
      (tester) async {
    final storage = InMemoryStorageService();
    final events = <MapEntry<String, Map<String, Object?>?>>[];
    final analytics = AnalyticsService.withSeams(
      logEvent: (name, params) async => events.add(MapEntry(name, params)),
    );
    await tester.pumpWidget(MaterialApp(
      home: TierSelectScreen(
        storage: storage,
        adService: AdService(),
        analytics: analytics,
        todayProvider: () => '2026-06-07',
        onTierSelected: (_, __) {},
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tutorial-skip')));
    await tester.pumpAndSettle();

    expect(events.map((event) => event.key), [
      'tutorial_started',
      'tutorial_skipped',
      'tutorial_completed',
    ]);
    expect(events[1].value, {'step': 1});
  });
}

Future<InMemoryStorageService> _storageWithTutorialSeen() async {
  final storage = InMemoryStorageService();
  final profile = storage.loadProfile();
  await storage.saveProfile(profile.copyWith(
    settings: profile.settings.copyWith(tutorialSeen: true),
  ));
  return storage;
}

Widget _tierSelect(StorageService storage) => MaterialApp(
      home: TierSelectScreen(
        storage: storage,
        adService: AdService(),
        todayProvider: () => '2026-06-07',
        onTierSelected: (_, __) {},
      ),
    );

Future<void> _finishMechanics(WidgetTester tester) async {
  final semantics = tester.ensureSemantics();
  const action = CustomSemanticsAction(label: 'Merge highlighted tiles');
  void merge() {
    final node =
        tester.getSemantics(find.byKey(const Key('tutorial-semantic-merge')));
    node.owner!.performAction(
      node.id,
      SemanticsAction.customAction,
      CustomSemanticsAction.getIdentifier(action),
    );
  }

  merge();
  await tester.pumpAndSettle();
  for (var i = 0; i < 3; i++) {
    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pumpAndSettle();
  }
  merge();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.tap(find.byKey(const Key('tutorial-next')));
  await tester.pumpAndSettle();
  semantics.dispose();
}

class _DelayedTutorialStorage extends InMemoryStorageService {
  final saveStarted = Completer<void>();
  final releaseSave = Completer<void>();

  @override
  Future<void> saveProfile(PlayerProfile profile) async {
    if (profile.settings.tutorialSeen) {
      saveStarted.complete();
      await releaseSave.future;
    }
    await super.saveProfile(profile);
  }
}

class _FailTutorialOnceStorage extends InMemoryStorageService {
  var failed = false;

  @override
  Future<void> saveProfile(PlayerProfile profile) async {
    if (profile.settings.tutorialSeen && !failed) {
      failed = true;
      throw StateError('tutorial write failed');
    }
    await super.saveProfile(profile);
  }
}

class _DelayedPrizeStorage extends InMemoryStorageService {
  final prizeSaveStarted = Completer<void>();
  final releasePrizeSave = Completer<void>();
  var _delayed = false;

  @override
  Future<void> saveProfile(PlayerProfile profile) async {
    if (!_delayed && profile.prizes.lastDailyPrizeDate != null) {
      _delayed = true;
      prizeSaveStarted.complete();
      await releasePrizeSave.future;
    }
    await super.saveProfile(profile);
  }
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
