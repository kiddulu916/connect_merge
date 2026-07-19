import 'package:connect_merge/application/engagement_cubit.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _PeriodRanks {
  final int rank;
  final calls = <(String, String)>[];
  String? failFrom;

  _PeriodRanks(this.rank);

  Future<Map<Difficulty, int>> fetch({
    required String from,
    required String to,
  }) async {
    calls.add((from, to));
    if (from == failFrom) throw StateError('network down');
    return {
      for (final difficulty in Difficulty.values)
        if (difficulty != Difficulty.challenge) difficulty: rank,
    };
  }
}

class _TrackingStorage extends InMemoryStorageService {
  final weeklyGuards = <String>[];

  @override
  Future<void> saveProfile(PlayerProfile profile) async {
    await super.saveProfile(profile);
    final guard = profile.prizes.lastWeeklyPrizeDate;
    if (guard != null) weeklyGuards.add(guard);
  }
}

void main() {
  Future<(int, int)> payoutFor(int rank) async {
    final storage = InMemoryStorageService();
    final cubit = EngagementCubit(
      storage: storage,
      todayProvider: () => '2026-06-24',
    )..load();
    addTearDown(cubit.close);
    await cubit.checkWeeklyPrizes(_PeriodRanks(rank).fetch);
    return (cubit.state.coins, cubit.state.weeklyPrizes.length);
  }

  test('top-five weekly payout boundaries and crowns', () async {
    expect(await payoutFor(1), (75, 4));
    expect(await payoutFor(2), (45, 4));
    expect(await payoutFor(3), (25, 4));
    expect(await payoutFor(4), (15, 4));
    expect(await payoutFor(5), (10, 4));
    expect(await payoutFor(6), (0, 0));
  });

  test('best qualifying tier pays once and each qualifying tier gets a crown',
      () async {
    final storage = InMemoryStorageService();
    final cubit = EngagementCubit(
      storage: storage,
      todayProvider: () => '2026-06-24',
    )..load();
    addTearDown(cubit.close);

    await cubit.checkWeeklyPrizes(({
      required String from,
      required String to,
    }) async =>
        {
          Difficulty.easy: 6,
          Difficulty.medium: 5,
          Difficulty.hard: 1,
          Difficulty.legendary: 4,
        });

    expect(cubit.state.coins, 75);
    expect(
      cubit.state.weeklyPrizes.map((prize) => prize.tier).toSet(),
      {Difficulty.medium, Difficulty.hard, Difficulty.legendary},
    );
  });

  test('null guard checks only the most recent completed week', () async {
    final storage = InMemoryStorageService();
    final cubit = EngagementCubit(
      storage: storage,
      todayProvider: () => '2026-06-24',
    )..load();
    addTearDown(cubit.close);
    final fake = _PeriodRanks(6);

    await cubit.checkWeeklyPrizes(fake.fetch);

    expect(fake.calls, [('2026-06-15', '2026-06-21')]);
    expect(storage.loadProfile().prizes.lastWeeklyPrizeDate, '2026-06-15');
  });

  test('gap processes oldest-first and is bounded to four weeks', () async {
    final storage = _TrackingStorage();
    await storage.saveProfile(const PlayerProfile(
      prizes: PrizeLedger(lastWeeklyPrizeDate: '2026-01-05'),
    ));
    storage.weeklyGuards.clear();
    final cubit = EngagementCubit(
      storage: storage,
      todayProvider: () => '2026-06-24',
    )..load();
    addTearDown(cubit.close);
    final fake = _PeriodRanks(5);

    await cubit.checkWeeklyPrizes(fake.fetch);

    expect(fake.calls, [
      ('2026-05-25', '2026-05-31'),
      ('2026-06-01', '2026-06-07'),
      ('2026-06-08', '2026-06-14'),
      ('2026-06-15', '2026-06-21'),
    ]);
    expect(storage.weeklyGuards,
        ['2026-05-25', '2026-06-01', '2026-06-08', '2026-06-15']);
    expect(cubit.state.coins, 40);
  });

  test('mid-window failure halts guard advancement and retries from the gap',
      () async {
    final storage = _TrackingStorage();
    await storage.saveProfile(const PlayerProfile(
      prizes: PrizeLedger(lastWeeklyPrizeDate: '2026-05-18'),
    ));
    storage.weeklyGuards.clear();
    final cubit = EngagementCubit(
      storage: storage,
      todayProvider: () => '2026-06-24',
    )..load();
    addTearDown(cubit.close);
    final fake = _PeriodRanks(5)..failFrom = '2026-06-08';

    await cubit.checkWeeklyPrizes(fake.fetch);

    expect(fake.calls, [
      ('2026-05-25', '2026-05-31'),
      ('2026-06-01', '2026-06-07'),
      ('2026-06-08', '2026-06-14'),
    ]);
    expect(storage.loadProfile().prizes.lastWeeklyPrizeDate, '2026-06-01');

    fake
      ..calls.clear()
      ..failFrom = null;
    await cubit.checkWeeklyPrizes(fake.fetch);

    expect(fake.calls, [
      ('2026-06-08', '2026-06-14'),
      ('2026-06-15', '2026-06-21'),
    ]);
    expect(storage.loadProfile().prizes.lastWeeklyPrizeDate, '2026-06-15');
  });

  group('previous completed week range', () {
    Future<(String, String)> rangeFor(String today) async {
      final storage = InMemoryStorageService();
      final cubit = EngagementCubit(
        storage: storage,
        todayProvider: () => today,
      )..load();
      addTearDown(cubit.close);
      final fake = _PeriodRanks(6);
      await cubit.checkWeeklyPrizes(fake.fetch);
      return fake.calls.single;
    }

    test('Monday and Tuesday use the prior Monday-Sunday', () async {
      expect(await rangeFor('2026-06-22'), ('2026-06-15', '2026-06-21'));
      expect(await rangeFor('2026-06-23'), ('2026-06-15', '2026-06-21'));
    });

    test('Sunday excludes the week that has not closed yet', () async {
      expect(await rangeFor('2026-06-21'), ('2026-06-08', '2026-06-14'));
    });

    test('crosses month and year boundaries', () async {
      expect(await rangeFor('2026-06-02'), ('2026-05-25', '2026-05-31'));
      expect(await rangeFor('2026-01-02'), ('2025-12-22', '2025-12-28'));
    });
  });
}
