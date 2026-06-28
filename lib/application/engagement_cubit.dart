import 'package:flutter_bloc/flutter_bloc.dart';

import '../domain/engine/almanac_progress.dart';
import '../domain/models/achievement.dart';
import '../domain/models/almanac.dart';
import '../domain/models/cosmetic.dart';
import '../domain/models/difficulty.dart';
import '../domain/models/leaderboard_entry.dart';
import '../domain/models/player_level.dart';
import '../domain/models/streak.dart';
import '../domain/models/weekly_prize.dart';
import '../infrastructure/storage_service.dart';
import 'game_cubit.dart' show formatDate, utcToday;

/// Immutable view of the player's retention state for the UI.
class EngagementState {
  /// Headline "any tier today" streak.
  final int dailyActiveStreak;

  /// UTC date the headline streak last advanced. Null until first completion.
  final String? lastActiveDate;

  /// Unlocked achievements (decoded from storage tokens).
  final Set<Achievement> unlocked;

  /// Achievements unlocked by the MOST RECENT completion hook — surfaced once on
  /// the result screen, then cleared by [acknowledgeNewlyUnlocked].
  final Set<Achievement> newlyUnlocked;

  /// Currently selected cosmetic.
  final Cosmetic selectedCosmetic;

  /// The full set of cosmetics currently unlocked (free + earned + ad).
  final Set<Cosmetic> unlockedCosmetics;

  /// Banked streak-freeze tokens (mirrors the headline streak; one bridges one
  /// missed UTC day).
  final int freezeTokens;

  /// Soft-currency wallet balance (Phase 2), surfaced so the cosmetics screen
  /// can gate purchases without re-reading storage.
  final int coins;

  /// Cumulative client-side XP (Phase 2). Derived from recorded run scores.
  final int lifetimeXp;

  /// The Merge Almanac (Phase 2) — per-tier collection + mastery badges.
  final Almanac almanac;

  /// Permanent history of weekly top-3 finishes for the "Your Crowns" UI.
  final List<WeeklyPrize> weeklyPrizes;

  const EngagementState({
    this.dailyActiveStreak = 0,
    this.lastActiveDate,
    this.unlocked = const {},
    this.newlyUnlocked = const {},
    this.selectedCosmetic = Cosmetic.classic,
    this.unlockedCosmetics = const {Cosmetic.classic},
    this.freezeTokens = 0,
    this.coins = 0,
    this.lifetimeXp = 0,
    this.almanac = Almanac.empty,
    this.weeklyPrizes = const [],
  });

  /// The player's current level, derived from [lifetimeXp] (pure flair).
  int get level => levelForXp(lifetimeXp);

  EngagementState copyWith({
    int? dailyActiveStreak,
    String? lastActiveDate,
    bool clearLastActiveDate = false,
    Set<Achievement>? unlocked,
    Set<Achievement>? newlyUnlocked,
    Cosmetic? selectedCosmetic,
    Set<Cosmetic>? unlockedCosmetics,
    int? freezeTokens,
    int? coins,
    int? lifetimeXp,
    Almanac? almanac,
    List<WeeklyPrize>? weeklyPrizes,
  }) =>
      EngagementState(
        dailyActiveStreak: dailyActiveStreak ?? this.dailyActiveStreak,
        lastActiveDate:
            clearLastActiveDate ? null : (lastActiveDate ?? this.lastActiveDate),
        unlocked: unlocked ?? this.unlocked,
        newlyUnlocked: newlyUnlocked ?? this.newlyUnlocked,
        selectedCosmetic: selectedCosmetic ?? this.selectedCosmetic,
        unlockedCosmetics: unlockedCosmetics ?? this.unlockedCosmetics,
        freezeTokens: freezeTokens ?? this.freezeTokens,
        coins: coins ?? this.coins,
        lifetimeXp: lifetimeXp ?? this.lifetimeXp,
        almanac: almanac ?? this.almanac,
        weeklyPrizes: weeklyPrizes ?? this.weeklyPrizes,
      );
}

/// Maximum streak-freeze tokens the headline streak can bank (re-uses the
/// per-tier cap so the rule is uniform).
const int kMaxFreezeTokens = kMaxStreakFreezeTokens;

