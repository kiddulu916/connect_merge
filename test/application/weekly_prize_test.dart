import 'package:connect_merge/application/engagement_cubit.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/leaderboard_entry.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// June 2026 calendar reference (June 1 = Monday):
//   Mon: June 1, 8, 15, 22, 29
//   Sun: June 7, 14, 21, 28
// ---------------------------------------------------------------------------

// A capturing fake that records the date range each call receives.
class _FakeLeaderboard {
  final int rank;
  String? capturedFrom;
  String? capturedTo;

  _FakeLeaderboard(this.rank);

  Future<List<LeaderboardEntry>> fetchPeriod({
    required Difficulty difficulty,
    required String from,
    required String to,
  }) async {
    capturedFrom = from;
    capturedTo = to;
    return [
      const LeaderboardEntry(rank: 1, displayName: 'Alice', score: 9000, isMe: false),
      LeaderboardEntry(rank: rank, displayName: 'Me', score: 1000, isMe: true),
    ];
  }
}

void main() {
  late InMemoryStorageService storage;

  setUp(() {
    storage = InMemoryStorageService();
  });

  // ---------------------------------------------------------------------------
  // Coin payout amounts
  // ---------------------------------------------------------------------------

  group('coin payouts', () {
    // June 24 = Wednesday; previous completed week = June 15 (Mon) → June 21 (Sun).
    late EngagementCubit cubit;
    setUp(() {
      cubit = EngagementCubit(
          storage: storage, todayProvider: () => '2026-06-24');
      cubit.load();
    });
    tearDown(() => cubit.close());

    test('rank 1 grants 500 coins and records crown', () async {
      final fake = _FakeLeaderboard(1);
      await cubit.checkWeeklyPrizes(fake.fetchPeriod);
      expect(cubit.state.coins, equals(500));
      expect(
          cubit.state.weeklyPrizes.length,
          equals(Difficulty.values
              .where((d) => d != Difficulty.challenge)
              .length));
    });

    test('rank 2 grants 250 coins', () async {
      final fake = _FakeLeaderboard(2);
      await cubit.checkWeeklyPrizes(fake.fetchPeriod);
      expect(cubit.state.coins, equals(250));
    });

    test('rank 3 grants 100 coins', () async {
      final fake = _FakeLeaderboard(3);
      await cubit.checkWeeklyPrizes(fake.fetchPeriod);
      expect(cubit.state.coins, equals(100));
    });

    test('rank 4+ grants no coins', () async {
      final fake = _FakeLeaderboard(4);
      await cubit.checkWeeklyPrizes(fake.fetchPeriod);
      expect(cubit.state.coins, equals(0));
    });

    test('second call in same week is a no-op (idempotent)', () async {
      final fake = _FakeLeaderboard(1);
      await cubit.checkWeeklyPrizes(fake.fetchPeriod);
      await cubit.checkWeeklyPrizes(fake.fetchPeriod);
      expect(cubit.state.coins, equals(500)); // only 500, not 1000
    });
  });

  // ---------------------------------------------------------------------------
  // Date range: prizes are for the PREVIOUS completed Mon–Sun week
  // ---------------------------------------------------------------------------

  group('previous-week date range', () {
    test('on a Tuesday: range is the preceding Mon–Sun (fully completed week)',
        () async {
      // June 23 = Tuesday. This week's Mon = June 22. Prev week = June 15 → June 21.
      final cubit = EngagementCubit(
          storage: storage, todayProvider: () => '2026-06-23');
      cubit.load();
      final fake = _FakeLeaderboard(1);
      await cubit.checkWeeklyPrizes(fake.fetchPeriod);
      expect(fake.capturedFrom, '2026-06-15');
      expect(fake.capturedTo, '2026-06-21');
      cubit.close();
    });

    test('on a Monday: range is PREVIOUS week Mon–Sun (not today → future)',
        () async {
      // June 22 = Monday. This week just started. Prev week = June 15 → June 21.
      final cubit = EngagementCubit(
          storage: storage, todayProvider: () => '2026-06-22');
      cubit.load();
      final fake = _FakeLeaderboard(1);
      await cubit.checkWeeklyPrizes(fake.fetchPeriod);
      // Must NOT query June 22 → June 28 (the incomplete current week).
      expect(fake.capturedFrom, '2026-06-15');
      expect(fake.capturedTo, '2026-06-21');
      cubit.close();
    });

    test('on a Sunday: range is the week before this week (not current week)',
        () async {
      // June 21 = Sunday. This week's Mon = June 15. Prev week = June 8 → June 14.
      // (The current week June 15–21 ends today but prizes check AFTER the week closes.)
      final cubit = EngagementCubit(
          storage: storage, todayProvider: () => '2026-06-21');
      cubit.load();
      final fake = _FakeLeaderboard(1);
      await cubit.checkWeeklyPrizes(fake.fetchPeriod);
      expect(fake.capturedFrom, '2026-06-08');
      expect(fake.capturedTo, '2026-06-14');
      cubit.close();
    });

    test('guard advances on next Monday so each completed week is checked once',
        () async {
      // First open on Tuesday June 23: checks June 15 → June 21, guard = '2026-06-15'.
      final cubita = EngagementCubit(
          storage: storage, todayProvider: () => '2026-06-23');
      cubita.load();
      await cubita.checkWeeklyPrizes(_FakeLeaderboard(1).fetchPeriod);
      cubita.close();

      // On Monday June 29 the guard changes: now checks June 22 → June 28.
      final cubitb = EngagementCubit(
          storage: storage, todayProvider: () => '2026-06-29');
      cubitb.load();
      final fake = _FakeLeaderboard(2);
      await cubitb.checkWeeklyPrizes(fake.fetchPeriod);
      expect(fake.capturedFrom, '2026-06-22');
      expect(fake.capturedTo, '2026-06-28');
      cubitb.close();
    });

    test('week boundary: correctly crosses month end', () async {
      // June 2 = Tuesday. This week's Mon = June 1. Prev week = May 25 → May 31.
      final cubit = EngagementCubit(
          storage: storage, todayProvider: () => '2026-06-02');
      cubit.load();
      final fake = _FakeLeaderboard(1);
      await cubit.checkWeeklyPrizes(fake.fetchPeriod);
      expect(fake.capturedFrom, '2026-05-25');
      expect(fake.capturedTo, '2026-05-31');
      cubit.close();
    });
  });
}
