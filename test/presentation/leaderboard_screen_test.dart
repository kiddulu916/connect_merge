import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/leaderboard_entry.dart';
import 'package:connect_merge/domain/models/weekly_prize.dart';
import 'package:connect_merge/infrastructure/friends_service.dart';
import 'package:connect_merge/infrastructure/leaderboard_service.dart';
import 'package:connect_merge/presentation/screens/leaderboard_screen.dart';

LeaderboardService _serviceReturning(List<LeaderboardEntry> entries) {
  return LeaderboardService.withSeams(
    invoke: (_, __) async => const {},
    rpc: (_, __) async => entries
        .map((e) => {
              'rank': e.rank,
              'display_name': e.displayName,
              'score': e.score,
              'is_me': e.isMe,
            })
        .toList(),
  );
}

LeaderboardService _serviceThrowing() => LeaderboardService.withSeams(
      invoke: (_, __) async => const {},
      rpc: (_, __) async => throw StateError('offline'),
    );

class _RpcCapture {
  final calls = <(String, Map<String, dynamic>)>[];

  Future<dynamic> rpc(String fn, Map<String, dynamic> params) async {
    calls.add((fn, params));
    return const [];
  }

  LeaderboardService leaderboard() => LeaderboardService.withSeams(
        invoke: (_, __) async => const {},
        rpc: (fn, params) async => (await rpc(fn, params)) as List<dynamic>,
      );

  FriendsService friends() => FriendsService.withSeams(
        rpc: rpc,
        invoke: (_, __) async => const {},
        insert: (_, __) async {},
        deleteMine: (_) async {},
        selectMine: (_) async => const [],
      );
}