/// Orchestrates Phase 4 retention: the headline daily-active streak (with freeze
/// tokens), achievement unlocks, and cosmetic selection. Pure transition logic
/// lives in the domain models ([nextStreak], [Achievement.isUnlocked],
/// [Cosmetic.isUnlocked]); this cubit wires them to persistence + the UI.
///
/// [GameCubit] calls [onTierCompleted] after a day is locked.
class EngagementCubit extends Cubit<EngagementState> {
  final StorageService storage;
  final String Function() todayProvider;

  EngagementCubit({
    required this.storage,
    String Function()? todayProvider,
  })  : todayProvider = todayProvider ?? utcToday,
        super(const EngagementState());

  /// Hydrate from storage. Recomputes the unlocked sets from the loaded profile
  /// + per-tier stats so any externally-changed progress is reflected.
  void load() {
    final profile = storage.loadProfile();
    final unlocked = _decodeAchievements(profile.unlockedAchievements);
    final adCosmetics = _decodeCosmetics(profile.adUnlockedCosmetics);
    final purchased = _decodeCosmetics(profile.purchasedCosmetics);
    emit(EngagementState(
      dailyActiveStreak: profile.dailyActiveStreak,
      lastActiveDate: profile.lastActiveDate,
      unlocked: unlocked,
      newlyUnlocked: const {},
      selectedCosmetic: _cosmeticByName(profile.selectedCosmetic),
      unlockedCosmetics: unlockedCosmetics(
        dailyActiveStreak: profile.dailyActiveStreak,
        achievements: unlocked,
        adUnlocked: adCosmetics,
        purchased: purchased,
      ),
      freezeTokens: _maxTierFreezeTokens(),
      coins: profile.coins,
      lifetimeXp: profile.lifetimeXp,
      almanac: Almanac.fromStorage(profile.almanacCounts),
      weeklyPrizes: profile.weeklyPrizes,
    ));
  }

  /// Completion hook (called by [GameCubit] after a tier's day is locked).
  ///
  /// 1. Advance the headline daily-active streak (idempotent within a UTC day),
  ///    consuming a freeze token to bridge a single missed day if available.
  /// 2. Recompute unlocked achievements from current progress and surface any
  ///    newly unlocked ones for the result screen.
  /// 3. Recompute unlocked cosmetics (streak/achievement/purchase gated).
  /// 4. Fold the finished run's [score] into client-side XP and its
  ///    [highestTier] into the Merge Almanac (Phase 2). Both are pure flair —
  ///    they NEVER affect `BoardState.score` or replay. XP is monotonic
  ///    (accumulates a non-negative amount); almanac counts are monotonic.
  /// 5. Persist the updated profile.
  ///
  /// [score] and [highestTier] default to 0 so legacy callers (which only
  /// advanced the streak) keep working — a 0 run adds 0 XP and no almanac count.
  Future<void> onTierCompleted({
    String? date,
    int score = 0,
    int highestTier = 0,
  }) async {
    final today = date ?? todayProvider();
    final profile = storage.loadProfile();

    // --- Streak transition (headline, "any tier today"). ---
    final hasFreeze = _maxTierFreezeTokens() > 0;
    final result = nextStreak(
      prev: profile.dailyActiveStreak,
      last: profile.lastActiveDate,
      today: today,
      hasFreeze: hasFreeze,
    );
    if (result.freezeConsumed) {
      await _consumeOneFreezeToken();
    }

    // --- Progress + achievements. ---
    final progress = _buildProgress(dailyActiveStreak: result.streak);
    final already = _decodeAchievements(profile.unlockedAchievements);
    final fresh = newlyUnlocked(progress, already);
    final allUnlocked = already.union(fresh);

    // --- Cosmetics. ---
    final adCosmetics = _decodeCosmetics(profile.adUnlockedCosmetics);
    final purchased = _decodeCosmetics(profile.purchasedCosmetics);
    final cosmetics = unlockedCosmetics(
      dailyActiveStreak: result.streak,
      achievements: allUnlocked,
      adUnlocked: adCosmetics,
      purchased: purchased,
    );

    // --- Meta-progression: XP + Almanac (Phase 2, pure client-side flair). ---
    final lifetimeXp = profile.lifetimeXp + xpForScore(score);
    final almanacCounts =
        foldRunIntoAlmanac(profile.almanacCounts, highestTier);

    final updated = profile.copyWith(
      dailyActiveStreak: result.streak,
      lastActiveDate: today,
      unlockedAchievements: allUnlocked.map((a) => a.name).toSet(),
      lifetimeXp: lifetimeXp,
      almanacCounts: almanacCounts,
    );
    await storage.saveProfile(updated);

    emit(state.copyWith(
      dailyActiveStreak: result.streak,
      lastActiveDate: today,
      unlocked: allUnlocked,
      newlyUnlocked: fresh,
      unlockedCosmetics: cosmetics,
      freezeTokens: _maxTierFreezeTokens(),
      coins: updated.coins,
      lifetimeXp: lifetimeXp,
      almanac: Almanac.fromStorage(almanacCounts),
    ));
  }

