import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/application/engagement_cubit.dart';
import 'package:connect_merge/domain/models/achievement.dart';
import 'package:connect_merge/domain/models/cosmetic.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/streak.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';

void main() {
  group('nextStreak (pure)', () {
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
      expect(storage.loadProfile().dailyActiveStreak, 1);
    });

    test('consecutive day increments the headline streak', () async {
      await storage.saveProfile(const PlayerProfile(
          dailyActiveStreak: 4, lastActiveDate: '2026-06-06'));
      final c = make()..load();
      await c.onTierCompleted();
      expect(c.state.dailyActiveStreak, 5);
    });

    test('same-day re-completion is idempotent', () async {
      await storage.saveProfile(const PlayerProfile(
          dailyActiveStreak: 4, lastActiveDate: '2026-06-07'));
      final c = make()..load();
      await c.onTierCompleted();
      expect(c.state.dailyActiveStreak, 4);
    });

    test('gap with a banked freeze token keeps the streak + consumes a token',
        () async {
      await storage.saveProfile(const PlayerProfile(
          dailyActiveStreak: 8, lastActiveDate: '2026-06-01'));
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

    test('gap with NO freeze resets the streak to 1', () async {
      await storage.saveProfile(const PlayerProfile(
          dailyActiveStreak: 8, lastActiveDate: '2026-06-01'));
      final c = make()..load();
      await c.onTierCompleted();
      expect(c.state.dailyActiveStreak, 1);
    });

    test('reaching 7-day streak unlocks sevenDayStreak + surfaces it once',
        () async {
      await storage.saveProfile(const PlayerProfile(
          dailyActiveStreak: 6, lastActiveDate: '2026-06-06'));
      final c = make()..load();
      await c.onTierCompleted();
      expect(c.state.dailyActiveStreak, 7);
      expect(c.state.unlocked, contains(Achievement.sevenDayStreak));
      expect(c.state.newlyUnlocked, contains(Achievement.sevenDayStreak));

      c.acknowledgeNewlyUnlocked();
      expect(c.state.newlyUnlocked, isEmpty);
      // Persisted.
      expect(storage.loadProfile().unlockedAchievements,
          contains(Achievement.sevenDayStreak.name));
    });

    test('streak unlocks the ocean cosmetic at 3 days', () async {
      await storage.saveProfile(const PlayerProfile(
          dailyActiveStreak: 2, lastActiveDate: '2026-06-06'));
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
      expect(storage.loadProfile().selectedCosmetic, 'classic');
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
}
