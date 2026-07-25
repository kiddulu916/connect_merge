import '../../domain/models/weekly_prize.dart';
import 'activity_streak.dart';
import 'cosmetics_inventory.dart';
import 'player_settings.dart';
import 'prize_ledger.dart';
import 'progression.dart';
import 'rivalry.dart';
import 'wallet.dart';

/// Cross-tier profile grouped by the systems that own each persisted field.
/// Its JSON representation remains the original flat 23-key map.
class PlayerProfile {
  final ActivityStreak activity;
  final Progression progression;
  final CosmeticsInventory cosmetics;
  final PlayerSettings settings;
  final Wallet wallet;
  final Rivalry rivalry;
  final PrizeLedger prizes;

  const PlayerProfile({
    this.activity = const ActivityStreak(),
    this.progression = const Progression(),
    this.cosmetics = const CosmeticsInventory(),
    this.settings = const PlayerSettings(),
    this.wallet = const Wallet(),
    this.rivalry = const Rivalry(),
    this.prizes = const PrizeLedger(),
  });

  static const empty = PlayerProfile();

  PlayerProfile copyWith({
    ActivityStreak? activity,
    Progression? progression,
    CosmeticsInventory? cosmetics,
    PlayerSettings? settings,
    Wallet? wallet,
    Rivalry? rivalry,
    PrizeLedger? prizes,
  }) =>
      PlayerProfile(
        activity: activity ?? this.activity,
        progression: progression ?? this.progression,
        cosmetics: cosmetics ?? this.cosmetics,
        settings: settings ?? this.settings,
        wallet: wallet ?? this.wallet,
        rivalry: rivalry ?? this.rivalry,
        prizes: prizes ?? this.prizes,
      );

  /// Adds [awardCoins] and stamps [date], including for a zero award.
  /// Guard checks, persistence, and emission remain the caller's responsibility.
  PlayerProfile awardDailyPrize(
    String date, {
    required int awardCoins,
  }) =>
      copyWith(
        wallet: wallet.copyWith(coins: wallet.coins + awardCoins),
        prizes: prizes.copyWith(lastDailyPrizeDate: date),
      );

  /// Adds [awardCoins], appends [crowns], and stamps [weekFrom].
  /// Guard checks, persistence, and emission remain the caller's responsibility.
  PlayerProfile awardWeeklyPrize(
    String weekFrom, {
    required int awardCoins,
    required List<WeeklyPrize> crowns,
  }) =>
      copyWith(
        wallet: wallet.copyWith(coins: wallet.coins + awardCoins),
        prizes: prizes.copyWith(
          lastWeeklyPrizeDate: weekFrom,
          weeklyPrizes: [...prizes.weeklyPrizes, ...crowns],
        ),
      );

  /// Adds [awardCoins] and stamps [monthKey], including for a zero award.
  /// Guard checks, persistence, and emission remain the caller's responsibility.
  PlayerProfile awardMonthlyPrize(
    String monthKey, {
    required int awardCoins,
  }) =>
      copyWith(
        wallet: wallet.copyWith(coins: wallet.coins + awardCoins),
        prizes: prizes.copyWith(lastMonthlyPrizeMonth: monthKey),
      );

  /// Adds [awardCoins] and stamps [date], including for a zero award.
  /// Guard checks, persistence, and emission remain the caller's responsibility.
  PlayerProfile awardChallengeCheck(
    String date, {
    required int awardCoins,
  }) =>
      copyWith(
        wallet: wallet.copyWith(coins: wallet.coins + awardCoins),
        prizes: prizes.copyWith(lastChallengeCheckDate: date),
      );

  PlayerProfile advanceActivity({
    required int streak,
    required String date,
    required Set<String> achievements,
    required int lifetimeXp,
    required Map<String, int> almanacCounts,
  }) =>
      copyWith(
        activity: activity.copyWith(
          dailyActiveStreak: streak,
          lastActiveDate: date,
        ),
        progression: progression.copyWith(
          unlockedAchievements: achievements,
          lifetimeXp: lifetimeXp,
          almanacCounts: almanacCounts,
        ),
      );

  /// Records a caller-validated purchase by debiting and unioning its name.
  /// Unlock-kind, idempotency, and funds checks stay in EngagementCubit.
  PlayerProfile recordPurchase(
    String cosmeticName, {
    required int price,
  }) =>
      copyWith(
        wallet: wallet.copyWith(coins: wallet.coins - price),
        cosmetics: cosmetics.copyWith(
          purchasedCosmetics: {
            ...cosmetics.purchasedCosmetics,
            cosmeticName,
          },
        ),
      );

  PlayerProfile grantAdCosmetic(String name) => copyWith(
        cosmetics: cosmetics.copyWith(
          adUnlockedCosmetics: {...cosmetics.adUnlockedCosmetics, name},
        ),
      );

  PlayerProfile selectCosmetic(String name) => copyWith(
        cosmetics: cosmetics.copyWith(selectedCosmetic: name),
      );

