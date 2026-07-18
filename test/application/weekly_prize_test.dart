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
      const LeaderboardEntry(
          rank: 1, displayName: 'Alice', score: 9000, isMe: false),
      LeaderboardEntry(rank: rank, displayName: 'Me', score: 1000, isMe: true),
    ];
  }
}

List<LeaderboardEntry> _entries(int rank) => [
      LeaderboardEntry(
        rank: rank,
        displayName: 'Me',
        score: 1000,
        isMe: true,
      ),
    ];

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
      cubit =
          EngagementCubit(storage: storage, todayProvider: () => '2026-06-24');
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

    test('zero payout stamps guard without emitting', () async {
      final emitted = <EngagementState>[];
      final subscription = cubit.stream.listen(emitted.add);

      await cubit.checkWeeklyPrizes(_FakeLeaderboard(4).fetchPeriod);
      await Future<void>.delayed(Duration.zero);

      expect(storage.loadProfile().prizes.lastWeeklyPrizeDate, '2026-06-15');
      expect(emitted, isEmpty);
      await subscription.cancel();
    });

    test('any fetch failure aborts without stamp and a healthy retry pays',
        () async {
      var failMedium = true;
      Future<List<LeaderboardEntry>> fetch({
        required Difficulty difficulty,
        required String from,
        required String to,
      }) async {
        if (failMedium && difficulty == Difficulty.medium) {
          throw StateError('network down');
        }
        return _entries(1);
      }

      await cubit.checkWeeklyPrizes(fetch);

      expect(storage.loadProfile().prizes.lastWeeklyPrizeDate, isNull);
      expect(storage.loadProfile().wallet.coins, 0);
      expect(storage.loadProfile().prizes.weeklyPrizes, isEmpty);
      expect(cubit.state.coins, 0);
      expect(cubit.state.weeklyPrizes, isEmpty);

      failMedium = false;
      await cubit.checkWeeklyPrizes(fetch);

      expect(storage.loadProfile().prizes.lastWeeklyPrizeDate, '2026-06-15');
      expect(cubit.state.coins, 500);
      expect(cubit.state.weeklyPrizes, hasLength(4));
    });

    test('best tier rank pays once and every qualifying tier gets a crown',
        () async {
      Future<List<LeaderboardEntry>> fetch({
        required Difficulty difficulty,
        required String from,
        required String to,
      }) async {
        final ranks = {
          Difficulty.easy: 4,
          Difficulty.medium: 3,
          Difficulty.hard: 1,
          Difficulty.legendary: 5,
        };
        return _entries(ranks[difficulty] ?? 5);
      }

      await cubit.checkWeeklyPrizes(fetch);

      expect(cubit.state.coins, 500);
      expect(
        cubit.state.weeklyPrizes.map((prize) => prize.tier).toSet(),
        {Difficulty.medium, Difficulty.hard},
      );
    });
  });

  test('two consecutive top-three weeks retain both weeks of crowns', () async {
    final first = EngagementCubit(
      storage: storage,
      todayProvider: () => '2026-06-24',
    )..load();
    await first.checkWeeklyPrizes(_FakeLeaderboard(1).fetchPeriod);
    await first.close();

    final second = EngagementCubit(
      storage: storage,
      todayProvider: () => '2026-06-30',
    )..load();
    await second.checkWeeklyPrizes(_FakeLeaderboard(2).fetchPeriod);

    expect(second.state.weeklyPrizes, hasLength(8));
    expect(storage.loadProfile().prizes.weeklyPrizes, hasLength(8));
    expect(
      second.state.weeklyPrizes.map((prize) => prize.weekStart).toSet(),
      {'2026-06-15', '2026-06-22'},
    );
    await second.close();
  });

  // ---------------------------------------------------------------------------
  // Date range: prizes are for the PREVIOUS completed Mon–Sun week
  // ---------------------------------------------------------------------------

  group('previous-week date range', () {
    test('on a Tuesday: range is the preceding Mon–Sun (fully completed week)',
        () async {
      // June 23 = Tuesday. This week's Mon = June 22. Prev week = June 15 → June 21.
      final cubit =
          EngagementCubit(storage: storage, todayProvider: () => '2026-06-23');
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
      final cubit =
          EngagementCubit(storage: storage, todayProvider: () => '2026-06-22');
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
      final cubit =
          EngagementCubit(storage: storage, todayProvider: () => '2026-06-21');
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
      final cubita =
          EngagementCubit(storage: storage, todayProvider: () => '2026-06-23');
      cubita.load();
      await cubita.checkWeeklyPrizes(_FakeLeaderboard(1).fetchPeriod);
      cubita.close();

      // On Monday June 29 the guard changes: now checks June 22 → June 28.
      final cubitb =
          EngagementCubit(storage: storage, todayProvider: () => '2026-06-29');
      cubitb.load();
      final fake = _FakeLeaderboard(2);
      await cubitb.checkWeeklyPrizes(fake.fetchPeriod);
      expect(fake.capturedFrom, '2026-06-22');
      expect(fake.capturedTo, '2026-06-28');
      cubitb.close();
    });

    test('week boundary: correctly crosses month end', () async {
      // June 2 = Tuesday. This week's Mon = June 1. Prev week = May 25 → May 31.
      final cubit =
          EngagementCubit(storage: storage, todayProvider: () => '2026-06-02');
      cubit.load();
      final fake = _FakeLeaderboard(1);
      await cubit.checkWeeklyPrizes(fake.fetchPeriod);
      expect(fake.capturedFrom, '2026-05-25');
      expect(fake.capturedTo, '2026-05-31');
      cubit.close();
    });

    test('week boundary: correctly crosses year end', () async {
      final cubit = EngagementCubit(
        storage: storage,
        todayProvider: () => '2026-01-02',
      )..load();
      final fake = _FakeLeaderboard(1);

      await cubit.checkWeeklyPrizes(fake.fetchPeriod);

      expect(fake.capturedFrom, '2025-12-22');
      expect(fake.capturedTo, '2025-12-28');
      await cubit.close();
    });
  });
}
