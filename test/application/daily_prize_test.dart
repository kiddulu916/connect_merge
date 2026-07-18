import 'package:connect_merge/application/engagement_cubit.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/leaderboard_entry.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FetchCall {
  final Difficulty difficulty;
  final String date;

  const _FetchCall(this.difficulty, this.date);
}

class _FakeLeaderboard {
  final int rank;
  final calls = <_FetchCall>[];

  _FakeLeaderboard(this.rank);

  Future<List<LeaderboardEntry>> fetch({
    required Difficulty difficulty,
    required String date,
  }) async {
    calls.add(_FetchCall(difficulty, date));
    return [
      LeaderboardEntry(
        rank: rank,
        displayName: 'Me',
        score: 1000,
        isMe: true,
      ),
    ];
  }
}

void main() {
  late InMemoryStorageService storage;
  late EngagementCubit cubit;

  setUp(() {
    storage = InMemoryStorageService();
    cubit = EngagementCubit(
      storage: storage,
      todayProvider: () => '2026-06-23',
    )..load();
  });

  tearDown(() => cubit.close());

  test('rank 1 pays once and persists yesterday guard', () async {
    final fake = _FakeLeaderboard(1);

    await cubit.checkDailyPrizes(fake.fetch);

    expect(cubit.state.coins, 50);
    expect(storage.loadProfile().coins, 50);
    expect(storage.loadProfile().lastDailyPrizeDate, '2026-06-22');
  });

  test('same-day guard prevents a second fetch and payout', () async {
    final fake = _FakeLeaderboard(1);

    await cubit.checkDailyPrizes(fake.fetch);
    final callsAfterFirstCheck = fake.calls.length;
    await cubit.checkDailyPrizes(fake.fetch);

    expect(fake.calls, hasLength(callsAfterFirstCheck));
    expect(cubit.state.coins, 50);
  });

  test('fetches every non-challenge tier for yesterday', () async {
    final fake = _FakeLeaderboard(4);

    await cubit.checkDailyPrizes(fake.fetch);

    expect(
      fake.calls.map((call) => call.difficulty),
      Difficulty.values.where((value) => value != Difficulty.challenge),
    );
    expect(fake.calls.map((call) => call.date), everyElement('2026-06-22'));
  });

  test('future guard blocks clock-rollback fetch and payment', () async {
    await storage.saveProfile(const PlayerProfile(
      coins: 75,
      lastDailyPrizeDate: '2026-06-23',
    ));
    cubit.load();
    final fake = _FakeLeaderboard(1);

    await cubit.checkDailyPrizes(fake.fetch);

    expect(fake.calls, isEmpty);
    expect(storage.loadProfile().lastDailyPrizeDate, '2026-06-23');
    expect(storage.loadProfile().coins, 75);
    expect(cubit.state.coins, 75);
  });
}
