import '../domain/constants.dart';
import '../domain/models/board_state.dart';
import '../domain/models/day_result.dart';
import '../domain/models/difficulty.dart';
import '../domain/models/weekly_prize.dart';

/// A persisted in-progress (or finished) day for a single difficulty tier.
class GameSnapshot {
  final String date; // YYYY-MM-DD (UTC) this snapshot belongs to
  final Difficulty difficulty; // which tier this snapshot belongs to
  final BoardState board;
  final bool completed; // true once the day is locked

  /// Snapshot schema version. A snapshot whose version != [kSnapshotVersion] is
  /// discarded on load (the cubit starts the day fresh under current rules).
  final int version;

  const GameSnapshot({
    required this.date,
    required this.difficulty,
    required this.board,
    required this.completed,
    this.version = kSnapshotVersion,
  });

  Map<String, dynamic> toJson() => {
        'date': date,
        'difficulty': difficulty.name,
        'board': board.toJson(),
        'completed': completed,
        'v': version,
      };

  static GameSnapshot fromJson(Map<String, dynamic> j) => GameSnapshot(
        date: j['date'] as String,
        difficulty: Difficulty.values.byName(j['difficulty'] as String),
        board:
            BoardState.fromJson(Map<String, dynamic>.from(j['board'] as Map)),
        completed: j['completed'] as bool,
        version: (j['v'] as int?) ?? 1,
      );
}

/// Lifetime, cross-day stats for a single difficulty tier. Streaks/best are
/// independent per tier (a Hard streak does not affect an Easy streak).
///
/// [streakFreezeTokens] (Phase 4) are banked per tier but consumed exclusively
/// to shield the headline streak; per-tier streaks never consume one. Capped at
/// [kMaxStreakFreezeTokens] to prevent infinite shielding.
class LifetimeStats {
  final int streak;
  final String? lastCompletedDate;
  final int bestScore;
  final int bestTier;
  final int streakFreezeTokens;

  const LifetimeStats({
    required this.streak,
    required this.lastCompletedDate,
    required this.bestScore,
    required this.bestTier,
    this.streakFreezeTokens = 0,
  });

  static const empty = LifetimeStats(
      streak: 0,
      lastCompletedDate: null,
      bestScore: 0,
      bestTier: 0,
      streakFreezeTokens: 0);

  LifetimeStats copyWith({
    int? streak,
    String? lastCompletedDate,
    int? bestScore,
    int? bestTier,
    int? streakFreezeTokens,
  }) =>
      LifetimeStats(
        streak: streak ?? this.streak,
        lastCompletedDate: lastCompletedDate ?? this.lastCompletedDate,
        bestScore: bestScore ?? this.bestScore,
        bestTier: bestTier ?? this.bestTier,
        streakFreezeTokens: streakFreezeTokens ?? this.streakFreezeTokens,
      );

  Map<String, dynamic> toJson() => {
        'streak': streak,
        'lastCompletedDate': lastCompletedDate,
        'bestScore': bestScore,
        'bestTier': bestTier,
        'streakFreezeTokens': streakFreezeTokens,
      };

  static LifetimeStats fromJson(Map<String, dynamic> j) => LifetimeStats(
        streak: j['streak'] as int,
        lastCompletedDate: j['lastCompletedDate'] as String?,
        bestScore: j['bestScore'] as int,
        bestTier: j['bestTier'] as int,
        streakFreezeTokens: (j['streakFreezeTokens'] as int?) ?? 0,
      );
}

class ActivityStreak {
  final int dailyActiveStreak;
  final String? lastActiveDate;

  const ActivityStreak({
    this.dailyActiveStreak = 0,
    this.lastActiveDate,
  });

  ActivityStreak copyWith({
    int? dailyActiveStreak,
    String? lastActiveDate,
  }) =>
      ActivityStreak(
        dailyActiveStreak: dailyActiveStreak ?? this.dailyActiveStreak,
        lastActiveDate: lastActiveDate ?? this.lastActiveDate,
      );
}

class Progression {
  final Set<String> unlockedAchievements;
  final Map<String, int> bestRankByDifficulty;
  final int lifetimeXp;
  final Map<String, int> almanacCounts;

  const Progression({
    this.unlockedAchievements = const {},
    this.bestRankByDifficulty = const {},
    this.lifetimeXp = 0,
    this.almanacCounts = const {},
  });