void main() {
  testWidgets('tutorial skips the Friends spotlight when friends are disabled',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LeaderboardScreen(
        service: _serviceReturning(const []),
        todayProvider: () => '2026-06-07',
        tutorialMode: true,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Choose a time period'), findsOneWidget);
    expect(find.text('Global or friends'), findsNothing);
    expect(find.byKey(const Key('tutorial-skip')), findsOneWidget);
  });

  for (final service in [_serviceReturning(const []), _serviceThrowing()]) {
    testWidgets('tutorial explains rows in text when no row can be targeted',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: LeaderboardScreen(
          service: service,
          todayProvider: () => '2026-06-07',
          tutorialMode: true,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('tutorial-next')));
      await tester.pumpAndSettle();

      expect(find.text('How rankings work'), findsOneWidget);
      expect(find.byKey(const Key('tutorial-text-fallback')), findsOneWidget);
    });
  }

  testWidgets('tutorial locks in text fallback when rows are still loading',
      (tester) async {
    final rows = Completer<List<dynamic>>();
    final service = LeaderboardService.withSeams(
      invoke: (_, __) async => const {},
      rpc: (_, __) => rows.future,
    );
    await tester.pumpWidget(MaterialApp(
      home: LeaderboardScreen(
        service: service,
        todayProvider: () => '2026-06-07',
        tutorialMode: true,
      ),
    ));
    await tester.pump();

    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pump();
    expect(find.byKey(const Key('tutorial-text-fallback')), findsOneWidget);

    rows.complete(const [
      {
        'rank': 1,
        'display_name': 'Late player',
        'score': 100,
        'is_me': false,
      },
    ]);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tutorial-text-fallback')), findsOneWidget);
  });

  testWidgets('tutorial ignores rapid Next taps while changing targets',
      (tester) async {
    final capture = _RpcCapture();
    await tester.pumpWidget(MaterialApp(
      home: LeaderboardScreen(
        service: capture.leaderboard(),
        friendsService: capture.friends(),
        todayProvider: () => '2026-06-07',
        tutorialMode: true,
      ),
    ));
    await tester.pumpAndSettle();

    final next = find.byKey(const Key('tutorial-next'));
    await tester.tap(next);
    await tester.tap(next);
    await tester.pumpAndSettle();

    expect(find.text('Choose a time period'), findsOneWidget);
    expect(find.text('How rankings work'), findsNothing);
  });

  testWidgets('empty state when no scores today', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LeaderboardScreen(
        service: _serviceReturning(const []),
        todayProvider: () => '2026-06-07',
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lb-empty')), findsOneWidget);
  });

  testWidgets('renders a ranked list and highlights the player row',
      (tester) async {
    final entries = [
      for (var i = 1; i <= 50; i++)
        LeaderboardEntry(
          rank: i,
          displayName: 'Player$i',
          score: 1000 - i,
          isMe: i == 25,
        ),
    ];
    await tester.pumpWidget(MaterialApp(
      home: LeaderboardScreen(
        service: _serviceReturning(entries),
        todayProvider: () => '2026-06-07',
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('lb-list')), findsOneWidget);
    expect(find.text('Player1'), findsOneWidget);
    // The player's own row (rank 25) is mid-list; scroll it into view to
    // confirm it renders with the "You" highlight tag.
    await tester.scrollUntilVisible(
      find.byKey(const Key('lb-row-25')),
      300,
      scrollable: find.descendant(
        of: find.byKey(const Key('lb-list')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.byKey(const Key('lb-row-25')), findsOneWidget);
    expect(find.text('You'), findsWidgets);
  });

  testWidgets('single entry (just you)', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LeaderboardScreen(
        service: _serviceReturning(const [
          LeaderboardEntry(
              rank: 1, displayName: 'Solo', score: 500, isMe: true),
        ]),
        todayProvider: () => '2026-06-07',
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lb-row-1')), findsOneWidget);
    expect(find.text('Solo'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
  });

  testWidgets('Friends scope keeps every non-challenge period tab visible',
      (tester) async {
    final capture = _RpcCapture();
    await tester.pumpWidget(MaterialApp(
      home: LeaderboardScreen(
        service: capture.leaderboard(),
        friendsService: capture.friends(),
        todayProvider: () => '2026-06-10',
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Friends'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('lb-period-tabs')), findsOneWidget);
    expect(find.text('Weekly'), findsOneWidget);
    expect(find.text('Monthly'), findsOneWidget);
    expect(find.text('All-time'), findsOneWidget);
  });

  testWidgets('Friends weekly routes through friends_leaderboard_period',
      (tester) async {
    final capture = _RpcCapture();
    await tester.pumpWidget(MaterialApp(
      home: LeaderboardScreen(
        service: capture.leaderboard(),
        friendsService: capture.friends(),
        todayProvider: () => '2026-06-10',
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Friends'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Weekly'));
    await tester.pumpAndSettle();

    final call = capture.calls.lastWhere(
      (call) => call.$1 == 'friends_leaderboard_period',
    );
    expect(call.$2['p_from'], '2026-06-08');
    expect(call.$2['p_to'], '2026-06-10');
  });

  testWidgets('Global period selection is forced daily on Challenge',
      (tester) async {
    final capture = _RpcCapture();
    await tester.pumpWidget(MaterialApp(
      home: LeaderboardScreen(
        service: capture.leaderboard(),
        todayProvider: () => '2026-06-10',
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Weekly'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Challenge'));
    await tester.pumpAndSettle();

    final call = capture.calls.lastWhere(
      (call) => call.$2['p_diff'] == 'challenge',
    );
    expect(call.$1, 'leaderboard');
    expect(call.$2['p_date'], '2026-06-10');
  });

  testWidgets('Friends period selection is forced daily on Challenge',
      (tester) async {
    final capture = _RpcCapture();
    await tester.pumpWidget(MaterialApp(
      home: LeaderboardScreen(
        service: capture.leaderboard(),
        friendsService: capture.friends(),
        todayProvider: () => '2026-06-10',
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Friends'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Monthly'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Challenge'));
    await tester.pumpAndSettle();

    final call = capture.calls.lastWhere(
      (call) => call.$2['p_diff'] == 'challenge',
    );
    expect(call.$1, 'friends_leaderboard');
    expect(call.$2['p_date'], '2026-06-10');
  });

  testWidgets('Challenge renders through rank 100 but not rank 101',
      (tester) async {
    final entries = [
      for (var rank = 1; rank <= 105; rank++)
        LeaderboardEntry(
          rank: rank,
          displayName: 'Challenge$rank',
          score: 1000 - rank,
          isMe: false,
        ),
    ];
    await tester.pumpWidget(MaterialApp(
      home: LeaderboardScreen(
        service: _serviceReturning(entries),
        initialDifficulty: Difficulty.challenge,
        todayProvider: () => '2026-06-10',
      ),
    ));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('lb-row-100')),
      1000,
      scrollable: find.descendant(
        of: find.byKey(const Key('lb-list')),
        matching: find.byType(Scrollable),
      ),
    );

    expect(find.byKey(const Key('lb-row-100')), findsOneWidget);
    expect(find.byKey(const Key('lb-row-101')), findsNothing);
  });

  for (final rank in [4, 5]) {
    testWidgets('weekly rank $rank renders the medal crown fallback',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: LeaderboardScreen(
          service: _serviceReturning(const [
            LeaderboardEntry(
              rank: 9,
              displayName: 'Me',
              score: 500,
              isMe: true,
            ),
          ]),
          weeklyPrizes: [
            WeeklyPrize(
              weekStart: '2026-06-01',
              tier: Difficulty.easy,
              rank: rank,
            ),
          ],
          todayProvider: () => '2026-06-10',
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('\u{1F3C5}'), findsWidgets);
    });
  }
}
