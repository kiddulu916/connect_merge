import 'package:connect_merge/application/engagement_cubit.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/leaderboard_entry.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

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
          rank: 1, displayName: 'Alice', score: 99000, isMe: false),
      LeaderboardEntry(rank: rank, displayName: 'Me', score: 1000, isMe: true),
    ];
  }
}

void main() {
  late InMemoryStorageService storage;

  setUp(() => storage = InMemoryStorageService());

  // ---------------------------------------------------------------------------
  // Coin payout amounts
  // ---------------------------------------------------------------------------

  group('coin payouts', () {
    late EngagementCubit cubit;
    setUp(() {
      cubit =
          EngagementCubit(storage: storage, todayProvider: () => '2026-06-15');
      cubit.load();
    });
    tearDown(() => cubit.close());

    test('rank 1 grants 2000 coins', () async {
      await cubit.checkMonthlyPrizes(_FakeLeaderboard(1).fetchPeriod);
      expect(cubit.state.coins, 2000);
    });

    test('rank 2 grants 1000 coins', () async {
      await cubit.checkMonthlyPrizes(_FakeLeaderboard(2).fetchPeriod);
      expect(cubit.state.coins, 1000);
    });

    test('rank 3 grants 500 coins', () async {
      await cubit.checkMonthlyPrizes(_FakeLeaderboard(3).fetchPeriod);
      expect(cubit.state.coins, 500);
    });

    test('rank 4+ grants no coins', () async {
      await cubit.checkMonthlyPrizes(_FakeLeaderboard(4).fetchPeriod);
      expect(cubit.state.coins, 0);
    });

    test('second call in same month is a no-op (idempotent)', () async {
      await cubit.checkMonthlyPrizes(_FakeLeaderboard(1).fetchPeriod);
      await cubit.checkMonthlyPrizes(_FakeLeaderboard(1).fetchPeriod);
      expect(cubit.state.coins, 2000); // only 2000, not 4000
    });
  });

  // ---------------------------------------------------------------------------
  // Date range: prizes are for the PREVIOUS completed calendar month
  // ---------------------------------------------------------------------------

  group('previous-month date range', () {
    test('mid-month: range is full previous month', () async {
      // Today = June 15. Previous month = May. from=May-01, to=May-31.
      final cubit =
          EngagementCubit(storage: storage, todayProvider: () => '2026-06-15');
      cubit.load();
      final fake = _FakeLeaderboard(1);
      await cubit.checkMonthlyPrizes(fake.fetchPeriod);
      expect(fake.capturedFrom, '2026-05-01');
      expect(fake.capturedTo, '2026-05-31');
      cubit.close();
    });

    test('first of month: range is still the full previous month', () async {
      // Today = June 01. Previous month = May. from=May-01, to=May-31.
      final cubit =
          EngagementCubit(storage: storage, todayProvider: () => '2026-06-01');
      cubit.load();
      final fake = _FakeLeaderboard(1);
      await cubit.checkMonthlyPrizes(fake.fetchPeriod);
      expect(fake.capturedFrom, '2026-05-01');
      expect(fake.capturedTo, '2026-05-31');
      cubit.close();
    });

    test('January: crosses year boundary to December of prior year', () async {
      // Today = Jan 20 2026. Previous month = Dec 2025. from=2025-12-01, to=2025-12-31.
      final cubit =
          EngagementCubit(storage: storage, todayProvider: () => '2026-01-20');
      cubit.load();
      final fake = _FakeLeaderboard(1);
      await cubit.checkMonthlyPrizes(fake.fetchPeriod);
      expect(fake.capturedFrom, '2025-12-01');
      expect(fake.capturedTo, '2025-12-31');
      cubit.close();
    });

    test('March: February last-day is 28 (non-leap 2026)', () async {
      // Today = Mar 01 2026. Previous month = Feb 2026 (28 days, not leap).
      final cubit =
          EngagementCubit(storage: storage, todayProvider: () => '2026-03-01');
      cubit.load();
      final fake = _FakeLeaderboard(1);
      await cubit.checkMonthlyPrizes(fake.fetchPeriod);
      expect(fake.capturedFrom, '2026-02-01');
      expect(fake.capturedTo, '2026-02-28'); // not 29
      cubit.close();
    });

    test('March: February last-day is 29 in a leap year', () async {
      final cubit = EngagementCubit(
        storage: storage,
        todayProvider: () => '2024-03-01',
      )..load();
      final fake = _FakeLeaderboard(1);

      await cubit.checkMonthlyPrizes(fake.fetchPeriod);

      expect(fake.capturedFrom, '2024-02-01');
      expect(fake.capturedTo, '2024-02-29');
      await cubit.close();
    });

    test('May: April last-day is 30 (30-day month)', () async {
      // Today = May 15 2026. Previous month = April (30 days).
      final cubit =
          EngagementCubit(storage: storage, todayProvider: () => '2026-05-15');
      cubit.load();
      final fake = _FakeLeaderboard(1);
      await cubit.checkMonthlyPrizes(fake.fetchPeriod);
      expect(fake.capturedFrom, '2026-04-01');
      expect(fake.capturedTo, '2026-04-30');
      cubit.close();
    });

    test(
        'guard advances each new month so each completed month is checked once',
        () async {
      // First open in June: checks May (guard key = '2026-05').
      final cubita =
          EngagementCubit(storage: storage, todayProvider: () => '2026-06-15');
      cubita.load();
      await cubita.checkMonthlyPrizes(_FakeLeaderboard(1).fetchPeriod);
      cubita.close();

      // Later in June: same month key → no-op.
      final cubitb =
          EngagementCubit(storage: storage, todayProvider: () => '2026-06-28');
      cubitb.load();
      final blockedFake = _FakeLeaderboard(1);
      await cubitb.checkMonthlyPrizes(blockedFake.fetchPeriod);
      expect(blockedFake.capturedFrom, isNull); // never called
      cubitb.close();

      // First open in July: guard changes, now checks June (from=Jun-01, to=Jun-30).
      final cubitc =
          EngagementCubit(storage: storage, todayProvider: () => '2026-07-05');
      cubitc.load();
      final nextFake = _FakeLeaderboard(2);
      await cubitc.checkMonthlyPrizes(nextFake.fetchPeriod);
      expect(nextFake.capturedFrom, '2026-06-01');
      expect(nextFake.capturedTo, '2026-06-30');
      cubitc.close();
    });
  });
}
