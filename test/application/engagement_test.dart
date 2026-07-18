import 'dart:async';

import 'package:connect_merge/application/engagement_cubit.dart';
import 'package:connect_merge/domain/models/achievement.dart';
import 'package:connect_merge/domain/models/cosmetic.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/leaderboard_entry.dart';
import 'package:connect_merge/domain/models/streak.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _DelayedDailySaveStorage extends InMemoryStorageService {
  final dailySaveStarted = Completer<void>();
  final releaseDailySave = Completer<void>();
  var _delayed = false;

  @override
  Future<void> saveProfile(PlayerProfile profile) async {
    if (!_delayed && profile.prizes.lastDailyPrizeDate != null) {
      _delayed = true;
      dailySaveStarted.complete();
      await releaseDailySave.future;
    }
    await super.saveProfile(profile);
  }
}

class _ThrowBeforeWriteStorage extends InMemoryStorageService {
  bool failBeforeWrite = true;

  @override
  Future<void> saveProfile(PlayerProfile profile) async {
    if (failBeforeWrite) throw StateError('save failed before write');
    await super.saveProfile(profile);
  }
}

class _WriteThenThrowStorage extends InMemoryStorageService {
  bool throwAfterWrite = true;

  @override
  Future<void> saveProfile(PlayerProfile profile) async {
    await super.saveProfile(profile);
    if (throwAfterWrite) {
      throwAfterWrite = false;
      throw StateError('save failed after write');
    }
  }
}

Future<List<LeaderboardEntry>> _rankOneDaily({
  required Difficulty difficulty,
  required String date,
}) async =>
    const [
      LeaderboardEntry(
        rank: 1,
        displayName: 'Me',
        score: 1000,
        isMe: true,
      ),
    ];

Future<List<LeaderboardEntry>> _rankOnePeriod({
  required Difficulty difficulty,
  required String from,
  required String to,
}) async =>
    const [
      LeaderboardEntry(
        rank: 1,
        displayName: 'Me',
        score: 1000,
        isMe: true,
      ),
    ];

