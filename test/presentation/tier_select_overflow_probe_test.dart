import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/domain/models/tile.dart';
import 'package:connect_merge/infrastructure/ad_service.dart';
import 'package:connect_merge/infrastructure/friends_service.dart';
import 'package:connect_merge/infrastructure/leaderboard_service.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:connect_merge/presentation/screens/tier_select_screen.dart';

/// Regression guard: render the screen at 375px wide (small phone) with the
/// worst-case tier-card layout — online (per-tier leaderboard icon shown) AND
/// every tier completed ("Done today" status) — and assert there is no
/// RenderFlex overflow. Previously the status badge sat unconstrained in the
/// fixed trailing row and overflowed by 55px at this width.
void main() {
  testWidgets('no overflow at 375px with completed tier + online icons',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 812));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final storage = await _storageWithTutorialSeen();
    // Complete EVERY tier so all four cards show the worst-case trailing cluster.
    for (final d in Difficulty.values) {
      await storage.saveSnapshot(GameSnapshot(
        date: '2026-06-07',
        difficulty: d,
        board: _completedBoard(),
        completed: true,
      ));
    }

    final leaderboard = LeaderboardService.withSeams(
      invoke: (_, __) async => <String, dynamic>{},
      rpc: (_, __) async => <dynamic>[],
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
    await tester.pump();

    // Scroll each card into view so it actually lays out at this width.
    final tierList = find.byType(Scrollable).last;
    for (final d in Difficulty.values) {
      await tester.scrollUntilVisible(
        find.byKey(Key('tier-${d.name}')),
        100,
        scrollable: tierList,
      );
    }

    expect(tester.takeException(), isNull,
        reason: 'A RenderFlex overflow at 375px would surface here.');
  });

  testWidgets('app bar title is "Connect Merge" on one line with all 4 actions',
      (tester) async {
    // 360px wide + ALL secondary-nav icons present (friends online adds the 4th)
    // is the worst case for the title; it must not wrap to a second line.
    await tester.binding.setSurfaceSize(const Size(360, 812));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final storage = await _storageWithTutorialSeen();
    await tester.pumpWidget(MaterialApp(
      home: TierSelectScreen(
        storage: storage,
        adService: AdService(),
        leaderboard: _seamLeaderboard(),
        friends: _seamFriends(),
        todayProvider: () => '2026-06-07',
        onTierSelected: (_, __) {},
      ),
    ));
    await tester.pump();

    final title = find.text('Connect Merge');
    expect(title, findsOneWidget);

    // One line: the rendered paragraph height must stay well under two lines.
    final para = tester.renderObject<RenderParagraph>(title);
    expect(para.size.height, lessThan(48),
        reason: 'Title wrapped to a second line.');
  });

  testWidgets('Legendary tier label is not truncated with online icons',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 812));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final storage = await _storageWithTutorialSeen();
    for (final d in Difficulty.values) {
      await storage.saveSnapshot(GameSnapshot(
        date: '2026-06-07',
        difficulty: d,
        board: _completedBoard(),
        completed: true,
      ));
    }

    await tester.pumpWidget(MaterialApp(
      home: TierSelectScreen(
        storage: storage,
        adService: AdService(),
        leaderboard: _seamLeaderboard(),
        friends: _seamFriends(),
        todayProvider: () => '2026-06-07',
        onTierSelected: (_, __) {},
      ),
    ));
    await tester.pump();

    final tierList = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(
      find.byKey(const Key('tier-legendary')),
      100,
      scrollable: tierList,
    );

    final label = find.text('Legendary');
    expect(label, findsOneWidget);
    final para = tester.renderObject<RenderParagraph>(label);
    expect(para.didExceedMaxLines, isFalse,
        reason: '"Legendary" is being ellipsized to "Legen…".');
  });
}

LeaderboardService _seamLeaderboard() => LeaderboardService.withSeams(
      invoke: (_, __) async => <String, dynamic>{},
      rpc: (_, __) async => <dynamic>[],
    );

FriendsService _seamFriends() => FriendsService.withSeams(
      rpc: (_, __) async => 'TESTCODE',
      invoke: (_, __) async => <String, dynamic>{},
      insert: (_, __) async {},
      deleteMine: (_) async {},
      selectMine: (_) async => const [],
    );

Future<InMemoryStorageService> _storageWithTutorialSeen() async {
  final storage = InMemoryStorageService();
  final profile = storage.loadProfile();
  await storage.saveProfile(profile.copyWith(
    settings: profile.settings.copyWith(tutorialSeen: true),
  ));
  return storage;
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