  /// Clear the one-shot newly-unlocked set after the result screen has shown it.
  void acknowledgeNewlyUnlocked() {
    if (state.newlyUnlocked.isEmpty) return;
    emit(state.copyWith(newlyUnlocked: const {}));
  }

  /// Select a cosmetic. Gated on the unlocked set — selecting a locked cosmetic
  /// is a no-op (harmless exploit prevention).
  Future<void> selectCosmetic(Cosmetic cosmetic) async {
    if (!state.unlockedCosmetics.contains(cosmetic)) return;
    final profile = storage.loadProfile();
    await storage.saveProfile(profile.copyWith(selectedCosmetic: cosmetic.name));
    emit(state.copyWith(selectedCosmetic: cosmetic));
  }

  /// Grant an ad-unlocked cosmetic (after a rewarded ad). Only valid for
  /// [CosmeticUnlock.rewardedAd] cosmetics.
  Future<void> grantAdCosmetic(Cosmetic cosmetic) async {
    if (cosmetic.unlock != CosmeticUnlock.rewardedAd) return;
    final profile = storage.loadProfile();
    final ad = {...profile.adUnlockedCosmetics, cosmetic.name};
    await storage.saveProfile(profile.copyWith(adUnlockedCosmetics: ad));
    emit(state.copyWith(
      unlockedCosmetics: {...state.unlockedCosmetics, cosmetic},
    ));
  }

  /// Re-sync the wallet balance from storage into state (Phase 2). Coins can be
  /// credited outside this cubit (golden tiles, loot chest), so call this before
  /// gating a purchase so the displayed balance is current. No-op if unchanged.
  void refreshWallet() {
    final coins = storage.loadProfile().coins;
    if (coins == state.coins) return;
    emit(state.copyWith(coins: coins));
  }

  /// Purchase a [CosmeticUnlock.purchase] cosmetic with coins (Phase 2).
  ///
  /// Read-check-write inside a single [loadProfile]→[saveProfile] so the wallet
  /// cannot leak value:
  /// - rejects non-purchasable cosmetics,
  /// - rejects overspend (`balance < price`) without debiting,
  /// - is idempotent (a cosmetic already purchased is not debited again).
  ///
  /// Returns true only when a fresh purchase was made and committed.
  Future<bool> purchaseCosmetic(Cosmetic cosmetic) async {
    if (cosmetic.unlock != CosmeticUnlock.purchase) return false;
    final profile = storage.loadProfile();
    // Idempotency: already owned -> no debit, no-op.
    if (profile.purchasedCosmetics.contains(cosmetic.name)) return false;
    // Overspend guard: can't afford -> no debit.
    if (profile.coins < cosmetic.price) return false;

    final newCoins = profile.coins - cosmetic.price;
    final purchased = {...profile.purchasedCosmetics, cosmetic.name};
    await storage.saveProfile(profile.copyWith(
      coins: newCoins,
      purchasedCosmetics: purchased,
    ));
    emit(state.copyWith(
      coins: newCoins,
      unlockedCosmetics: {...state.unlockedCosmetics, cosmetic},
    ));
    return true;
  }

