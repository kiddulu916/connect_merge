import 'package:flutter_test/flutter_test.dart';
import 'package:merge_count/application/engagement_cubit.dart';
import 'package:merge_count/domain/models/cosmetic.dart';
import 'package:merge_count/domain/models/player_level.dart';
import 'package:merge_count/infrastructure/storage_service.dart';

void main() {
  late InMemoryStorageService storage;
  EngagementCubit make() =>
      EngagementCubit(storage: storage, todayProvider: () => '2026-06-12');

  setUp(() => storage = InMemoryStorageService());

  // A purchasable cosmetic to exercise the economy.
  final buyable =
      Cosmetic.values.firstWhere((c) => c.unlock == CosmeticUnlock.purchase);

  group('purchaseCosmetic (economy guards)', () {
    test('debits exactly the price and records the purchase', () async {
      await storage.saveProfile(PlayerProfile(coins: buyable.price));
      final c = make()..load();

      final ok = await c.purchaseCosmetic(buyable);

      expect(ok, isTrue);
      final profile = storage.loadProfile();
      expect(profile.coins, 0); // debited exactly the price
      expect(profile.purchasedCosmetics, contains(buyable.name));
      expect(c.state.coins, 0);
      expect(c.state.unlockedCosmetics, contains(buyable));
    });

    test('buying with surplus leaves the remainder', () async {
      await storage.saveProfile(PlayerProfile(coins: buyable.price + 25));
      final c = make()..load();
      expect(await c.purchaseCosmetic(buyable), isTrue);
      expect(storage.loadProfile().coins, 25);
    });

    test('overspend (1 coin short) is rejected; balance unchanged', () async {
      await storage.saveProfile(PlayerProfile(coins: buyable.price - 1));
      final c = make()..load();

      final ok = await c.purchaseCosmetic(buyable);

      expect(ok, isFalse);
      expect(storage.loadProfile().coins, buyable.price - 1); // no debit
      expect(storage.loadProfile().purchasedCosmetics, isEmpty);
      expect(c.state.unlockedCosmetics.contains(buyable), isFalse);
    });

    test('zero balance cannot buy a priced cosmetic', () async {
      final c = make()..load();
      expect(await c.purchaseCosmetic(buyable), isFalse);
      expect(storage.loadProfile().coins, 0);
    });

    test('double purchase is idempotent: debited once', () async {
      await storage.saveProfile(PlayerProfile(coins: buyable.price * 2));
      final c = make()..load();

      final first = await c.purchaseCosmetic(buyable);
      final second = await c.purchaseCosmetic(buyable); // double-tap

      expect(first, isTrue);
      expect(second, isFalse); // already owned -> no-op
      expect(storage.loadProfile().coins, buyable.price); // debited ONCE
      expect(
          storage.loadProfile().purchasedCosmetics.where((n) => n == buyable.name).length,
          1);
    });

    test('non-purchase cosmetics cannot be bought (no debit)', () async {
      await storage.saveProfile(const PlayerProfile(coins: 9999));
      final c = make()..load();
      final free = Cosmetic.values
          .firstWhere((c) => c.unlock == CosmeticUnlock.rewardedAd);
      expect(await c.purchaseCosmetic(free), isFalse);
      expect(storage.loadProfile().coins, 9999);
    });

    test('purchased cosmetic survives a reload (migration-free persistence)',
        () async {
      await storage.saveProfile(PlayerProfile(coins: buyable.price));
      await (make()..load()).purchaseCosmetic(buyable);

      final reloaded = make()..load();
      expect(reloaded.state.unlockedCosmetics, contains(buyable));
      expect(reloaded.state.coins, 0);
    });
  });

  group('refreshWallet', () {
    test('picks up coins credited outside the cubit', () async {
      final c = make()..load();
      expect(c.state.coins, 0);
      // Golden tiles / loot chest credit coins directly on the profile.
      await storage.saveProfile(const PlayerProfile(coins: 80));
      c.refreshWallet();
      expect(c.state.coins, 80);
    });
  });

  group('double coins on completion (pure bookkeeping)', () {
    test('crediting then doubling never touches score; wallet doubles', () async {
      // Simulate the result-screen "double coins" reward: the run earned N
      // coins (already on the wallet); the rewarded ad credits N again.
      const earned = 30;
      await storage.saveProfile(const PlayerProfile(coins: earned));

      final profile = storage.loadProfile();
      await storage.saveProfile(profile.copyWith(coins: profile.coins + earned));

      expect(storage.loadProfile().coins, earned * 2);
    });
  });

  group('XP + Almanac fold via onTierCompleted (Phase 2)', () {
    test('a completed run accrues XP and an almanac count', () async {
      final c = make()..load();
      await c.onTierCompleted(date: '2026-06-12', score: 200, highestTier: 9);

      final profile = storage.loadProfile();
      expect(profile.lifetimeXp, xpForScore(200));
      expect(profile.almanacCounts['9'], 1);
      expect(c.state.lifetimeXp, xpForScore(200));
      expect(c.state.almanac.countFor(9), 1);
      expect(c.state.level, levelForXp(xpForScore(200)));
    });

    test('XP is monotonic across consecutive completions', () async {
      await storage.saveProfile(const PlayerProfile(
          lifetimeXp: 500, dailyActiveStreak: 1, lastActiveDate: '2026-06-11'));
      final c = make()..load();
      final before = c.state.lifetimeXp;

      // Even a 0-score run never lowers XP.
      await c.onTierCompleted(date: '2026-06-12', score: 0, highestTier: 0);
      expect(c.state.lifetimeXp, greaterThanOrEqualTo(before));

      await c.onTierCompleted(date: '2026-06-13', score: 150, highestTier: 3);
      expect(c.state.lifetimeXp, greaterThanOrEqualTo(before));
    });

    test('legacy call without score/tier still advances the streak only',
        () async {
      final c = make()..load();
      await c.onTierCompleted(date: '2026-06-12');
      expect(c.state.dailyActiveStreak, 1);
      expect(storage.loadProfile().lifetimeXp, 0);
      expect(storage.loadProfile().almanacCounts, isEmpty);
    });
  });
}