  Progression copyWith({
    Set<String>? unlockedAchievements,
    Map<String, int>? bestRankByDifficulty,
    int? lifetimeXp,
    Map<String, int>? almanacCounts,
  }) =>
      Progression(
        unlockedAchievements: unlockedAchievements ?? this.unlockedAchievements,
        bestRankByDifficulty: bestRankByDifficulty ?? this.bestRankByDifficulty,
        lifetimeXp: lifetimeXp ?? this.lifetimeXp,
        almanacCounts: almanacCounts ?? this.almanacCounts,
      );
}

class CosmeticsInventory {
  final String selectedCosmetic;
  final Set<String> adUnlockedCosmetics;
  final Set<String> purchasedCosmetics;

  const CosmeticsInventory({
    this.selectedCosmetic = 'classic',
    this.adUnlockedCosmetics = const {},
    this.purchasedCosmetics = const {},
  });

  CosmeticsInventory copyWith({
    String? selectedCosmetic,
    Set<String>? adUnlockedCosmetics,
    Set<String>? purchasedCosmetics,
  }) =>
      CosmeticsInventory(
        selectedCosmetic: selectedCosmetic ?? this.selectedCosmetic,
        adUnlockedCosmetics: adUnlockedCosmetics ?? this.adUnlockedCosmetics,
        purchasedCosmetics: purchasedCosmetics ?? this.purchasedCosmetics,
      );
}

class PlayerSettings {
  final bool notificationsEnabled;
  final int reminderMinutes;
  final bool tutorialSeen;
  final bool colorblindMode;

  const PlayerSettings({
    this.notificationsEnabled = false,
    this.reminderMinutes = 19 * 60,
    this.tutorialSeen = false,
    this.colorblindMode = false,
  });

  PlayerSettings copyWith({
    bool? notificationsEnabled,
    int? reminderMinutes,
    bool? tutorialSeen,
    bool? colorblindMode,
  }) =>
      PlayerSettings(
        notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
        reminderMinutes: reminderMinutes ?? this.reminderMinutes,
        tutorialSeen: tutorialSeen ?? this.tutorialSeen,
        colorblindMode: colorblindMode ?? this.colorblindMode,
      );
}

class Wallet {
  final int coins;
  final String? lastLootClaimDate;

  const Wallet({
    this.coins = 0,
    this.lastLootClaimDate,
  });

  Wallet copyWith({
    int? coins,
    String? lastLootClaimDate,
  }) =>
      Wallet(
        coins: coins ?? this.coins,
        lastLootClaimDate: lastLootClaimDate ?? this.lastLootClaimDate,
      );
}

class Rivalry {
  final String? rivalId;
  final String? rivalName;
  final Map<String, int> lastSeenRivalScoreByTier;

  const Rivalry({
    this.rivalId,
    this.rivalName,
    this.lastSeenRivalScoreByTier = const {},
  });

  Rivalry copyWith({
    String? rivalId,
    String? rivalName,
    Map<String, int>? lastSeenRivalScoreByTier,
  }) =>
      Rivalry(
        rivalId: rivalId ?? this.rivalId,
        rivalName: rivalName ?? this.rivalName,
        lastSeenRivalScoreByTier:
            lastSeenRivalScoreByTier ?? this.lastSeenRivalScoreByTier,
      );
}

class PrizeLedger {
  final String? lastDailyPrizeDate;
  final String? lastWeeklyPrizeDate;
  final String? lastMonthlyPrizeMonth;
  final String? lastChallengeCheckDate;
  final List<WeeklyPrize> weeklyPrizes;

  const PrizeLedger({
    this.lastDailyPrizeDate,
    this.lastWeeklyPrizeDate,
    this.lastMonthlyPrizeMonth,
    this.lastChallengeCheckDate,
    this.weeklyPrizes = const [],
  });