  // ---------------------------------------------------------------------------
  // Daily / weekly / monthly prize constants
  // ---------------------------------------------------------------------------

  /// Minimal daily top-3 coin rewards.
  static const _dailyCoins = {1: 50, 2: 30, 3: 15};

  static const _weeklyCoins = {1: 500, 2: 250, 3: 100};

  /// Big monthly top-3 coin rewards.
  static const _monthlyCoins = {1: 2000, 2: 1000, 3: 500};

  // ---------------------------------------------------------------------------
  // Daily prize helpers
  // ---------------------------------------------------------------------------

  /// Check if the player placed top-3 in yesterday's daily leaderboard for any
  /// non-challenge tier. Idempotent: the `lastDailyPrizeDate` guard prevents
  /// double-granting. [fetchFn] matches [LeaderboardService.fetch]'s signature.
  Future<void> checkDailyPrizes(
    Future<List<LeaderboardEntry>> Function({
      required Difficulty difficulty,
      required String date,
    }) fetchFn,
  ) async {
    final today = todayProvider();
    final yesterday = previousUtcDay(today);

    final profile = storage.loadProfile();
    if (profile.lastDailyPrizeDate == yesterday) return;

    int? bestRank;
    for (final difficulty in Difficulty.values) {
      if (difficulty == Difficulty.challenge) continue;
      try {
        final entries = await fetchFn(difficulty: difficulty, date: yesterday);
        final myEntry = entries.where((e) => e.isMe).firstOrNull;
        if (myEntry == null) continue;
        if (_dailyCoins.containsKey(myEntry.rank)) {
          if (bestRank == null || myEntry.rank < bestRank) {
            bestRank = myEntry.rank;
          }
        }
      } catch (_) {
        return; // network failure: skip; retry on next app open
      }
    }

    final coins = bestRank != null ? (_dailyCoins[bestRank] ?? 0) : 0;
    final updatedProfile = profile.copyWith(
      lastDailyPrizeDate: yesterday,
      coins: profile.coins + coins,
    );
    await storage.saveProfile(updatedProfile);
    if (coins > 0) emit(state.copyWith(coins: updatedProfile.coins));
  }

  // ---------------------------------------------------------------------------
  // Weekly prize helpers
  // ---------------------------------------------------------------------------

  /// Returns the Monday of the most recent completed ISO week (last Monday in UTC).
  /// "Last Monday" = today if today IS Monday, else the preceding Monday.
  static String _lastMonday(String today) {
    final d = DateTime.parse(today);
    // weekday: Mon=1 ... Sun=7
    final daysSinceMonday = (d.weekday - 1) % 7;
    final monday = d.subtract(Duration(days: daysSinceMonday));
    return monday.toIso8601String().substring(0, 10);
  }

  static String _lastSunday(String monday) {
    final m = DateTime.parse(monday);
    return m.add(const Duration(days: 6)).toIso8601String().substring(0, 10);
  }

