import '../domain/models/board_state.dart';
import '../domain/models/difficulty.dart';

/// A persisted in-progress (or finished) day for a single difficulty tier.
class GameSnapshot {
  final String date; // YYYY-MM-DD (UTC) this snapshot belongs to
  final Difficulty difficulty; // which tier this snapshot belongs to
  final BoardState board;
  final bool completed; // true once the day is locked

  const GameSnapshot({
    required this.date,
    required this.difficulty,
    required this.board,
    required this.completed,
  });

  Map<String, dynamic> toJson() => {
        'date': date,
        'difficulty': difficulty.name,
        'board': board.toJson(),
        'completed': completed,
      };

  static GameSnapshot fromJson(Map<String, dynamic> j) => GameSnapshot(
        date: j['date'] as String,
        difficulty: Difficulty.values.byName(j['difficulty'] as String),
        board: BoardState.fromJson(Map<String, dynamic>.from(j['board'] as Map)),
        completed: j['completed'] as bool,
      );
}

/// Lifetime, cross-day stats for a single difficulty tier. Streaks/best are
/// independent per tier (a Hard streak does not affect an Easy streak).
///
/// [streakFreezeTokens] (Phase 4) shield this tier's streak from a single missed
/// UTC day; capped at [kMaxStreakFreezeTokens] to prevent infinite shielding.
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
        // Absent in pre-Phase-4 stats: default to 0 (migration-free).
        streakFreezeTokens: (j['streakFreezeTokens'] as int?) ?? 0,
      );
}

/// Cross-tier player profile (Phase 4): the headline daily-active streak,
/// unlocked achievements, selected + ad-unlocked cosmetics, and local
/// notification preferences. Single record (not per-tier).
class PlayerProfile {
  /// "Any tier today" headline streak.
  final int dailyActiveStreak;

  /// UTC date of the last day any tier was completed (drives the headline
  /// streak transition). Null until the first completion.
  final String? lastActiveDate;

  /// Achievement enum `name`s already unlocked (stable storage tokens).
  final Set<String> unlockedAchievements;

  /// Currently selected cosmetic enum `name`.
  final String selectedCosmetic;

  /// Cosmetic enum `name`s unlocked specifically via rewarded ad.
  final Set<String> adUnlockedCosmetics;

  /// Local-notification preferences.
  final bool notificationsEnabled;

  /// Reminder time as minutes past local midnight (e.g. 1140 == 19:00).
  final int reminderMinutes;

  /// Best (lowest) leaderboard rank ever observed per difficulty `name`. Only
  /// populated lazily after a leaderboard fetch (powers rank-based achievements).
  final Map<String, int> bestRankByDifficulty;

  /// Soft-currency wallet balance (Phase 1). A purely client-side economy:
  /// coins NEVER affect `BoardState.score` or the move log. Migration-free
  /// default 0.
  final int coins;

  /// UTC date (`YYYY-MM-DD`) of the last Daily Loot Chest claim, or null if the
  /// chest has never been claimed. Guards once-per-UTC-day claiming.
  /// Migration-free default null.
  final String? lastLootClaimDate;

  const PlayerProfile({
    this.dailyActiveStreak = 0,
    this.lastActiveDate,
    this.unlockedAchievements = const {},
    this.selectedCosmetic = 'classic',
    this.adUnlockedCosmetics = const {},
    this.notificationsEnabled = false,
    this.reminderMinutes = 19 * 60,
    this.bestRankByDifficulty = const {},
    this.coins = 0,
    this.lastLootClaimDate,
  });

  static const empty = PlayerProfile();

  PlayerProfile copyWith({
    int? dailyActiveStreak,
    String? lastActiveDate,
    Set<String>? unlockedAchievements,
    String? selectedCosmetic,
    Set<String>? adUnlockedCosmetics,
    bool? notificationsEnabled,
    int? reminderMinutes,
    Map<String, int>? bestRankByDifficulty,
    int? coins,
    String? lastLootClaimDate,
  }) =>
      PlayerProfile(
        dailyActiveStreak: dailyActiveStreak ?? this.dailyActiveStreak,
        lastActiveDate: lastActiveDate ?? this.lastActiveDate,
        unlockedAchievements: unlockedAchievements ?? this.unlockedAchievements,
        selectedCosmetic: selectedCosmetic ?? this.selectedCosmetic,
        adUnlockedCosmetics: adUnlockedCosmetics ?? this.adUnlockedCosmetics,
        notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
        reminderMinutes: reminderMinutes ?? this.reminderMinutes,
        bestRankByDifficulty:
            bestRankByDifficulty ?? this.bestRankByDifficulty,
        coins: coins ?? this.coins,
        lastLootClaimDate: lastLootClaimDate ?? this.lastLootClaimDate,
      );

  Map<String, dynamic> toJson() => {
        'dailyActiveStreak': dailyActiveStreak,
        'lastActiveDate': lastActiveDate,
        'unlockedAchievements': unlockedAchievements.toList(),
        'selectedCosmetic': selectedCosmetic,
        'adUnlockedCosmetics': adUnlockedCosmetics.toList(),
        'notificationsEnabled': notificationsEnabled,
        'reminderMinutes': reminderMinutes,
        'bestRankByDifficulty': bestRankByDifficulty,
        'coins': coins,
        'lastLootClaimDate': lastLootClaimDate,
      };

  static PlayerProfile fromJson(Map<String, dynamic> j) => PlayerProfile(
        dailyActiveStreak: (j['dailyActiveStreak'] as int?) ?? 0,
        lastActiveDate: j['lastActiveDate'] as String?,
        unlockedAchievements:
            ((j['unlockedAchievements'] as List?) ?? const [])
                .map((e) => e as String)
                .toSet(),
        selectedCosmetic: (j['selectedCosmetic'] as String?) ?? 'classic',
        adUnlockedCosmetics: ((j['adUnlockedCosmetics'] as List?) ?? const [])
            .map((e) => e as String)
            .toSet(),
        notificationsEnabled: (j['notificationsEnabled'] as bool?) ?? false,
        reminderMinutes: (j['reminderMinutes'] as int?) ?? 19 * 60,
        bestRankByDifficulty: ((j['bestRankByDifficulty'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k as String, (v as num).toInt())),
        // Absent in pre-Phase-1 profiles: migration-free defaults.
        coins: (j['coins'] as int?) ?? 0,
        lastLootClaimDate: j['lastLootClaimDate'] as String?,
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
}

class InMemoryStorageService implements StorageService {
  final Map<String, GameSnapshot> _snapshots = {};
  final Map<String, LifetimeStats> _stats = {};
  PlayerProfile _profile = PlayerProfile.empty;

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
}
