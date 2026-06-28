import 'package:connect_merge/application/engagement_cubit.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/leaderboard_entry.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

// Minimal fake leaderboard that returns a preset rank for the caller.
class _FakeLeaderboard {
  final int rank;
  _FakeLeaderboard(this.rank);

  Future<List<LeaderboardEntry>> fetchPeriod({
    required Difficulty difficulty,
    required String from,
    required String to,
  }) async => [
        const LeaderboardEntry(rank: 1, displayName: 'Alice', score: 9000, isMe: false),
        LeaderboardEntry(rank: rank, displayName: 'Me', score: 1000, isMe: true),
      ];
}

void main() {
  late InMemoryStorageService storage;
  late EngagementCubit cubit;

  setUp(() {
    storage = InMemoryStorageService();
    cubit = EngagementCubit(storage: storage, todayProvider: () => '2026-06-23');
    cubit.load();
  });

  tearDown(() => cubit.close());

  test('rank 1 grants 500 coins and records crown', () async {
    final fake = _FakeLeaderboard(1);
    await cubit.checkWeeklyPrizes(fake.fetchPeriod);
    expect(cubit.state.coins, equals(500));
    expect(cubit.state.weeklyPrizes.length, equals(Difficulty.values.where((d) => d != Difficulty.challenge).length));
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
}
