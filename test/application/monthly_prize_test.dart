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
    return {Difficulty.easy: rank};
  }
}

void main() {
  Future<int> payoutFor(int rank) async {
    final storage = InMemoryStorageService();
    final cubit = EngagementCubit(
      storage: storage,
      todayProvider: () => '2026-06-15',
    )..load();
    addTearDown(cubit.close);
    await cubit.checkMonthlyPrizes(_PeriodRanks(rank).fetch);
    return cubit.state.coins;
  }

  test('top-five monthly payout boundaries', () async {
    expect(await payoutFor(1), 100);
    expect(await payoutFor(2), 60);
    expect(await payoutFor(3), 35);
    expect(await payoutFor(4), 20);
    expect(await payoutFor(5), 15);
    expect(await payoutFor(6), 0);
  });

  test('null guard checks only the most recent completed month', () async {
    final storage = InMemoryStorageService();
    final cubit = EngagementCubit(
      storage: storage,
      todayProvider: () => '2026-06-15',
    )..load();
    addTearDown(cubit.close);
    final fake = _PeriodRanks(6);

    await cubit.checkMonthlyPrizes(fake.fetch);

    expect(fake.calls, [('2026-05-01', '2026-05-31')]);
    expect(storage.loadProfile().prizes.lastMonthlyPrizeMonth, '2026-05');
  });

  test('catch-up is oldest-first and bounded to two months', () async {
    final storage = InMemoryStorageService();
    await storage.saveProfile(const PlayerProfile(
      prizes: PrizeLedger(lastMonthlyPrizeMonth: '2025-01'),
    ));
    final cubit = EngagementCubit(
      storage: storage,
      todayProvider: () => '2026-07-15',
    )..load();
    addTearDown(cubit.close);
    final fake = _PeriodRanks(5);

    await cubit.checkMonthlyPrizes(fake.fetch);

    expect(fake.calls, [
      ('2026-05-01', '2026-05-31'),
      ('2026-06-01', '2026-06-30'),
    ]);
    expect(cubit.state.coins, 30);
    expect(storage.loadProfile().prizes.lastMonthlyPrizeMonth, '2026-06');
  });

  test('mid-window failure halts and retries the failed month', () async {
    final storage = InMemoryStorageService();
    await storage.saveProfile(const PlayerProfile(
      prizes: PrizeLedger(lastMonthlyPrizeMonth: '2026-04'),
    ));
    final cubit = EngagementCubit(
      storage: storage,
      todayProvider: () => '2026-07-15',
    )..load();
    addTearDown(cubit.close);
    final fake = _PeriodRanks(5)..failFrom = '2026-06-01';

    await cubit.checkMonthlyPrizes(fake.fetch);

    expect(fake.calls, [
      ('2026-05-01', '2026-05-31'),
      ('2026-06-01', '2026-06-30'),
    ]);
    expect(storage.loadProfile().prizes.lastMonthlyPrizeMonth, '2026-05');

    fake
      ..calls.clear()
      ..failFrom = null;
    await cubit.checkMonthlyPrizes(fake.fetch);
    expect(fake.calls, [('2026-06-01', '2026-06-30')]);
    expect(storage.loadProfile().prizes.lastMonthlyPrizeMonth, '2026-06');
  });

  group('previous completed month range', () {
    Future<(String, String)> rangeFor(String today) async {
      final storage = InMemoryStorageService();
      final cubit = EngagementCubit(
        storage: storage,
        todayProvider: () => today,
      )..load();
      addTearDown(cubit.close);
      final fake = _PeriodRanks(6);
      await cubit.checkMonthlyPrizes(fake.fetch);
      return fake.calls.single;
    }

    test('covers ordinary, year-boundary, and leap months', () async {
      expect(await rangeFor('2026-06-15'), ('2026-05-01', '2026-05-31'));
      expect(await rangeFor('2026-01-20'), ('2025-12-01', '2025-12-31'));
      expect(await rangeFor('2026-03-01'), ('2026-02-01', '2026-02-28'));
      expect(await rangeFor('2024-03-01'), ('2024-02-01', '2024-02-29'));
      expect(await rangeFor('2026-05-15'), ('2026-04-01', '2026-04-30'));
    });
  });
}
