import 'package:flutter_bloc/flutter_bloc.dart';

import '../domain/date_utils.dart' show previousUtcDay, utcToday;
import '../domain/engine/almanac_progress.dart';
import '../domain/models/achievement.dart';
import '../domain/models/almanac.dart';
import '../domain/models/avatar.dart';
import '../domain/models/cosmetic.dart';
import '../domain/models/difficulty.dart';
import '../domain/models/player_level.dart';
import '../domain/models/streak.dart' show nextStreak;
import '../domain/models/weekly_prize.dart';
import '../infrastructure/storage_service.dart';
import 'engagement/cosmetics_wallet_mixin.dart';
import 'engagement/prize_checking_mixin.dart';

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

  /// Currently selected avatar, as its emoji glyph (matches `players.avatar`).
  final String selectedAvatar;

  /// The full set of avatars currently unlocked (free + purchased).
  final Set<Avatar> unlockedAvatars;

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

  /// Permanent history of weekly rank 1–5 finishes for the "Your Crowns" UI.
  final List<WeeklyPrize> weeklyPrizes;

  const EngagementState({
    this.dailyActiveStreak = 0,
    this.lastActiveDate,
    this.unlocked = const {},
    this.newlyUnlocked = const {},
    this.selectedCosmetic = Cosmetic.classic,
    this.unlockedCosmetics = const {Cosmetic.classic},
    this.selectedAvatar = '🦊',
    this.unlockedAvatars = const {
      Avatar.fox,
      Avatar.cat,
      Avatar.panda,
      Avatar.frog,
      Avatar.unicorn,
      Avatar.octopus,
      Avatar.owl,
      Avatar.bee,
    },
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
    String? selectedAvatar,
    Set<Avatar>? unlockedAvatars,
    int? freezeTokens,
    int? coins,
    int? lifetimeXp,
    Almanac? almanac,
    List<WeeklyPrize>? weeklyPrizes,
  }) =>
      EngagementState(
        dailyActiveStreak: dailyActiveStreak ?? this.dailyActiveStreak,
        lastActiveDate: clearLastActiveDate
            ? null
            : (lastActiveDate ?? this.lastActiveDate),
        unlocked: unlocked ?? this.unlocked,
        newlyUnlocked: newlyUnlocked ?? this.newlyUnlocked,
        selectedCosmetic: selectedCosmetic ?? this.selectedCosmetic,
        unlockedCosmetics: unlockedCosmetics ?? this.unlockedCosmetics,
        selectedAvatar: selectedAvatar ?? this.selectedAvatar,
        unlockedAvatars: unlockedAvatars ?? this.unlockedAvatars,
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
///
/// Two families of logic are physically split into mixins under
/// `lib/application/engagement/` for file size — [PrizeCheckingMixin] (daily /
/// weekly / monthly / Challenge prize payouts) and [CosmeticsWalletMixin]
/// (cosmetics, wallet, freeze-token banking). Both are still part of this one
/// logical class: they're mixed in below, so `EngagementCubit` still exposes a
/// single flat API and every call site elsewhere in the repo is unaffected.
class EngagementCubit extends Cubit<EngagementState>
    with PrizeCheckingMixin, CosmeticsWalletMixin {
  @override
  final StorageService storage;
  @override
  final String Function() todayProvider;

  /// Optional error-reporting hook (observability). Fired for exceptions that
  /// are currently swallowed silently. Signature matches
  /// `CrashReportingService.recordError` exactly, so callers can pass the
  /// method directly (e.g. `onError: crashReporting.recordError`).
  ///
  /// Named `onErrorHook` (not `onError`) for two reasons: `Cubit`/`BlocBase`
  /// already declares an inherited instance method named `onError` (its
  /// internal stream-error hook), so a field of that name would not be a
  /// compatible override and would fail to compile (same pattern as
  /// `GameCubit`); and it's read by [PrizeCheckingMixin] in a different file
  /// (`lib/application/engagement/prize_checking_mixin.dart`) via an abstract
  /// getter, which requires a non-private name since Dart privacy is
  /// per-library. The public constructor parameter is still named `onError`
  /// so callers are unaffected.
  @override
  final void Function(Object error, StackTrace? stack, {bool fatal})?
      onErrorHook;

  /// Optional analytics hook (observability). Signature matches
  /// `AnalyticsService.logEvent` exactly.
  final void Function(String name, [Map<String, Object?>? params])?
      onAnalyticsEvent;

  EngagementCubit({
    required this.storage,
    String Function()? todayProvider,
    void Function(Object error, StackTrace? stack, {bool fatal})? onError,
    this.onAnalyticsEvent,
  })  : todayProvider = todayProvider ?? utcToday,
        onErrorHook = onError,
        super(const EngagementState());

  /// Hydrate from storage. Recomputes the unlocked sets from the loaded profile
  /// + per-tier stats so any externally-changed progress is reflected.
  void load() {
    final profile = storage.loadProfile();
    final unlocked =
        _decodeAchievements(profile.progression.unlockedAchievements);
    final adCosmetics = _decodeCosmetics(profile.cosmetics.adUnlockedCosmetics);
    final purchased = _decodeCosmetics(profile.cosmetics.purchasedCosmetics);
    emit(EngagementState(
      dailyActiveStreak: profile.activity.dailyActiveStreak,
      lastActiveDate: profile.activity.lastActiveDate,
      unlocked: unlocked,
      newlyUnlocked: const {},
      selectedCosmetic: _cosmeticByName(profile.cosmetics.selectedCosmetic),
      unlockedCosmetics: unlockedCosmetics(
        dailyActiveStreak: profile.activity.dailyActiveStreak,
        achievements: unlocked,
        adUnlocked: adCosmetics,
        purchased: purchased,
      ),
      selectedAvatar: profile.avatars.selectedAvatar,
      unlockedAvatars: unlockedAvatars(
        purchased: _decodeAvatars(profile.avatars.purchasedAvatars),
      ),
      freezeTokens: maxTierFreezeTokens(),
      coins: profile.wallet.coins,
      lifetimeXp: profile.progression.lifetimeXp,
      almanac: Almanac.fromStorage(profile.progression.almanacCounts),
      weeklyPrizes: profile.prizes.weeklyPrizes,
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
    final hasFreeze = maxTierFreezeTokens() > 0;
    final result = nextStreak(
      prev: profile.activity.dailyActiveStreak,
      last: profile.activity.lastActiveDate,
      today: today,
      hasFreeze: hasFreeze,
    );
    if (result.freezeConsumed) {
      await consumeOneFreezeToken();
    }
    // A genuine gap (a prior date exists, isn't today, isn't yesterday) that
    // no freeze token bridged is a direct churn-risk signal — surface it once,
    // using the streak length BEFORE the reset.
    final yesterday = previousUtcDay(today);
    final hadGap = profile.activity.lastActiveDate != null &&
        profile.activity.lastActiveDate != today &&
        profile.activity.lastActiveDate != yesterday;
    if (hadGap && !result.freezeConsumed) {
      onAnalyticsEvent?.call('streak_broken', {
        'streakType': 'daily',
        'length': profile.activity.dailyActiveStreak,
      });
    }

    // --- Progress + achievements. ---
    final progress = _buildProgress(dailyActiveStreak: result.streak);
    final already =
        _decodeAchievements(profile.progression.unlockedAchievements);
    final fresh = newlyUnlocked(progress, already);
    final allUnlocked = already.union(fresh);

    // --- Cosmetics. ---
    final adCosmetics = _decodeCosmetics(profile.cosmetics.adUnlockedCosmetics);
    final purchased = _decodeCosmetics(profile.cosmetics.purchasedCosmetics);
    final cosmetics = unlockedCosmetics(
      dailyActiveStreak: result.streak,
      achievements: allUnlocked,
      adUnlocked: adCosmetics,
      purchased: purchased,
    );

    // --- Meta-progression: XP + Almanac (pure client-side flair). ---
    final lifetimeXp = profile.progression.lifetimeXp + xpForScore(score);
    final almanacCounts =
        foldRunIntoAlmanac(profile.progression.almanacCounts, highestTier);

    final updated = profile.advanceActivity(
      streak: result.streak,
      date: today,
      achievements: allUnlocked.map((a) => a.name).toSet(),
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
      freezeTokens: maxTierFreezeTokens(),
      coins: updated.wallet.coins,
      lifetimeXp: lifetimeXp,
      almanac: Almanac.fromStorage(almanacCounts),
    ));
  }

  /// Clear the one-shot newly-unlocked set after the result screen has shown it.
  void acknowledgeNewlyUnlocked() {
    if (state.newlyUnlocked.isEmpty) return;
    emit(state.copyWith(newlyUnlocked: const {}));
  }

  /// Durably records first-launch tutorial completion in the same local-write
  /// queue as startup prize commits, so neither writer can overwrite the
  /// other's freshly loaded profile. The queue deliberately swallows storage
  /// errors, so callers receive the persisted verification result.
  Future<bool> markTutorialSeen() async {
    await serializedPrizeCommit(() async {
      final profile = storage.loadProfile();
      if (profile.settings.tutorialSeen) return;
      await storage.saveProfile(profile.copyWith(
        settings: profile.settings.copyWith(tutorialSeen: true),
      ));
    });
    return storage.loadProfile().settings.tutorialSeen;
  }

  // --- helpers ---

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
    final bestRank = profile.progression.bestRankByDifficulty
        .map((k, v) => MapEntry(Difficulty.values.byName(k), v));
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

  /// Decode persisted avatar names to [Avatar]s, dropping any unrecognized
  /// token (e.g. a retired avatar) rather than defaulting it in.
  Set<Avatar> _decodeAvatars(Set<String> names) {
    final out = <Avatar>{};
    for (final name in names) {
      for (final a in Avatar.values) {
        if (a.name == name) {
          out.add(a);
          break;
        }
      }
    }
    return out;
  }
}
