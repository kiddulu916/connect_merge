import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/models/leaderboard_entry.dart';
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

void main() {
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
}
