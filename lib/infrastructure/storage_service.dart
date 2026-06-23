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
        board: BoardState.fromJson(Map<String, dynamic>.from(j['board'] as Map)),
        completed: j['completed'] as bool,
        version: (j['v'] as int?) ?? 1,
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

  /// Cosmetic enum `name`s bought with coins (Phase 2). A purely client-side
  /// purchase ledger — buying debits [coins] and records the name here.
  /// Migration-free default empty.
  final Set<String> purchasedCosmetics;

  /// Cumulative client-side XP (Phase 2), derived from already-recorded run
  /// scores. Drives the player level (pure flair); NEVER affects score or
  /// replay. Migration-free default 0.
  final int lifetimeXp;

  /// Merge Almanac counts (Phase 2): tier (as a string key) -> times that tier
  /// was the highest reached in a run. Migration-free default empty.
  final Map<String, int> almanacCounts;

  /// The chosen rival's stable player id (Phase 3), or null if no rival is set.
  /// Migration-free default null.
  final String? rivalId;

  /// The chosen rival's display name (Phase 3), for the you-vs-them chip.
  /// Migration-free default null.
  final String? rivalName;

  /// Last seen rival score per tier (`difficulty.name` -> score) (Phase 3). The
  /// "your rival passed you" nudge fires only when the rival's fetched score
  /// exceeds BOTH the player's score AND this last-seen value, so a single
  /// overtake fires at most one notification (no spam). Migration-free default
  /// empty.
  final Map<String, int> lastSeenRivalScoreByTier;

  /// Whether the first-run tutorial overlay has been shown+dismissed (Phase 4).
  /// Gates the one-time coachmarks. Migration-free default false.
  final bool tutorialSeen;

  /// Whether colorblind-safe tile patterns are enabled (Phase 4). Numerals are
  /// always rendered; this opt-in adds a per-tier pattern overlay so tiles are
  /// distinguishable without hue. Migration-free default false.
  final bool colorblindMode;

  /// ISO week-start Monday of the last weekly prize check. Guards once-per-week
  /// claiming. Migration-free default null.
  final String? lastWeeklyPrizeDate;

  /// Permanent history of weekly top-3 finishes, serialised as raw JSON list.
  /// Migration-free default empty.
  final List<WeeklyPrize> weeklyPrizes;

  /// UTC date of the last challenge payout check (`YYYY-MM-DD`). Guards
  /// once-per-day claiming. Migration-free default null.
  final String? lastChallengeCheckDate;

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
    this.purchasedCosmetics = const {},
    this.lifetimeXp = 0,
    this.almanacCounts = const {},
    this.rivalId,
    this.rivalName,
    this.lastSeenRivalScoreByTier = const {},
    this.tutorialSeen = false,
    this.colorblindMode = false,
    this.lastWeeklyPrizeDate,
    this.weeklyPrizes = const [],
    this.lastChallengeCheckDate,
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
    Set<String>? purchasedCosmetics,
    int? lifetimeXp,
    Map<String, int>? almanacCounts,
    String? rivalId,
    bool clearRival = false,
    String? rivalName,
    Map<String, int>? lastSeenRivalScoreByTier,
    bool? tutorialSeen,
    bool? colorblindMode,
    String? lastWeeklyPrizeDate,
    bool clearLastWeeklyPrizeDate = false,
    List<WeeklyPrize>? weeklyPrizes,
    String? lastChallengeCheckDate,
    bool clearLastChallengeCheckDate = false,
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
        purchasedCosmetics: purchasedCosmetics ?? this.purchasedCosmetics,
        lifetimeXp: lifetimeXp ?? this.lifetimeXp,
        almanacCounts: almanacCounts ?? this.almanacCounts,
        // [clearRival] wins so a rival can be explicitly removed (set to null).
        rivalId: clearRival ? null : (rivalId ?? this.rivalId),
        rivalName: clearRival ? null : (rivalName ?? this.rivalName),
        lastSeenRivalScoreByTier:
            lastSeenRivalScoreByTier ?? this.lastSeenRivalScoreByTier,
        tutorialSeen: tutorialSeen ?? this.tutorialSeen,
        colorblindMode: colorblindMode ?? this.colorblindMode,
        lastWeeklyPrizeDate: clearLastWeeklyPrizeDate
            ? null
            : (lastWeeklyPrizeDate ?? this.lastWeeklyPrizeDate),
        weeklyPrizes: weeklyPrizes ?? this.weeklyPrizes,
        lastChallengeCheckDate: clearLastChallengeCheckDate
            ? null
            : (lastChallengeCheckDate ?? this.lastChallengeCheckDate),
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
        'purchasedCosmetics': purchasedCosmetics.toList(),
        'lifetimeXp': lifetimeXp,
        'almanacCounts': almanacCounts,
        'rivalId': rivalId,
        'rivalName': rivalName,
        'lastSeenRivalScoreByTier': lastSeenRivalScoreByTier,
        'tutorialSeen': tutorialSeen,
        'colorblindMode': colorblindMode,
        'lastWeeklyPrizeDate': lastWeeklyPrizeDate,
        'weeklyPrizes': weeklyPrizes.map((p) => p.toJson()).toList(),
        'lastChallengeCheckDate': lastChallengeCheckDate,
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
        // Absent in pre-Phase-2 profiles: migration-free defaults.
        purchasedCosmetics: ((j['purchasedCosmetics'] as List?) ?? const [])
            .map((e) => e as String)
            .toSet(),
        lifetimeXp: (j['lifetimeXp'] as int?) ?? 0,
        almanacCounts: ((j['almanacCounts'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k as String, (v as num).toInt())),
        // Absent in pre-Phase-3 profiles: migration-free defaults.
        rivalId: j['rivalId'] as String?,
        rivalName: j['rivalName'] as String?,
        lastSeenRivalScoreByTier:
            ((j['lastSeenRivalScoreByTier'] as Map?) ?? const {})
                .map((k, v) => MapEntry(k as String, (v as num).toInt())),
        // Absent in pre-Phase-4 profiles: migration-free defaults.
        tutorialSeen: (j['tutorialSeen'] as bool?) ?? false,
        colorblindMode: (j['colorblindMode'] as bool?) ?? false,
        // Absent in pre-weekly-prize profiles: migration-free defaults.
        lastWeeklyPrizeDate: j['lastWeeklyPrizeDate'] as String?,
        weeklyPrizes: ((j['weeklyPrizes'] as List?) ?? const [])
            .map((e) => WeeklyPrize.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        lastChallengeCheckDate: j['lastChallengeCheckDate'] as String?,
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
    final next = (_profile.coins + delta) < 0 ? 0 : _profile.coins + delta;
    _profile = _profile.copyWith(coins: next);
    return next;
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
}
