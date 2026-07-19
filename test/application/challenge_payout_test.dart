import 'package:connect_merge/application/engagement_cubit.dart';
import 'package:connect_merge/domain/date_utils.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Map<String, Map<Difficulty, int>>> _ranks(
  int rank, {
  required String from,
  required String to,
}) async {
  final result = <String, Map<Difficulty, int>>{};
  var day = parseUtcDate(from);
  final end = parseUtcDate(to);
  while (!day.isAfter(end)) {
    result[formatDate(day)] = {Difficulty.challenge: rank};
    day = DateTime.utc(day.year, day.month, day.day + 1);
  }
  return result;
}

void main() {
  Future<int> payoutFor(int rank) async {
    final storage = InMemoryStorageService();
    final cubit = EngagementCubit(
      storage: storage,
      todayProvider: () => '2026-06-23',
    )..load();
    addTearDown(cubit.close);
    await cubit.checkChallengePayouts(({
      required String from,
      required String to,
    }) =>
        _ranks(rank, from: from, to: to));
    return cubit.state.coins;
  }

  test('broad-and-shallow payout boundaries', () async {
    expect(await payoutFor(1), 20);
    expect(await payoutFor(2), 15);
    expect(await payoutFor(3), 15);
    expect(await payoutFor(4), 10);
    expect(await payoutFor(6), 10);
    expect(await payoutFor(7), 5);
    expect(await payoutFor(10), 5);
    expect(await payoutFor(11), 0);
    expect(await payoutFor(0), 0);
  });

  test('null guard checks only yesterday and stamps a zero payout', () async {
    final storage = InMemoryStorageService();
    final cubit = EngagementCubit(
      storage: storage,
      todayProvider: () => '2026-06-23',
    )..load();
    addTearDown(cubit.close);
    (String, String)? call;

    await cubit.checkChallengePayouts(({
      required String from,
      required String to,
    }) async {
      call = (from, to);
      return _ranks(11, from: from, to: to);
    });

    expect(call, ('2026-06-22', '2026-06-22'));
    expect(storage.loadProfile().prizes.lastChallengeCheckDate, '2026-06-22');
  });

  test('catch-up is bounded to seven closed days', () async {
    final storage = InMemoryStorageService();
    await storage.saveProfile(const PlayerProfile(
      prizes: PrizeLedger(lastChallengeCheckDate: '2026-05-01'),
    ));
    final cubit = EngagementCubit(
      storage: storage,
      todayProvider: () => '2026-06-23',
    )..load();
    addTearDown(cubit.close);
    (String, String)? call;

    await cubit.checkChallengePayouts(({
      required String from,
      required String to,
    }) async {
      call = (from, to);
      return _ranks(10, from: from, to: to);
    });

    expect(call, ('2026-06-16', '2026-06-22'));
    expect(cubit.state.coins, 35);
    expect(storage.loadProfile().prizes.lastChallengeCheckDate, '2026-06-22');
  });
}
