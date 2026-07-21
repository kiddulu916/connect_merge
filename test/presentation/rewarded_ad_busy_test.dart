import 'package:connect_merge/application/engagement_cubit.dart';
import 'package:connect_merge/application/game_cubit.dart';
import 'package:connect_merge/application/game_state.dart';
import 'package:connect_merge/application/loot_cubit.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/engine/game_engine.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/domain/models/tile.dart';
import 'package:connect_merge/infrastructure/ad_service.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:connect_merge/presentation/screens/cosmetics_screen.dart';
import 'package:connect_merge/presentation/screens/game_screen.dart';
import 'package:connect_merge/presentation/screens/loot_chest_screen.dart';
import 'package:connect_merge/presentation/screens/score_share_screen.dart';
import 'package:connect_merge/presentation/screens/tier_select_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('GameScreen disables rewarded controls while an ad is busy',
      (tester) async {
    const date = '2026-07-02';
    final storage = InMemoryStorageService();
    final cubit = GameCubit(storage: storage, todayProvider: () => date);
    addTearDown(cubit.close);
    await cubit.init(difficulty: Difficulty.medium);
    await cubit.playChain(_findChain((cubit.state as GamePlaying).board));
    final adService = _busyAdService();

    await tester.pumpWidget(MaterialApp(
      home: BlocProvider.value(
        value: cubit,
        child: GameScreen(adService: adService, storage: storage),
      ),
    ));

    expect(tester.widget<OutlinedButton>(_button('hint-button')).onPressed,
        isNull);
    expect(tester.widget<OutlinedButton>(_button('undo-button')).onPressed,
        isNull);

    final resultStorage = InMemoryStorageService();
    final board = _outOfMovesBoard();
    await resultStorage.saveSnapshot(GameSnapshot(
      date: date,
      difficulty: Difficulty.easy,
      board: board,
      completed: false,
    ));
    final resultCubit =
        GameCubit(storage: resultStorage, todayProvider: () => date);
    addTearDown(resultCubit.close);
    await tester.pumpWidget(MaterialApp(
      home: BlocProvider.value(
        value: resultCubit,
        child: GameScreen(adService: adService, storage: resultStorage),
      ),
    ));
    await resultCubit.init(difficulty: Difficulty.easy);
    await tester.pumpAndSettle();

    final watch = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Watch for +$kAdMoveReward'),
    );
    expect(watch.onPressed, isNull);
  });

  testWidgets('ScoreShareScreen disables both rewarded controls while busy',
      (tester) async {
    final busy = _busyAdService().showing;
    await tester.pumpWidget(MaterialApp(
      home: ScoreShareScreen(
        adBusy: busy,
        board: _outOfMovesBoard(),
        date: '2026-07-02',
        stats: LifetimeStats.empty,
        canOfferAd: true,
        onWatchAd: () {},
        coinsEarned: 10,
        onDoubleCoins: () {},
      ),
    ));

    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('double-coins-button')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Watch ad for more moves'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('CosmeticsScreen disables rewarded unlock while busy',
      (tester) async {
    final storage = InMemoryStorageService();
    final engagement = EngagementCubit(storage: storage)..load();
    addTearDown(engagement.close);

    await tester.pumpWidget(MaterialApp(
      home: CosmeticsScreen(
        engagement: engagement,
        adService: _busyAdService(),
      ),
    ));

    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('cosmetic-ad-neon')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('LootChestScreen disables rewarded double while busy',
      (tester) async {
    final storage = InMemoryStorageService();
    final loot = LootCubit(
      storage: storage,
      todayProvider: () => '2026-07-02',
    )..load();
    addTearDown(loot.close);
    await loot.claim();

    await tester.pumpWidget(MaterialApp(
      home: LootChestScreen(loot: loot, adService: _busyAdService()),
    ));

    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('double-loot-button')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('TierSelectScreen disables streak freeze while busy',
      (tester) async {
    final storage = InMemoryStorageService();
    final profile = storage.loadProfile();
    await storage.saveProfile(profile.copyWith(
      activity: const ActivityStreak(
        dailyActiveStreak: 2,
        lastActiveDate: '2026-07-01',
      ),
      settings: profile.settings.copyWith(tutorialSeen: true),
    ));
    final engagement = EngagementCubit(
      storage: storage,
      todayProvider: () => '2026-07-02',
    )..load();
    addTearDown(engagement.close);

    await tester.pumpWidget(MaterialApp(
      home: TierSelectScreen(
        storage: storage,
        adService: _busyAdService(),
        engagement: engagement,
        todayProvider: () => '2026-07-02',
        onTierSelected: (_, __) {},
      ),
    ));

    expect(
      tester.widget<TextButton>(find.byKey(const Key('freeze-cta'))).onPressed,
      isNull,
    );
  });
}

AdService _busyAdService() => AdService.withSeams(
      initialized: false,
      showing: true,
    );

Finder _button(String key) => find.byKey(Key(key));

List<int> _findChain(BoardState board) {
  for (var i = 0; i < board.cells.length; i++) {
    final col = i % board.gridSize;
    final row = i ~/ board.gridSize;
    for (final neighbor in [
      if (col + 1 < board.gridSize) i + 1,
      if (row + 1 < board.gridSize) i + board.gridSize,
    ]) {
      for (final path in [
        [i, neighbor],
        [neighbor, i],
      ]) {
        if (GameEngine.isValidChain(board, path)) return path;
      }
    }
  }
  throw StateError('seeded board unexpectedly has no valid chain');
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