  /// Check if the player placed top-3 in last week's leaderboard for any tier.
  /// Idempotent: the `lastWeeklyPrizeDate` guard prevents double-granting.
  /// [fetchPeriod] is the transport seam — matches [LeaderboardService.fetchPeriod]'s signature.
  Future<void> checkWeeklyPrizes(
    Future<List<LeaderboardEntry>> Function({
      required Difficulty difficulty,
      required String from,
      required String to,
    }) fetchPeriod,
  ) async {
    final today = todayProvider();
    final lastMonday = _lastMonday(today);
    final lastSunday = _lastSunday(lastMonday);

    final profile = storage.loadProfile();
    if (profile.lastWeeklyPrizeDate == lastMonday) return; // already checked this week

    int? bestRank; // best (lowest) rank across all non-challenge tiers
    final newCrowns = <WeeklyPrize>[];

    for (final difficulty in Difficulty.values) {
      if (difficulty == Difficulty.challenge) continue; // challenge has its own payout
      try {
        final entries = await fetchPeriod(
          difficulty: difficulty,
          from: lastMonday,
          to: lastSunday,
        );
        final myEntry = entries.where((e) => e.isMe).firstOrNull;
        if (myEntry == null) continue;
        if (_weeklyCoins.containsKey(myEntry.rank)) {
          // Track best rank (lower = better)
          if (bestRank == null || myEntry.rank < bestRank) {
            bestRank = myEntry.rank;
          }
          newCrowns.add(WeeklyPrize(
            weekStart: lastMonday,
            tier: difficulty,
            rank: myEntry.rank,
          ));
        }
      } catch (_) {
        // Network failure: skip this tier, try on next launch.
      }
    }

    // Award coins once for the best rank achieved across all tiers this week.
    final totalCoins = bestRank != null ? (_weeklyCoins[bestRank] ?? 0) : 0;

    final updatedProfile = profile.copyWith(
      lastWeeklyPrizeDate: lastMonday,
      weeklyPrizes: [...profile.weeklyPrizes, ...newCrowns],
      coins: profile.coins + totalCoins,
    );
    await storage.saveProfile(updatedProfile);

    emit(state.copyWith(
      coins: updatedProfile.coins,
      weeklyPrizes: updatedProfile.weeklyPrizes,
    ));
  }

  // ---------------------------------------------------------------------------
  // Monthly prize helpers
  // ---------------------------------------------------------------------------

  /// `YYYY-MM` for the calendar month BEFORE [today].
  static String _lastMonthKey(String today) {
    final d = DateTime.parse(today);
    final prev = DateTime.utc(d.year, d.month - 1, 1);
    return '${prev.year.toString().padLeft(4, '0')}-${prev.month.toString().padLeft(2, '0')}';
  }

  static String _firstOfMonth(String yyyyMM) => '$yyyyMM-01';

  static String _lastOfMonth(String yyyyMM) {
    final parts = yyyyMM.split('-');
    final year = int.parse(parts[0]);
    final month = int.parse(parts[1]);
    // Last day = day 0 of next month.
    final last = DateTime.utc(year, month + 1, 0);
    return formatDate(last);
  }

  /// Check if the player placed top-3 in last calendar month's leaderboard for
  /// any non-challenge tier. Idempotent: `lastMonthlyPrizeMonth` guards it.
  Future<void> checkMonthlyPrizes(
    Future<List<LeaderboardEntry>> Function({
      required Difficulty difficulty,
      required String from,
      required String to,
    }) fetchPeriod,
  ) async {
    final today = todayProvider();
    final monthKey = _lastMonthKey(today);

    final profile = storage.loadProfile();
    if (profile.lastMonthlyPrizeMonth == monthKey) return;

    final from = _firstOfMonth(monthKey);
    final to = _lastOfMonth(monthKey);

    int? bestRank;
    for (final difficulty in Difficulty.values) {
      if (difficulty == Difficulty.challenge) continue;
      try {
        final entries =
            await fetchPeriod(difficulty: difficulty, from: from, to: to);
        final myEntry = entries.where((e) => e.isMe).firstOrNull;
        if (myEntry == null) continue;
        if (_monthlyCoins.containsKey(myEntry.rank)) {
          if (bestRank == null || myEntry.rank < bestRank) {
            bestRank = myEntry.rank;
          }
        }
      } catch (_) {
        return;
      }
    }

    final coins = bestRank != null ? (_monthlyCoins[bestRank] ?? 0) : 0;
    final updatedProfile = profile.copyWith(
      lastMonthlyPrizeMonth: monthKey,
      coins: profile.coins + coins,
    );
    await storage.saveProfile(updatedProfile);
    if (coins > 0) emit(state.copyWith(coins: updatedProfile.coins));
  }

  // ---------------------------------------------------------------------------
  // Challenge payout helpers
  // ---------------------------------------------------------------------------

  static int _challengeCoinForRank(int rank) {
    if (rank == 1) return 150;
    if (rank <= 3) return 100;
    if (rank <= 10) return 50;
    return 0;
  }

