import 'package:connect_merge/application/engagement_cubit.dart';
import 'package:connect_merge/domain/date_utils.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _TrackingStorage extends InMemoryStorageService {
  final dailyGuards = <String>[];

  @override
  Future<void> saveProfile(PlayerProfile profile) async {
    await super.saveProfile(profile);
    final guard = profile.prizes.lastDailyPrizeDate;
    if (guard != null) dailyGuards.add(guard);
  }
}

class _DailyRanks {
  final int rank;
  final calls = <(String, String)>[];
  bool fail = false;

  _DailyRanks(this.rank);

  Future<Map<String, Map<Difficulty, int>>> fetch({
    required String from,
    required String to,
  }) async {
    calls.add((from, to));
    if (fail) throw StateError('network down');
    final result = <String, Map<Difficulty, int>>{};
    var day = parseUtcDate(from);
    final end = parseUtcDate(to);
    while (!day.isAfter(end)) {
      result[formatDate(day)] = {Difficulty.easy: rank};
      day = DateTime.utc(day.year, day.month, day.day + 1);
    }
    return result;
  }
}

void main() {
  late _TrackingStorage storage;
  late EngagementCubit cubit;

  setUp(() {
    storage = _TrackingStorage();
    cubit = EngagementCubit(
      storage: storage,
      todayProvider: () => '2026-06-23',
    )..load();
  });

  tearDown(() => cubit.close());

  test('rank 1 pays once and a null guard checks only yesterday', () async {
    final fake = _DailyRanks(1);

    await cubit.checkDailyPrizes(fake.fetch);

    expect(fake.calls, [('2026-06-22', '2026-06-22')]);
    expect(cubit.state.coins, 50);
    expect(storage.loadProfile().wallet.coins, 50);
    expect(storage.loadProfile().prizes.lastDailyPrizeDate, '2026-06-22');
  });

  test('rank 5 pays 5 coins and rank 6 pays nothing', () async {
    await cubit.checkDailyPrizes(_DailyRanks(5).fetch);
    expect(cubit.state.coins, 5);

    final otherStorage = InMemoryStorageService();
    final other = EngagementCubit(
      storage: otherStorage,
      todayProvider: () => '2026-06-23',
    )..load();
    addTearDown(other.close);
    await other.checkDailyPrizes(_DailyRanks(6).fetch);
    expect(other.state.coins, 0);
  });

  test('best qualifying tier pays once per day', () async {
    await cubit.checkDailyPrizes(({
      required String from,
      required String to,
    }) async =>
        {
          '2026-06-22': {
            Difficulty.easy: 5,
            Difficulty.medium: 2,
            Difficulty.hard: 4,
          },
        });

    expect(cubit.state.coins, 30);
  });

  test('gap is processed once per day oldest-first', () async {
    await storage.saveProfile(const PlayerProfile(
      prizes: PrizeLedger(lastDailyPrizeDate: '2026-06-18'),
    ));
    storage.dailyGuards.clear();
    cubit.load();

    await cubit.checkDailyPrizes(_DailyRanks(5).fetch);

    expect(storage.dailyGuards,
        ['2026-06-19', '2026-06-20', '2026-06-21', '2026-06-22']);
    expect(cubit.state.coins, 20);
  });

  test('catch-up is bounded to the seven most recent closed days', () async {
    await storage.saveProfile(const PlayerProfile(
      prizes: PrizeLedger(lastDailyPrizeDate: '2026-05-01'),
    ));
    storage.dailyGuards.clear();
    cubit.load();
    final fake = _DailyRanks(5);

    await cubit.checkDailyPrizes(fake.fetch);

    expect(fake.calls, [('2026-06-16', '2026-06-22')]);
    expect(storage.dailyGuards, hasLength(7));
    expect(storage.dailyGuards.first, '2026-06-16');
    expect(storage.dailyGuards.last, '2026-06-22');
    expect(cubit.state.coins, 35);
  });

  test('failed range fetch leaves the guard for a healthy retry', () async {
    final fake = _DailyRanks(1)..fail = true;

    await cubit.checkDailyPrizes(fake.fetch);
    expect(storage.loadProfile().prizes.lastDailyPrizeDate, isNull);

    fake.fail = false;
    await cubit.checkDailyPrizes(fake.fetch);
    expect(storage.loadProfile().prizes.lastDailyPrizeDate, '2026-06-22');
    expect(cubit.state.coins, 50);
  });

  test('same-day and future guards prevent another fetch or payout', () async {
    await storage.saveProfile(const PlayerProfile(
      wallet: Wallet(coins: 75),
      prizes: PrizeLedger(lastDailyPrizeDate: '2026-06-23'),
    ));
    cubit.load();
    final fake = _DailyRanks(1);

    await cubit.checkDailyPrizes(fake.fetch);

    expect(fake.calls, isEmpty);
    expect(cubit.state.coins, 75);
  });
}