  PlayerProfile claimLoot(
    String date, {
    required int awardCoins,
  }) =>
      copyWith(
        wallet: wallet.copyWith(
          coins: wallet.coins + awardCoins,
          lastLootClaimDate: date,
        ),
      );

  PlayerProfile creditCoins(int delta) => copyWith(
        wallet: wallet.copyWith(
          coins: wallet.coins + delta < 0 ? 0 : wallet.coins + delta,
        ),
      );

  PlayerProfile setRival(String id, String name) => copyWith(
        rivalry: Rivalry(rivalId: id, rivalName: name),
      );

  PlayerProfile clearRival() => copyWith(rivalry: const Rivalry());

  Map<String, dynamic> toJson() => {
        'dailyActiveStreak': activity.dailyActiveStreak,
        'lastActiveDate': activity.lastActiveDate,
        'unlockedAchievements': progression.unlockedAchievements.toList(),
        'selectedCosmetic': cosmetics.selectedCosmetic,
        'adUnlockedCosmetics': cosmetics.adUnlockedCosmetics.toList(),
        'notificationsEnabled': settings.notificationsEnabled,
        'reminderMinutes': settings.reminderMinutes,
        'bestRankByDifficulty': progression.bestRankByDifficulty,
        'coins': wallet.coins,
        'lastLootClaimDate': wallet.lastLootClaimDate,
        'purchasedCosmetics': cosmetics.purchasedCosmetics.toList(),
        'lifetimeXp': progression.lifetimeXp,
        'almanacCounts': progression.almanacCounts,
        'rivalId': rivalry.rivalId,
        'rivalName': rivalry.rivalName,
        'lastSeenRivalScoreByTier': rivalry.lastSeenRivalScoreByTier,
        'tutorialSeen': settings.tutorialSeen,
        'colorblindMode': settings.colorblindMode,
        'lastWeeklyPrizeDate': prizes.lastWeeklyPrizeDate,
        'weeklyPrizes': prizes.weeklyPrizes.map((p) => p.toJson()).toList(),
        'lastChallengeCheckDate': prizes.lastChallengeCheckDate,
        'lastDailyPrizeDate': prizes.lastDailyPrizeDate,
        'lastMonthlyPrizeMonth': prizes.lastMonthlyPrizeMonth,
      };

  static PlayerProfile fromJson(Map<String, dynamic> j) => PlayerProfile(
        activity: ActivityStreak(
          dailyActiveStreak: (j['dailyActiveStreak'] as int?) ?? 0,
          lastActiveDate: j['lastActiveDate'] as String?,
        ),
        progression: Progression(
          unlockedAchievements:
              ((j['unlockedAchievements'] as List?) ?? const [])
                  .map((e) => e as String)
                  .toSet(),
          bestRankByDifficulty:
              ((j['bestRankByDifficulty'] as Map?) ?? const {})
                  .map((k, v) => MapEntry(k as String, (v as num).toInt())),
          lifetimeXp: (j['lifetimeXp'] as int?) ?? 0,
          almanacCounts: ((j['almanacCounts'] as Map?) ?? const {})
              .map((k, v) => MapEntry(k as String, (v as num).toInt())),
        ),
        cosmetics: CosmeticsInventory(
          selectedCosmetic: (j['selectedCosmetic'] as String?) ?? 'classic',
          adUnlockedCosmetics: ((j['adUnlockedCosmetics'] as List?) ?? const [])
              .map((e) => e as String)
              .toSet(),
          purchasedCosmetics: ((j['purchasedCosmetics'] as List?) ?? const [])
              .map((e) => e as String)
              .toSet(),
        ),
        settings: PlayerSettings(
          notificationsEnabled: (j['notificationsEnabled'] as bool?) ?? false,
          reminderMinutes: (j['reminderMinutes'] as int?) ?? 19 * 60,
          tutorialSeen: (j['tutorialSeen'] as bool?) ?? false,
          colorblindMode: (j['colorblindMode'] as bool?) ?? false,
        ),
        wallet: Wallet(
          coins: (j['coins'] as int?) ?? 0,
          lastLootClaimDate: j['lastLootClaimDate'] as String?,
        ),
        rivalry: Rivalry(
          rivalId: j['rivalId'] as String?,
          rivalName: j['rivalName'] as String?,
          lastSeenRivalScoreByTier:
              ((j['lastSeenRivalScoreByTier'] as Map?) ?? const {})
                  .map((k, v) => MapEntry(k as String, (v as num).toInt())),
        ),
        prizes: PrizeLedger(
          lastWeeklyPrizeDate: j['lastWeeklyPrizeDate'] as String?,
          weeklyPrizes: ((j['weeklyPrizes'] as List?) ?? const [])
              .map((e) =>
                  WeeklyPrize.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList(),
          lastChallengeCheckDate: j['lastChallengeCheckDate'] as String?,
          lastDailyPrizeDate: j['lastDailyPrizeDate'] as String?,
          lastMonthlyPrizeMonth: j['lastMonthlyPrizeMonth'] as String?,
        ),
      );
}