  /// Check if the player placed top-10 in yesterday's challenge leaderboard.
  /// [fetchFn] matches [LeaderboardService.fetch]'s signature.
  Future<void> checkChallengePayouts(
    Future<List<LeaderboardEntry>> Function({
      required Difficulty difficulty,
      required String date,
    }) fetchFn,
  ) async {
    final today = todayProvider();
    final yesterday = previousUtcDay(today);

    final profile = storage.loadProfile();
    if (profile.lastChallengeCheckDate == yesterday) return; // already checked

    int coins = 0;
    try {
      final entries = await fetchFn(
        difficulty: Difficulty.challenge,
        date: yesterday,
      );
      final myEntry = entries.where((e) => e.isMe).firstOrNull;
      if (myEntry != null) {
        coins = _challengeCoinForRank(myEntry.rank);
      }
    } catch (_) {
      return; // network failure: skip; retry on next app open
    }

    final updatedProfile = profile.copyWith(
      lastChallengeCheckDate: yesterday,
      coins: profile.coins + coins,
    );
    await storage.saveProfile(updatedProfile);

    emit(state.copyWith(coins: updatedProfile.coins));
  }

  /// Grant a streak-freeze token (e.g. from a rewarded ad). Banked on every tier
  /// up to [kMaxFreezeTokens] each, so a missed day is shielded regardless of
  /// which tier the player resumes. Returns whether anything was granted.
  Future<bool> grantFreezeToken() async {
    var grantedAny = false;
    for (final d in Difficulty.values) {
      final stats = storage.loadStats(d);
      if (stats.streakFreezeTokens < kMaxFreezeTokens) {
        await storage.saveStats(
            d,
            stats.copyWith(
                streakFreezeTokens: stats.streakFreezeTokens + 1));
        grantedAny = true;
      }
    }
    if (grantedAny) {
      emit(state.copyWith(freezeTokens: _maxTierFreezeTokens()));
    }
    return grantedAny;
  }

  // --- helpers ---

  /// The headline freeze-token count = the max banked across any tier (a single
  /// token anywhere can bridge the missed day for the headline streak).
  int _maxTierFreezeTokens() {
    var m = 0;
    for (final d in Difficulty.values) {
      final t = storage.loadStats(d).streakFreezeTokens;
      if (t > m) m = t;
    }
    return m;
  }

  /// Consume one freeze token from the tier holding the most (deterministic).
  Future<void> _consumeOneFreezeToken() async {
    Difficulty? best;
    var bestCount = 0;
    for (final d in Difficulty.values) {
      final t = storage.loadStats(d).streakFreezeTokens;
      if (t > bestCount) {
        bestCount = t;
        best = d;
      }
    }
    if (best == null || bestCount <= 0) return;
    final stats = storage.loadStats(best);
    await storage.saveStats(
        best, stats.copyWith(streakFreezeTokens: stats.streakFreezeTokens - 1));
  }

  /// Build a [PlayerProgress] snapshot from per-tier stats + profile rank data.
  PlayerProgress _buildProgress({required int dailyActiveStreak}) {
    final perTierStreak = <Difficulty, int>{};
    final bestTier = <Difficulty, int>{};
    for (final d in Difficulty.values) {
      final s = storage.loadStats(d);
      perTierStreak[d] = s.streak;
      bestTier[d] = s.bestTier;
    }
    final profile = storage.loadProfile();
    final bestRank = profile.bestRankByDifficulty.map(
        (k, v) => MapEntry(Difficulty.values.byName(k), v));
    return PlayerProgress(
      dailyActiveStreak: dailyActiveStreak,
      perTierStreak: perTierStreak,
      bestTierByDifficulty: bestTier,
      bestRankByDifficulty: bestRank,
    );
  }

  Set<Achievement> _decodeAchievements(Set<String> names) => names
      .map((n) => Achievement.values
          .where((a) => a.name == n)
          .cast<Achievement?>()
          .firstWhere((a) => true, orElse: () => null))
      .whereType<Achievement>()
      .toSet();

  Set<Cosmetic> _decodeCosmetics(Set<String> names) =>
      names.map(_cosmeticByName).toSet();

  Cosmetic _cosmeticByName(String name) {
    for (final c in Cosmetic.values) {
      if (c.name == name) return c;
    }
    return Cosmetic.defaultCosmetic;
  }
}
