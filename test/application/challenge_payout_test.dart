import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/application/engagement_cubit.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/leaderboard_entry.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';

LeaderboardEntry _entry(int rank, bool isMe) =>
    LeaderboardEntry(rank: rank, displayName: 'P', score: 100, isMe: isMe);

void main() {
  late InMemoryStorageService storage;
  late EngagementCubit cubit;
  // 'today' = 2026-06-23; 'yesterday' = 2026-06-22
  const today = '2026-06-23';

  setUp(() {
    storage = InMemoryStorageService();
    cubit = EngagementCubit(storage: storage, todayProvider: () => today);
    cubit.load();
  });

  tearDown(() => cubit.close());

  Future<List<LeaderboardEntry>> fakeFetch(int rank) async => [
        _entry(1, false),
        _entry(rank, true),
      ];

  test('rank 1 grants 150 coins', () async {
    await cubit.checkChallengePayouts(
        ({required Difficulty difficulty, required String date}) =>
            fakeFetch(1));
    expect(cubit.state.coins, equals(150));
  });

  test('rank 2 grants 100 coins', () async {
    await cubit.checkChallengePayouts(
        ({required Difficulty difficulty, required String date}) =>
            fakeFetch(2));
    expect(cubit.state.coins, equals(100));
  });

  test('rank 10 grants 50 coins', () async {
    await cubit.checkChallengePayouts(
        ({required Difficulty difficulty, required String date}) =>
            fakeFetch(10));
    expect(cubit.state.coins, equals(50));
  });

  test('rank 11 grants nothing', () async {
    await cubit.checkChallengePayouts(
        ({required Difficulty difficulty, required String date}) =>
            fakeFetch(11));
    expect(cubit.state.coins, equals(0));
  });

  test('second call same day is a no-op', () async {
    await cubit.checkChallengePayouts(
        ({required Difficulty difficulty, required String date}) =>
            fakeFetch(1));
    await cubit.checkChallengePayouts(
        ({required Difficulty difficulty, required String date}) =>
            fakeFetch(1));
    expect(cubit.state.coins, equals(150)); // not 300
  });
}
