import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/leaderboard_entry.dart';
import 'package:connect_merge/infrastructure/leaderboard_service.dart';
import 'package:connect_merge/presentation/screens/leaderboard_screen.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Service that records every RPC call so tests can assert on params.
class _CapturingService {
  String? capturedFn;
  Map<String, dynamic>? capturedParams;

  LeaderboardService build([List<LeaderboardEntry> entries = const []]) {
    return LeaderboardService.withSeams(
      invoke: (_, __) async => const {},
      rpc: (fn, params) async {
        capturedFn = fn;
        capturedParams = params;
        return entries
            .map((e) => {
                  'rank': e.rank,
                  'display_name': e.displayName,
                  'score': e.score,
                  'total': e.score, // period RPC uses 'total' column
                  'is_me': e.isMe,
                })
            .toList();
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Unit tests: LeaderboardPeriodX.range()
// ---------------------------------------------------------------------------

void main() {
  group('LeaderboardPeriodX.range() — date-range computation', () {
    // June 1 2026 is a Monday; we use dates anchored to that for clarity.
    const monday = '2026-06-08'; // a known Monday (June 8 = June 1 + 7 days)
    const wednesday = '2026-06-10'; // June 10 = June 8 + 2 (Wednesday)
    const sunday = '2026-06-14'; // June 14 = June 8 + 6 (Sunday)
    const midMonth = '2026-06-15';
    const firstOfMonth = '2026-06-01';
    const farFuture = '2026-12-31';

    test('daily: from==to==today', () {
      expect(LeaderboardPeriod.daily.range(wednesday), (wednesday, wednesday));
      expect(LeaderboardPeriod.daily.range(monday), (monday, monday));
    });

    test('weekly on a Wednesday: from=Monday, to=today', () {
      final (from, to) = LeaderboardPeriod.weekly.range(wednesday);
      expect(from, monday); // June 8
      expect(to, wednesday); // June 10
    });

    test('weekly on a Monday: from==to==today (single-day window)', () {
      final (from, to) = LeaderboardPeriod.weekly.range(monday);
      expect(from, monday);
      expect(to, monday);
    });

    test('weekly on a Sunday: from=Monday-of-week, to=today', () {
      final (from, to) = LeaderboardPeriod.weekly.range(sunday);
      expect(from, monday); // June 8
      expect(to, sunday); // June 14
    });

    test('weekly crosses a year boundary', () {
      final (from, to) = LeaderboardPeriod.weekly.range('2026-01-01');
      expect(from, '2025-12-29');
      expect(to, '2026-01-01');
    });

    test('weekly finds Monday after Cairo spring-forward', () {
      final (from, to) = LeaderboardPeriod.weekly.range('2025-04-26');
      expect(from, '2025-04-21');
      expect(to, '2025-04-26');
    });

    test('weekly: from is always <= to', () {
      for (final day in [monday, wednesday, sunday, midMonth, firstOfMonth]) {
        final (from, to) = LeaderboardPeriod.weekly.range(day);
        expect(DateTime.parse(from).isBefore(DateTime.parse(to)) ||
            from == to, isTrue,
            reason: 'from=$from to=$to for today=$day');
      }
    });

    test('monthly on mid-month: from=1st, to=today', () {
      final (from, to) = LeaderboardPeriod.monthly.range(midMonth);
      expect(from, '2026-06-01');
      expect(to, midMonth);
    });

    test('monthly on the 1st: from==to==1st', () {
      final (from, to) = LeaderboardPeriod.monthly.range(firstOfMonth);
      expect(from, '2026-06-01');
      expect(to, firstOfMonth);
    });

    test('monthly crosses year boundary (Jan): from=Jan-01', () {
      final (from, to) = LeaderboardPeriod.monthly.range('2027-01-20');
      expect(from, '2027-01-01');
      expect(to, '2027-01-20');
    });

    test('all-time: from=2020-01-01, to=today regardless of input', () {
      expect(
        LeaderboardPeriod.allTime.range(wednesday),
        ('2020-01-01', wednesday),
      );
      expect(
        LeaderboardPeriod.allTime.range(farFuture),
        ('2020-01-01', farFuture),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Widget tests: period selection routes to the correct RPC + date params
  // ---------------------------------------------------------------------------

  group('LeaderboardScreen — period selection sends correct date ranges', () {
    // A Wednesday in the middle of a known week (June 8 is Monday).
    const today = '2026-06-10'; // Wednesday

    testWidgets('switching to Weekly calls leaderboard_period with Mon→today',
        (tester) async {
      final cap = _CapturingService();
      await tester.pumpWidget(MaterialApp(
        home: LeaderboardScreen(
          service: cap.build(),
          todayProvider: () => today,
        ),
      ));
      await tester.pumpAndSettle();

      // Tap "Weekly" in the period segmented button.
      await tester.tap(find.text('Weekly'));
      await tester.pumpAndSettle();

      expect(cap.capturedFn, 'leaderboard_period');
      expect(cap.capturedParams!['p_from'], '2026-06-08'); // Monday
      expect(cap.capturedParams!['p_to'], today);
    });

    testWidgets('switching to Monthly calls leaderboard_period with 1st→today',
        (tester) async {
      final cap = _CapturingService();
      await tester.pumpWidget(MaterialApp(
        home: LeaderboardScreen(
          service: cap.build(),
          todayProvider: () => today,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Monthly'));
      await tester.pumpAndSettle();

      expect(cap.capturedFn, 'leaderboard_period');
      expect(cap.capturedParams!['p_from'], '2026-06-01');
      expect(cap.capturedParams!['p_to'], today);
    });

    testWidgets('switching to All-time calls leaderboard_period with 2020-01-01→today',
        (tester) async {
      final cap = _CapturingService();
      await tester.pumpWidget(MaterialApp(
        home: LeaderboardScreen(
          service: cap.build(),
          todayProvider: () => today,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('All-time'));
      await tester.pumpAndSettle();

      expect(cap.capturedFn, 'leaderboard_period');
      expect(cap.capturedParams!['p_from'], '2020-01-01');
      expect(cap.capturedParams!['p_to'], today);
    });

    testWidgets('Daily (default) calls the daily leaderboard RPC, not period',
        (tester) async {
      final cap = _CapturingService();
      await tester.pumpWidget(MaterialApp(
        home: LeaderboardScreen(
          service: cap.build(),
          todayProvider: () => today,
        ),
      ));
      await tester.pumpAndSettle();

      // Default period is Daily — the daily RPC should have been called.
      expect(cap.capturedFn, 'leaderboard');
      expect(cap.capturedParams!['p_date'], today);
    });

    testWidgets('Weekly on a Monday produces a single-day from==to==today range',
        (tester) async {
      const aMonday = '2026-06-08';
      final cap = _CapturingService();
      await tester.pumpWidget(MaterialApp(
        home: LeaderboardScreen(
          service: cap.build(),
          todayProvider: () => aMonday,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Weekly'));
      await tester.pumpAndSettle();

      // On a Monday the week just started; from == to == today.
      expect(cap.capturedParams!['p_from'], aMonday);
      expect(cap.capturedParams!['p_to'], aMonday);
    });

    testWidgets(
        'Weekly on a Sunday produces a full Mon-Sun range (7-day window)',
        (tester) async {
      const aSunday = '2026-06-14';
      final cap = _CapturingService();
      await tester.pumpWidget(MaterialApp(
        home: LeaderboardScreen(
          service: cap.build(),
          todayProvider: () => aSunday,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Weekly'));
      await tester.pumpAndSettle();

      expect(cap.capturedParams!['p_from'], '2026-06-08'); // Monday
      expect(cap.capturedParams!['p_to'], aSunday); // Sunday
    });

    testWidgets('period tabs are hidden when viewing the challenge difficulty',
        (tester) async {
      final cap = _CapturingService();
      await tester.pumpWidget(MaterialApp(
        home: LeaderboardScreen(
          service: cap.build(),
          todayProvider: () => today,
          initialDifficulty: Difficulty.challenge,
        ),
      ));
      await tester.pumpAndSettle();

      // Period tabs should not be visible on the challenge tab.
      expect(find.byKey(const Key('lb-period-tabs')), findsNothing);
    });
  });
}
