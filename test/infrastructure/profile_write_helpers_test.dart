import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/weekly_prize.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prize awards add coins, stamp guards, and append crowns', () {
    const oldCrown = WeeklyPrize(
      weekStart: '2026-07-06',
      tier: Difficulty.easy,
      rank: 3,
    );
    const newCrown = WeeklyPrize(
      weekStart: '2026-07-13',
      tier: Difficulty.hard,
      rank: 1,
    );
    const profile = PlayerProfile(
      wallet: Wallet(coins: 100),
      prizes: PrizeLedger(weeklyPrizes: [oldCrown]),
    );

    final awarded = profile
        .awardDailyPrize('2026-07-17', awardCoins: 0)
        .awardWeeklyPrize(
          '2026-07-13',
          awardCoins: 500,
          crowns: const [newCrown],
        )
        .awardMonthlyPrize('2026-06', awardCoins: 1000)
        .awardChallengeCheck('2026-07-17', awardCoins: 150);

    expect(awarded.wallet.coins, 1750);
    expect(awarded.prizes.lastDailyPrizeDate, '2026-07-17');
    expect(awarded.prizes.lastWeeklyPrizeDate, '2026-07-13');
    expect(awarded.prizes.lastMonthlyPrizeMonth, '2026-06');
    expect(awarded.prizes.lastChallengeCheckDate, '2026-07-17');
    expect(awarded.prizes.weeklyPrizes, [oldCrown, newCrown]);
  });

  test('every zero-coin award still stamps its guard', () {
    const profile = PlayerProfile(wallet: Wallet(coins: 100));

    final awarded = profile
        .awardDailyPrize('2026-07-17', awardCoins: 0)
        .awardWeeklyPrize(
          '2026-07-13',
          awardCoins: 0,
          crowns: const [],
        )
        .awardMonthlyPrize('2026-06', awardCoins: 0)
        .awardChallengeCheck('2026-07-17', awardCoins: 0);

    expect(awarded.wallet.coins, 100);
    expect(awarded.prizes.lastDailyPrizeDate, '2026-07-17');
    expect(awarded.prizes.lastWeeklyPrizeDate, '2026-07-13');
    expect(awarded.prizes.lastMonthlyPrizeMonth, '2026-06');
    expect(awarded.prizes.lastChallengeCheckDate, '2026-07-17');
  });

  test('activity and cosmetic helpers preserve their transaction contracts',
      () {
    const profile = PlayerProfile(
      progression: Progression(unlockedAchievements: {'firstMerge'}),
      cosmetics: CosmeticsInventory(
        adUnlockedCosmetics: {'ember'},
        purchasedCosmetics: {'ocean'},
      ),
      wallet: Wallet(coins: 100),
    );

    final updated = profile
        .advanceActivity(
          streak: 7,
          date: '2026-07-17',
          achievements: {'firstMerge', 'sevenDayStreak'},
          lifetimeXp: 900,
          almanacCounts: {'8': 2},
        )
        .grantAdCosmetic('ember')
        .grantAdCosmetic('forest')
        .selectCosmetic('forest')
        .recordPurchase('royal', price: 40);

    expect(updated.activity.dailyActiveStreak, 7);
    expect(updated.activity.lastActiveDate, '2026-07-17');
    expect(updated.progression.unlockedAchievements,
        {'firstMerge', 'sevenDayStreak'});
    expect(updated.progression.lifetimeXp, 900);
    expect(updated.progression.almanacCounts, {'8': 2});
    expect(updated.cosmetics.adUnlockedCosmetics, {'ember', 'forest'});
    expect(updated.cosmetics.selectedCosmetic, 'forest');
    expect(updated.cosmetics.purchasedCosmetics, {'ocean', 'royal'});
    expect(updated.wallet.coins, 60);
  });

  test('wallet helpers add claims and clamp credits at zero', () {
    const profile = PlayerProfile(wallet: Wallet(coins: 25));

    final claimed = profile.claimLoot('2026-07-17', awardCoins: 30);
    final clamped = claimed.creditCoins(-100);

    expect(claimed.wallet.coins, 55);
    expect(claimed.wallet.lastLootClaimDate, '2026-07-17');
    expect(clamped.wallet.coins, 0);
    expect(clamped.wallet.lastLootClaimDate, '2026-07-17');
  });

  test('setting and clearing a rival both reset last-seen scores', () {
    const profile = PlayerProfile(
      rivalry: Rivalry(
        rivalId: 'old-id',
        rivalName: 'Old Name',
        lastSeenRivalScoreByTier: {'hard': 4096},
      ),
    );

    final set = profile.setRival('new-id', 'New Name');
    final cleared = set.clearRival();

    expect(set.rivalry.rivalId, 'new-id');
    expect(set.rivalry.rivalName, 'New Name');
    expect(set.rivalry.lastSeenRivalScoreByTier, isEmpty);
    expect(cleared.rivalry.rivalId, isNull);
    expect(cleared.rivalry.rivalName, isNull);
    expect(cleared.rivalry.lastSeenRivalScoreByTier, isEmpty);
  });
}