void main() {
  group('nextStreak (pure)', () {
    test('previousUtcDay crosses a year boundary', () {
      expect(previousUtcDay('2026-01-01'), '2025-12-31');
    });

    test('previousUtcDay returns leap day', () {
      expect(previousUtcDay('2024-03-01'), '2024-02-29');
    });

    test('last == yesterday -> +1, no freeze consumed', () {
      final r = nextStreak(
          prev: 3, last: '2026-06-06', today: '2026-06-07', hasFreeze: false);
      expect(r, const StreakResult(streak: 4, freezeConsumed: false));
    });

    test('last == today -> unchanged (idempotent)', () {
      final r = nextStreak(
          prev: 5, last: '2026-06-07', today: '2026-06-07', hasFreeze: true);
      expect(r, const StreakResult(streak: 5, freezeConsumed: false));
    });

    test('first ever completion (last == null) -> 1', () {
      final r = nextStreak(
          prev: 0, last: null, today: '2026-06-07', hasFreeze: false);
      expect(r, const StreakResult(streak: 1, freezeConsumed: false));
    });

    test('gap with NO freeze -> reset to 1', () {
      final r = nextStreak(
          prev: 9, last: '2026-06-01', today: '2026-06-07', hasFreeze: false);
      expect(r, const StreakResult(streak: 1, freezeConsumed: false));
    });

    test('gap WITH freeze -> keep+advance, token consumed', () {
      final r = nextStreak(
          prev: 9, last: '2026-06-01', today: '2026-06-07', hasFreeze: true);
      expect(r, const StreakResult(streak: 10, freezeConsumed: true));
    });
  });

  group('EngagementCubit completion hook', () {
    late InMemoryStorageService storage;
    EngagementCubit make() =>
        EngagementCubit(storage: storage, todayProvider: () => '2026-06-07');

    setUp(() => storage = InMemoryStorageService());

    test('first completion sets headline streak to 1 and persists', () async {
      final c = make()..load();
      await c.onTierCompleted();
      expect(c.state.dailyActiveStreak, 1);
      expect(c.state.lastActiveDate, '2026-06-07');
      expect(storage.loadProfile().activity.dailyActiveStreak, 1);
    });

    test('consecutive day increments the headline streak', () async {
      await storage.saveProfile(const PlayerProfile(
        activity: ActivityStreak(
          dailyActiveStreak: 4,
          lastActiveDate: '2026-06-06',
        ),
      ));
      final c = make()..load();
      await c.onTierCompleted();
      expect(c.state.dailyActiveStreak, 5);
    });

    test('same-day re-completion is idempotent', () async {
      await storage.saveProfile(const PlayerProfile(
        activity: ActivityStreak(
          dailyActiveStreak: 4,
          lastActiveDate: '2026-06-07',
        ),
      ));
      final c = make()..load();
      await c.onTierCompleted();
      expect(c.state.dailyActiveStreak, 4);
    });

    test('gap with a banked freeze token keeps the streak + consumes a token',
        () async {
      await storage.saveProfile(const PlayerProfile(
        activity: ActivityStreak(
          dailyActiveStreak: 8,
          lastActiveDate: '2026-06-01',
        ),
      ));
      // Bank a freeze token on the easy tier.
      await storage.saveStats(
          Difficulty.easy,
          const LifetimeStats(
              streak: 0,
              lastCompletedDate: null,
              bestScore: 0,
              bestTier: 0,
              streakFreezeTokens: 1));
      final c = make()..load();
      expect(c.state.freezeTokens, 1);

      await c.onTierCompleted();
      // Streak bridged (advanced) rather than reset.
      expect(c.state.dailyActiveStreak, 9);
      // Token consumed.
      expect(storage.loadStats(Difficulty.easy).streakFreezeTokens, 0);
      expect(c.state.freezeTokens, 0);
    });

    test(
        'a genuine gap with NO freeze token fires streak_broken with the pre-reset length',
        () async {
      await storage.saveProfile(const PlayerProfile(
        activity: ActivityStreak(
          dailyActiveStreak: 8,
          lastActiveDate: '2026-06-01',
        ),
      ));
      final events = <MapEntry<String, Map<String, Object?>?>>[];
      final c = EngagementCubit(
        storage: storage,
        todayProvider: () => '2026-06-07',
        onAnalyticsEvent: (name, [params]) =>
            events.add(MapEntry(name, params)),
      )..load();
      await c.onTierCompleted();

      expect(c.state.dailyActiveStreak, 1); // reset, no freeze available
      final broken = events.where((e) => e.key == 'streak_broken').toList();
      expect(broken, hasLength(1));
      expect(broken.single.value, {'streakType': 'daily', 'length': 8});
    });

    test('a gap bridged by a freeze token does NOT fire streak_broken',
        () async {
      await storage.saveProfile(const PlayerProfile(
        activity: ActivityStreak(
          dailyActiveStreak: 8,
          lastActiveDate: '2026-06-01',
        ),
      ));
      await storage.saveStats(
          Difficulty.easy,
          const LifetimeStats(
              streak: 0,
              lastCompletedDate: null,
              bestScore: 0,
              bestTier: 0,
              streakFreezeTokens: 1));
      final events = <MapEntry<String, Map<String, Object?>?>>[];
      final c = EngagementCubit(
        storage: storage,
        todayProvider: () => '2026-06-07',
        onAnalyticsEvent: (name, [params]) =>
            events.add(MapEntry(name, params)),
      )..load();
      await c.onTierCompleted();

      expect(events.where((e) => e.key == 'streak_broken'), isEmpty);
    });

    test('consecutive-day completion does NOT fire streak_broken', () async {
      await storage.saveProfile(const PlayerProfile(
        activity: ActivityStreak(
          dailyActiveStreak: 4,
          lastActiveDate: '2026-06-06',
        ),
      ));
      final events = <MapEntry<String, Map<String, Object?>?>>[];
      final c = EngagementCubit(
        storage: storage,
        todayProvider: () => '2026-06-07',
        onAnalyticsEvent: (name, [params]) =>
            events.add(MapEntry(name, params)),
      )..load();
      await c.onTierCompleted();

      expect(events.where((e) => e.key == 'streak_broken'), isEmpty);
    });

    test('first-ever completion does NOT fire streak_broken', () async {
      final events = <MapEntry<String, Map<String, Object?>?>>[];
      final c = EngagementCubit(
        storage: storage,
        todayProvider: () => '2026-06-07',
        onAnalyticsEvent: (name, [params]) =>
            events.add(MapEntry(name, params)),
      )..load();
      await c.onTierCompleted();

      expect(events.where((e) => e.key == 'streak_broken'), isEmpty);
    });

    test('onError fires when checkDailyPrizes\' fetch throws', () async {
      Object? capturedError;
      final c = EngagementCubit(
        storage: storage,
        todayProvider: () => '2026-06-07',
        onError: (error, stack, {fatal = false}) => capturedError = error,
      )..load();

      await c.checkDailyPrizes(
        ({required difficulty, required date}) async =>
            throw StateError('network down'),
      );

      expect(capturedError, isA<StateError>());
    });

    test('gap with NO freeze resets the streak to 1', () async {
      await storage.saveProfile(const PlayerProfile(
        activity: ActivityStreak(
          dailyActiveStreak: 8,
          lastActiveDate: '2026-06-01',
        ),
      ));
      final c = make()..load();
      await c.onTierCompleted();
      expect(c.state.dailyActiveStreak, 1);
    });

    test('reaching 7-day streak unlocks sevenDayStreak + surfaces it once',
        () async {
      await storage.saveProfile(const PlayerProfile(
        activity: ActivityStreak(
          dailyActiveStreak: 6,
          lastActiveDate: '2026-06-06',
        ),
      ));
      final c = make()..load();
      await c.onTierCompleted();
      expect(c.state.dailyActiveStreak, 7);
      expect(c.state.unlocked, contains(Achievement.sevenDayStreak));
      expect(c.state.newlyUnlocked, contains(Achievement.sevenDayStreak));

      c.acknowledgeNewlyUnlocked();
      expect(c.state.newlyUnlocked, isEmpty);
      // Persisted.
      expect(storage.loadProfile().progression.unlockedAchievements,
          contains(Achievement.sevenDayStreak.name));
    });

    test('streak unlocks the ocean cosmetic at 3 days', () async {
      await storage.saveProfile(const PlayerProfile(
        activity: ActivityStreak(
          dailyActiveStreak: 2,
          lastActiveDate: '2026-06-06',
        ),
      ));
      final c = make()..load();
      await c.onTierCompleted(); // -> 3
      expect(c.state.unlockedCosmetics, contains(Cosmetic.ocean));
    });
  });

  group('EngagementCubit cosmetics + freeze grants', () {
    late InMemoryStorageService storage;
    EngagementCubit make() =>
        EngagementCubit(storage: storage, todayProvider: () => '2026-06-07');
    setUp(() => storage = InMemoryStorageService());

    test('selecting a locked cosmetic is a no-op', () async {
      final c = make()..load();
      await c.selectCosmetic(Cosmetic.sunset); // not unlocked
      expect(c.state.selectedCosmetic, Cosmetic.classic);
    });

    test('selecting an unlocked cosmetic persists the choice', () async {
      final c = make()..load();
      await c.selectCosmetic(Cosmetic.classic);
      expect(c.state.selectedCosmetic, Cosmetic.classic);
      expect(storage.loadProfile().cosmetics.selectedCosmetic, 'classic');
    });

    test('grantAdCosmetic unlocks a rewarded cosmetic; then selectable',
        () async {
      final c = make()..load();
      expect(c.state.unlockedCosmetics, isNot(contains(Cosmetic.neon)));
      await c.grantAdCosmetic(Cosmetic.neon);
      expect(c.state.unlockedCosmetics, contains(Cosmetic.neon));
      await c.selectCosmetic(Cosmetic.neon);
      expect(c.state.selectedCosmetic, Cosmetic.neon);
    });

    test('grantFreezeToken banks up to the cap per tier', () async {
      final c = make()..load();
      expect(await c.grantFreezeToken(), isTrue);
      expect(c.state.freezeTokens, 1);
      for (final d in Difficulty.values) {
        expect(storage.loadStats(d).streakFreezeTokens, 1);
      }
    });
  });

  group('prize commit serialization and failures', () {
    test('concurrent checks retain every guard payout and crown', () async {
      final storage = _DelayedDailySaveStorage();
      final cubit = EngagementCubit(
        storage: storage,
        todayProvider: () => '2026-06-24',
      )..load();
      addTearDown(cubit.close);

      final daily = cubit.checkDailyPrizes(_rankOneDaily);
      final weekly = cubit.checkWeeklyPrizes(_rankOnePeriod);
      final monthly = cubit.checkMonthlyPrizes(_rankOnePeriod);
      final challenge = cubit.checkChallengePayouts(_rankOneDaily);

      await storage.dailySaveStarted.future;
      await Future<void>.delayed(Duration.zero);
      storage.releaseDailySave.complete();
      await Future.wait([daily, weekly, monthly, challenge]);

      final profile = storage.loadProfile();
      expect(profile.prizes.lastDailyPrizeDate, '2026-06-23');
      expect(profile.prizes.lastWeeklyPrizeDate, '2026-06-15');
      expect(profile.prizes.lastMonthlyPrizeMonth, '2026-05');
      expect(profile.prizes.lastChallengeCheckDate, '2026-06-23');
      expect(profile.wallet.coins, 2700);
      expect(profile.prizes.weeklyPrizes, hasLength(4));
      expect(cubit.state.coins, 2700);
      expect(cubit.state.weeklyPrizes, hasLength(4));
    });

    test('pre-write failure reports without emit and does not poison retries',
        () async {
      final storage = _ThrowBeforeWriteStorage();
      final errors = <Object>[];
      final cubit = EngagementCubit(
        storage: storage,
        todayProvider: () => '2026-06-24',
        onError: (error, stack, {fatal = false}) => errors.add(error),
      )..load();
      addTearDown(cubit.close);
      final emitted = <EngagementState>[];
      final subscription = cubit.stream.listen(emitted.add);
      addTearDown(subscription.cancel);

      await cubit.checkDailyPrizes(_rankOneDaily);
      await Future<void>.delayed(Duration.zero);

      expect(errors, hasLength(1));
      expect(storage.loadProfile().prizes.lastDailyPrizeDate, isNull);
      expect(storage.loadProfile().wallet.coins, 0);
      expect(emitted, isEmpty);

      storage.failBeforeWrite = false;
      await cubit.checkWeeklyPrizes(_rankOnePeriod);
      await cubit.checkDailyPrizes(_rankOneDaily);

      expect(storage.loadProfile().prizes.lastWeeklyPrizeDate, '2026-06-15');
      expect(storage.loadProfile().prizes.lastDailyPrizeDate, '2026-06-23');
      expect(storage.loadProfile().wallet.coins, 550);
      expect(cubit.state.coins, 550);
    });

    test('write-then-throw reconciles crowns and retry cannot pay twice',
        () async {
      final storage = _WriteThenThrowStorage();
      final errors = <Object>[];
      final cubit = EngagementCubit(
        storage: storage,
        todayProvider: () => '2026-06-24',
        onError: (error, stack, {fatal = false}) => errors.add(error),
      )..load();
      addTearDown(cubit.close);
      final emitted = <EngagementState>[];
      final subscription = cubit.stream.listen(emitted.add);
      addTearDown(subscription.cancel);
      var fetches = 0;
      Future<List<LeaderboardEntry>> fetch({
        required Difficulty difficulty,
        required String from,
        required String to,
      }) {
        fetches++;
        return _rankOnePeriod(difficulty: difficulty, from: from, to: to);
      }

      await cubit.checkWeeklyPrizes(fetch);
      await Future<void>.delayed(Duration.zero);

      expect(errors, hasLength(1));
      expect(storage.loadProfile().prizes.lastWeeklyPrizeDate, '2026-06-15');
      expect(storage.loadProfile().wallet.coins, 500);
      expect(storage.loadProfile().prizes.weeklyPrizes, hasLength(4));
      expect(cubit.state.coins, 500);
      expect(cubit.state.weeklyPrizes, hasLength(4));
      expect(emitted, hasLength(1));

      await cubit.checkWeeklyPrizes(fetch);

      expect(fetches, 4);
      expect(storage.loadProfile().wallet.coins, 500);
      expect(storage.loadProfile().prizes.weeklyPrizes, hasLength(4));
      expect(emitted, hasLength(1));
    });
  });
}
