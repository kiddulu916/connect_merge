import 'package:flutter_bloc/flutter_bloc.dart';

import '../domain/engine/almanac_progress.dart';
import '../domain/models/achievement.dart';
import '../domain/models/almanac.dart';
import '../domain/models/cosmetic.dart';
import '../domain/models/difficulty.dart';
import '../domain/models/player_level.dart';
import '../domain/models/streak.dart';
import '../infrastructure/storage_service.dart';
import 'game_cubit.dart' show utcToday;

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
