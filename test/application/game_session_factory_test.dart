import 'dart:async';

import 'package:connect_merge/application/engagement_cubit.dart';
import 'package:connect_merge/application/game_cubit.dart';
import 'package:connect_merge/application/game_session_factory.dart';
import 'package:connect_merge/application/game_state.dart';
import 'package:connect_merge/application/loot_cubit.dart';
import 'package:connect_merge/domain/engine/daily_seeder.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/domain/models/move.dart';
import 'package:connect_merge/infrastructure/leaderboard_service.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const date = '2026-07-18';

  test('initializes and runs engagement before afterCompleted', () async {
    final events = <String>[];
    final storage = InMemoryStorageService();
    final engagement = _RecordingEngagementCubit(storage, events);
    final loot = _RecordingLootCubit(storage, events);
    addTearDown(engagement.close);
    addTearDown(loot.close);
    final factory = GameSessionFactory(
      storage: storage,
      engagement: engagement,
      loot: loot,
      todayProvider: () => date,
    );

    final cubit = factory.create(
      difficulty: Difficulty.hard,
      afterCompleted: () async => events.add('after'),
    );
    addTearDown(cubit.close);
    await _waitForInitialized(cubit);
    await cubit.onTierCompleted!(score: 420, highestTier: 7);

    expect(events, ['engagement', 'after']);
    expect(engagement.date, date);
    expect(engagement.score, 420);
    expect(engagement.highestTier, 7);
  });

  test('coins hook ignores zero and refreshes loot after a nonzero write',
      () async {
    final events = <String>[];
    final storage = _BlockingCoinStorage(events);
    final engagement = _RecordingEngagementCubit(storage, events);
    final loot = _RecordingLootCubit(storage, events);
    addTearDown(engagement.close);
    addTearDown(loot.close);
    final cubit = GameSessionFactory(
      storage: storage,
      engagement: engagement,
      loot: loot,
      todayProvider: () => date,
    ).create(difficulty: Difficulty.easy);
    addTearDown(cubit.close);
    await _waitForInitialized(cubit);

    await cubit.onCoinsEarned!(0);
    expect(events, isEmpty);

    final credit = cubit.onCoinsEarned!(9);
    expect(events, ['addCoins:9']);
    storage.releaseAddCoins();
    await credit;

    expect(events, ['addCoins:9', 'loot.load']);
    expect(storage.loadProfile().wallet.coins, 9);
  });

  test('submit hook forwards the replay fields when online', () async {
    String? submittedDate;
    Difficulty? submittedDifficulty;
    List<MoveEvent>? submittedMoves;
    final leaderboard = LeaderboardService.withSeams(
      invoke: (_, body) async {
        submittedDate = body['date'] as String;
        submittedDifficulty =
            Difficulty.values.byName(body['difficulty'] as String);
        submittedMoves = (body['moveLog'] as List)
            .map((entry) =>
                MoveEvent.fromJson(Map<String, dynamic>.from(entry as Map)))
            .toList();
        return {
          'valid': true,
          'score': 1,
          'highestTier': 1,
          'rank': 1,
        };
      },
      rpc: (_, __) async => const [],
    );
    final storage = InMemoryStorageService();
    final engagement = EngagementCubit(storage: storage);
    final loot = LootCubit(storage: storage);
    addTearDown(engagement.close);
    addTearDown(loot.close);
    final cubit = GameSessionFactory(
      storage: storage,
      engagement: engagement,
      loot: loot,
      leaderboard: leaderboard,
      todayProvider: () => date,
    ).create(difficulty: Difficulty.medium);
    addTearDown(cubit.close);
    await _waitForInitialized(cubit);
    const moves = <MoveEvent>[
      MergeEvent(from: 1, to: 2),
      ContinueEvent(),
    ];

    await cubit.onSubmitRun!(
      date: date,
      difficulty: Difficulty.medium,
      moveLog: moves,
      adContinues: 1,
    );

    expect(submittedDate, date);
    expect(submittedDifficulty, Difficulty.medium);
    expect(submittedMoves, moves);
  });

  test('submit hook is null when offline', () async {
    final storage = InMemoryStorageService();
    final engagement = EngagementCubit(storage: storage);
    final loot = LootCubit(storage: storage);
    addTearDown(engagement.close);
    addTearDown(loot.close);
    final cubit = GameSessionFactory(
      storage: storage,
      engagement: engagement,
      loot: loot,
      todayProvider: () => date,
    ).create(difficulty: Difficulty.legendary);
    addTearDown(cubit.close);
    await _waitForInitialized(cubit);

    expect(cubit.onSubmitRun, isNull);
  });

  test('threads analytics and reports swallowed submission errors', () async {
    final storage = InMemoryStorageService();
    final board =
        const DailySeeder(date, Difficulty.easy).generate().board.copyWith(
      status: GameStatus.outOfMoves,
      moveLog: const [MergeEvent(from: 0, to: 1)],
    );
    await storage.saveSnapshot(GameSnapshot(
      date: date,
      difficulty: Difficulty.easy,
      board: board,
      completed: true,
    ));
    final engagement = EngagementCubit(storage: storage);
    final loot = LootCubit(storage: storage);
    addTearDown(engagement.close);
    addTearDown(loot.close);
    Object? reportedError;
    void analytics(String name, [Map<String, Object?>? params]) {}
    final leaderboard = LeaderboardService.withSeams(
      invoke: (_, __) async => throw StateError('submit failed'),
      rpc: (_, __) async => const [],
    );
    final cubit = GameSessionFactory(
      storage: storage,
      engagement: engagement,
      loot: loot,
      leaderboard: leaderboard,
      todayProvider: () => date,
      onError: (error, stack, {fatal = false}) => reportedError = error,
      onAnalyticsEvent: analytics,
    ).create(difficulty: Difficulty.easy);
    addTearDown(cubit.close);
    await _waitForInitialized(cubit);

    expect(cubit.onAnalyticsEvent, same(analytics));
    await cubit.submitIfPending();
    expect(reportedError, isA<StateError>());
  });
}

Future<void> _waitForInitialized(GameCubit cubit) async {
  if (cubit.state is! GameInitial) return;
  await cubit.stream.firstWhere((state) => state is! GameInitial);
}

class _RecordingEngagementCubit extends EngagementCubit {
  final List<String> events;
  String? date;
  int? score;
  int? highestTier;

  _RecordingEngagementCubit(StorageService storage, this.events)
      : super(storage: storage, todayProvider: () => 'unused');

  @override
  Future<void> onTierCompleted({
    String? date,
    int score = 0,
    int highestTier = 0,
  }) async {
    events.add('engagement');
    this.date = date;
    this.score = score;
    this.highestTier = highestTier;
  }
}

class _RecordingLootCubit extends LootCubit {
  final List<String> events;

  _RecordingLootCubit(StorageService storage, this.events)
      : super(storage: storage, todayProvider: () => 'unused');

  @override
  void load() => events.add('loot.load');
}

class _BlockingCoinStorage extends InMemoryStorageService {
  final List<String> events;
  final Completer<void> _release = Completer<void>();

  _BlockingCoinStorage(this.events);

  void releaseAddCoins() => _release.complete();

  @override
  Future<int> addCoins(int delta) async {
    events.add('addCoins:$delta');
    await _release.future;
    return super.addCoins(delta);
  }
}