  PrizeLedger copyWith({
    String? lastDailyPrizeDate,
    String? lastWeeklyPrizeDate,
    String? lastMonthlyPrizeMonth,
    String? lastChallengeCheckDate,
    List<WeeklyPrize>? weeklyPrizes,
  }) =>
      PrizeLedger(
        lastDailyPrizeDate: lastDailyPrizeDate ?? this.lastDailyPrizeDate,
        lastWeeklyPrizeDate: lastWeeklyPrizeDate ?? this.lastWeeklyPrizeDate,
        lastMonthlyPrizeMonth:
            lastMonthlyPrizeMonth ?? this.lastMonthlyPrizeMonth,
        lastChallengeCheckDate:
            lastChallengeCheckDate ?? this.lastChallengeCheckDate,
        weeklyPrizes: weeklyPrizes ?? this.weeklyPrizes,
      );
}

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

/// Cap on streak-freeze tokens a single tier can bank (prevents infinite
/// shielding). One token bridges exactly one missed UTC day.
const int kMaxStreakFreezeTokens = 3;

/// Local persistence boundary. Snapshots and stats are keyed by
/// `(date, difficulty)` / `difficulty`. The Hive implementation lives in
/// hive_storage_service.dart; this in-memory fake is used by tests.
abstract class StorageService {
  Future<void> init();
  GameSnapshot? loadSnapshot(String date, Difficulty difficulty);
  Future<void> saveSnapshot(GameSnapshot snapshot); // carries date + difficulty
  LifetimeStats loadStats(Difficulty difficulty);
  Future<void> saveStats(Difficulty difficulty, LifetimeStats stats);

  /// Cross-tier profile (headline streak, achievements, cosmetics, notif prefs).
  PlayerProfile loadProfile();
  Future<void> saveProfile(PlayerProfile profile);

  /// The SINGLE awaited path for a pure coin credit/refund: loads the profile,
  /// writes `coins = max(0, coins + delta)` (clamped at 0), awaits the save, and
  /// returns the new balance. [delta] is signed (positive credit, negative
  /// refund). Atomic compound writes (loot claim, cosmetic purchase) stay
  /// combined elsewhere — this is only for standalone coin movement.
  Future<int> addCoins(int delta);

  /// Append-only day-result history (Phase 4), powering the stats calendar.
  /// [loadHistory] returns the persisted results in insertion (chronological)
  /// order, oldest first; an empty list when nothing has been recorded (so it
  /// loads cleanly for pre-Phase-4 players). [appendResult] adds one result and
  /// caps the log to [kHistoryRetentionDays] entries, dropping the oldest.
  List<DayResult> loadHistory();
  Future<void> appendResult(DayResult result);

  /// Erase ALL locally persisted data (snapshots, stats, profile, history).
  /// Used by delete-my-data so the device matches the server: gone means gone.
  Future<void> wipeAll();
}

class InMemoryStorageService implements StorageService {
  final Map<String, GameSnapshot> _snapshots = {};
  final Map<String, LifetimeStats> _stats = {};
  PlayerProfile _profile = PlayerProfile.empty;
  final List<DayResult> _history = [];

  static String _snapKey(String date, Difficulty difficulty) =>
      '$date:${difficulty.name}';

  @override
  Future<void> init() async {}

  @override
  GameSnapshot? loadSnapshot(String date, Difficulty difficulty) =>
      _snapshots[_snapKey(date, difficulty)];

  @override
  Future<void> saveSnapshot(GameSnapshot snapshot) async {
    _snapshots[_snapKey(snapshot.date, snapshot.difficulty)] = snapshot;
  }

  @override
  LifetimeStats loadStats(Difficulty difficulty) =>
      _stats[difficulty.name] ?? LifetimeStats.empty;

  @override
  Future<void> saveStats(Difficulty difficulty, LifetimeStats stats) async {
    _stats[difficulty.name] = stats;
  }

  @override
  PlayerProfile loadProfile() => _profile;

  @override
  Future<void> saveProfile(PlayerProfile profile) async {
    _profile = profile;
  }

  @override
  Future<int> addCoins(int delta) async {
    _profile = _profile.creditCoins(delta);
    return _profile.wallet.coins;
  }

  @override
  List<DayResult> loadHistory() => List<DayResult>.unmodifiable(_history);

  @override
  Future<void> appendResult(DayResult result) async {
    _history.add(result);
    // Cap to the retention window, dropping the oldest entries.
    while (_history.length > kHistoryRetentionDays) {
      _history.removeAt(0);
    }
  }

  @override
  Future<void> wipeAll() async {
    _snapshots.clear();
    _stats.clear();
    _profile = PlayerProfile.empty;
    _history.clear();
  }
}
