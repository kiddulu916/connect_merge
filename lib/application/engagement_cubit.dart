import 'package:flutter_bloc/flutter_bloc.dart';

import '../domain/date_utils.dart'
    show formatDate, mondayOfWeek, parseUtcDate, previousUtcDay, utcToday;
import '../domain/engine/almanac_progress.dart';
import '../domain/models/achievement.dart';
import '../domain/models/almanac.dart';
import '../domain/models/cosmetic.dart';
import '../domain/models/difficulty.dart';
import '../domain/models/player_level.dart';
import '../domain/models/streak.dart' show nextStreak;
import '../domain/models/weekly_prize.dart';
import '../infrastructure/storage_service.dart';

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

  /// Permanent history of weekly rank 1–5 finishes for the "Your Crowns" UI.
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
        lastActiveDate: clearLastActiveDate
            ? null
            : (lastActiveDate ?? this.lastActiveDate),
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

  /// Optional error-reporting hook (observability). Fired for exceptions that
  /// are currently swallowed silently. Signature matches
  /// `CrashReportingService.recordError` exactly, so callers can pass the
  /// method directly (e.g. `onError: crashReporting.recordError`).
  ///
  /// Stored as a private field (`_onError`) rather than `this.onError`
  /// because `Cubit`/`BlocBase` already declares an inherited instance
  /// method named `onError` (its internal stream-error hook) — a field of
  /// the same name is not a compatible override and fails to compile (this
  /// was discovered and fixed the same way in `GameCubit`, Task 5). The
  /// public constructor parameter is still named `onError` so callers are
  /// unaffected.
  final void Function(Object error, StackTrace? stack, {bool fatal})? _onError;

  /// Optional analytics hook (observability). Signature matches
  /// `AnalyticsService.logEvent` exactly.
  final void Function(String name, [Map<String, Object?>? params])?
      onAnalyticsEvent;

  Future<void> _prizeCommit = Future.value();

  EngagementCubit({
    required this.storage,
    String Function()? todayProvider,
    void Function(Object error, StackTrace? stack, {bool fatal})? onError,
    this.onAnalyticsEvent,
  })  : todayProvider = todayProvider ?? utcToday,
        _onError = onError,
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
      freezeTokens: _maxTierFreezeTokens(),
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
    final hasFreeze = _maxTierFreezeTokens() > 0;
    final result = nextStreak(
      prev: profile.activity.dailyActiveStreak,
      last: profile.activity.lastActiveDate,
      today: today,
      hasFreeze: hasFreeze,
    );
    if (result.freezeConsumed) {
      await _consumeOneFreezeToken();
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
      freezeTokens: _maxTierFreezeTokens(),
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

  /// Select a cosmetic. Gated on the unlocked set — selecting a locked cosmetic
  /// is a no-op (harmless exploit prevention).
  Future<void> selectCosmetic(Cosmetic cosmetic) async {
    if (!state.unlockedCosmetics.contains(cosmetic)) return;
    final profile = storage.loadProfile();
    await storage.saveProfile(profile.selectCosmetic(cosmetic.name));
    emit(state.copyWith(selectedCosmetic: cosmetic));
  }

  /// Grant an ad-unlocked cosmetic (after a rewarded ad). Only valid for
  /// [CosmeticUnlock.rewardedAd] cosmetics.
  Future<void> grantAdCosmetic(Cosmetic cosmetic) async {
    if (cosmetic.unlock != CosmeticUnlock.rewardedAd) return;
    final profile = storage.loadProfile();
    await storage.saveProfile(profile.grantAdCosmetic(cosmetic.name));
    emit(state.copyWith(
      unlockedCosmetics: {...state.unlockedCosmetics, cosmetic},
    ));
  }

  /// Re-sync the wallet balance from storage into state (Phase 2). Coins can be
  /// credited outside this cubit (golden tiles, loot chest), so call this before
  /// gating a purchase so the displayed balance is current. No-op if unchanged.
  void refreshWallet() {
    final coins = storage.loadProfile().wallet.coins;
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
    if (profile.cosmetics.purchasedCosmetics.contains(cosmetic.name)) {
      return false;
    }
    // Overspend guard: can't afford -> no debit.
    if (profile.wallet.coins < cosmetic.price) return false;

    final newCoins = profile.wallet.coins - cosmetic.price;
    await storage.saveProfile(
      profile.recordPurchase(cosmetic.name, price: cosmetic.price),
    );
    emit(state.copyWith(
      coins: newCoins,
      unlockedCosmetics: {...state.unlockedCosmetics, cosmetic},
    ));
    return true;
  }

  // ---------------------------------------------------------------------------
  // Daily / weekly / monthly prize constants
  // ---------------------------------------------------------------------------

  static const _dailyCoins = {1: 50, 2: 30, 3: 15, 4: 10, 5: 5};

  static const _weeklyCoins = {1: 75, 2: 45, 3: 25, 4: 15, 5: 10};

  static const _monthlyCoins = {1: 100, 2: 60, 3: 35, 4: 20, 5: 15};

  static int _dailyCoinsFor(int rank) => _dailyCoins[rank] ?? 0;

  static int _weeklyCoinsFor(int rank) => _weeklyCoins[rank] ?? 0;

  static int _monthlyCoinsFor(int rank) => _monthlyCoins[rank] ?? 0;

  static int _challengeCoinsFor(int rank) {
    if (rank < 1) return 0;
    if (rank == 1) return 20;
    if (rank <= 3) return 15;
    if (rank <= 6) return 10;
    if (rank <= 10) return 5;
    return 0;
  }

  /// One payout per period: the best qualifying rank across eligible tiers.
  static int? _bestQualifyingRank(
    Map<Difficulty, int> ranks,
    int Function(int) coinsForRank,
  ) {
    int? best;
    for (final rank in ranks.values) {
      if (coinsForRank(rank) > 0 && (best == null || rank < best)) {
        best = rank;
      }
    }
    return best;
  }

  static List<String> _boundedDateKeys(
    String? guard,
    String latest, {
    required int stepDays,
    required int limit,
  }) {
    if (guard == null) return [latest];
    if (guard.compareTo(latest) >= 0) return const [];
    final latestDate = parseUtcDate(latest);
    final oldest = formatDate(DateTime.utc(
      latestDate.year,
      latestDate.month,
      latestDate.day - stepDays * (limit - 1),
    ));
    final guardDate = parseUtcDate(guard);
    final afterGuard = formatDate(DateTime.utc(
      guardDate.year,
      guardDate.month,
      guardDate.day + stepDays,
    ));
    var current = parseUtcDate(
      afterGuard.compareTo(oldest) > 0 ? afterGuard : oldest,
    );
    final result = <String>[];
    while (formatDate(current).compareTo(latest) <= 0) {
      result.add(formatDate(current));
      current = DateTime.utc(
        current.year,
        current.month,
        current.day + stepDays,
      );
    }
    return result;
  }

  static String _shiftMonth(String monthKey, int offset) {
    final parts = monthKey.split('-');
    final shifted = DateTime.utc(
      int.parse(parts[0]),
      int.parse(parts[1]) + offset,
      1,
    );
    return '${shifted.year.toString().padLeft(4, '0')}-'
        '${shifted.month.toString().padLeft(2, '0')}';
  }

  static List<String> _boundedMonthKeys(String? guard, String latest) {
    if (guard == null) return [latest];
    if (guard.compareTo(latest) >= 0) return const [];
    final oldest = _shiftMonth(latest, -1);
    var current = _shiftMonth(guard, 1);
    if (current.compareTo(oldest) < 0) current = oldest;
    final result = <String>[];
    while (current.compareTo(latest) <= 0) {
      result.add(current);
      current = _shiftMonth(current, 1);
    }
    return result;
  }

  static bool _sameWeeklyPrizes(
    List<WeeklyPrize> left,
    List<WeeklyPrize> right,
  ) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      final a = left[i];
      final b = right[i];
      if (a.weekStart != b.weekStart || a.tier != b.tier || a.rank != b.rank) {
        return false;
      }
    }
    return true;
  }

  Future<void> _serializedPrizeCommit(Future<void> Function() body) {
    final commit = _prizeCommit.then((_) async {
      try {
        await body();
      } catch (error, stack) {
        _onError?.call(error, stack);
        final persisted = storage.loadProfile();
        if (persisted.wallet.coins != state.coins ||
            !_sameWeeklyPrizes(
                persisted.prizes.weeklyPrizes, state.weeklyPrizes)) {
          emit(state.copyWith(
            coins: persisted.wallet.coins,
            weeklyPrizes: persisted.prizes.weeklyPrizes,
          ));
        }
      }
    });
    _prizeCommit = commit;
    return commit;
  }

  /// Durably records first-launch tutorial completion in the same local-write
  /// queue as startup prize commits, so neither writer can overwrite the
  /// other's freshly loaded profile. The queue deliberately swallows storage
  /// errors, so callers receive the persisted verification result.
  Future<bool> markTutorialSeen() async {
    await _serializedPrizeCommit(() async {
      final profile = storage.loadProfile();
      if (profile.settings.tutorialSeen) return;
      await storage.saveProfile(profile.copyWith(
        settings: profile.settings.copyWith(tutorialSeen: true),
      ));
    });
    return storage.loadProfile().settings.tutorialSeen;
  }

  // ---------------------------------------------------------------------------
  // Daily prize helpers
  // ---------------------------------------------------------------------------

  /// Pay each unclaimed closed daily board, up to seven days oldest-first.
  Future<void> checkDailyPrizes(
    Future<Map<String, Map<Difficulty, int>>> Function({
      required String from,
      required String to,
    }) fetchRanks,
  ) async {
    final yesterday = previousUtcDay(todayProvider());
    final guard = storage.loadProfile().prizes.lastDailyPrizeDate;
    final dates = _boundedDateKeys(
      guard,
      yesterday,
      stepDays: 1,
      limit: 7,
    );
    if (dates.isEmpty) return;
    late final Map<String, Map<Difficulty, int>> ranksByDate;
    try {
      ranksByDate = await fetchRanks(from: dates.first, to: dates.last);
    } catch (error, stack) {
      _onError?.call(error, stack);
      return;
    }

    for (final date in dates) {
      final ranks = Map<Difficulty, int>.fromEntries(
        (ranksByDate[date] ?? const {}).entries.where(
              (entry) => entry.key != Difficulty.challenge,
            ),
      );
      await _serializedPrizeCommit(() async {
        final profile = storage.loadProfile();
        final storedGuard = profile.prizes.lastDailyPrizeDate;
        if (storedGuard != null && storedGuard.compareTo(date) >= 0) return;
        final bestRank = _bestQualifyingRank(ranks, _dailyCoinsFor);
        final coins = bestRank == null ? 0 : _dailyCoinsFor(bestRank);
        final updated = profile.awardDailyPrize(date, awardCoins: coins);
        await storage.saveProfile(updated);
        if (updated.wallet.coins != state.coins) {
          emit(state.copyWith(coins: updated.wallet.coins));
        }
      });
      final committed = storage.loadProfile().prizes.lastDailyPrizeDate;
      if (committed == null || committed.compareTo(date) < 0) break;
    }
  }

  // ---------------------------------------------------------------------------
  // Weekly prize helpers
  // ---------------------------------------------------------------------------

  /// Returns the Monday of the ISO week that contains [today].
  /// Monday=1 through Sunday=7 in Dart's weekday numbering.
  static String _thisWeekMonday(String today) => mondayOfWeek(today);

  /// Returns the Sunday that is 6 days after [monday].
  static String _weekSunday(String monday) {
    final m = parseUtcDate(monday);
    return formatDate(DateTime.utc(m.year, m.month, m.day + 6));
  }

  /// Returns the Monday of the most recently COMPLETED ISO week (Mon–Sun that
  /// ended before today). Mirrors the monthly prize logic: prizes are awarded
  /// once the period has fully closed, so the full week's data is available.
  static String _prevWeekMonday(String today) {
    final thisMonday = _thisWeekMonday(today);
    final d = parseUtcDate(thisMonday);
    return formatDate(DateTime.utc(d.year, d.month, d.day - 7));
  }

  /// Check rank 1–5 finishes across up to four unclaimed completed weeks.
  /// Each board is a fully closed Monday–Sunday range; the guard prevents
  /// double-granting and advances only through contiguous successful checks.
  Future<void> checkWeeklyPrizes(
    Future<Map<Difficulty, int>> Function({
      required String from,
      required String to,
    }) fetchRanks,
  ) async {
    final latestWeek = _prevWeekMonday(todayProvider());
    final guard = storage.loadProfile().prizes.lastWeeklyPrizeDate;
    final weeks = _boundedDateKeys(
      guard,
      latestWeek,
      stepDays: 7,
      limit: 4,
    );
    for (final weekFrom in weeks) {
      final weekTo = _weekSunday(weekFrom);
      late final Map<Difficulty, int> fetchedRanks;
      try {
        fetchedRanks = await fetchRanks(from: weekFrom, to: weekTo);
      } catch (error, stack) {
        _onError?.call(error, stack);
        break;
      }
      final ranks = Map<Difficulty, int>.fromEntries(
        fetchedRanks.entries.where(
          (entry) => entry.key != Difficulty.challenge,
        ),
      );

      await _serializedPrizeCommit(() async {
        final profile = storage.loadProfile();
        final storedGuard = profile.prizes.lastWeeklyPrizeDate;
        if (storedGuard != null && storedGuard.compareTo(weekFrom) >= 0) return;
        final bestRank = _bestQualifyingRank(ranks, _weeklyCoinsFor);
        final coins = bestRank == null ? 0 : _weeklyCoinsFor(bestRank);
        final crowns = ranks.entries
            .where((entry) => _weeklyCoinsFor(entry.value) > 0)
            .map((entry) => WeeklyPrize(
                  weekStart: weekFrom,
                  tier: entry.key,
                  rank: entry.value,
                ))
            .toList();
        final updated = profile.awardWeeklyPrize(
          weekFrom,
          awardCoins: coins,
          crowns: crowns,
        );
        await storage.saveProfile(updated);
        if (updated.wallet.coins != state.coins ||
            !_sameWeeklyPrizes(
                updated.prizes.weeklyPrizes, state.weeklyPrizes)) {
          emit(state.copyWith(
            coins: updated.wallet.coins,
            weeklyPrizes: updated.prizes.weeklyPrizes,
          ));
        }
      });
      final committed = storage.loadProfile().prizes.lastWeeklyPrizeDate;
      if (committed == null || committed.compareTo(weekFrom) < 0) break;
    }
  }

  // ---------------------------------------------------------------------------
  // Monthly prize helpers
  // ---------------------------------------------------------------------------

  /// `YYYY-MM` for the calendar month BEFORE [today].
  static String _lastMonthKey(String today) {
    final d = parseUtcDate(today);
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

  /// Check rank 1–5 finishes across unclaimed completed calendar months.
  Future<void> checkMonthlyPrizes(
    Future<Map<Difficulty, int>> Function({
      required String from,
      required String to,
    }) fetchRanks,
  ) async {
    final latestMonth = _lastMonthKey(todayProvider());
    final guard = storage.loadProfile().prizes.lastMonthlyPrizeMonth;
    final months = _boundedMonthKeys(guard, latestMonth);
    for (final monthKey in months) {
      final from = _firstOfMonth(monthKey);
      final to = _lastOfMonth(monthKey);
      late final Map<Difficulty, int> fetchedRanks;
      try {
        fetchedRanks = await fetchRanks(from: from, to: to);
      } catch (error, stack) {
        _onError?.call(error, stack);
        break;
      }
      final ranks = Map<Difficulty, int>.fromEntries(
        fetchedRanks.entries.where(
          (entry) => entry.key != Difficulty.challenge,
        ),
      );

      await _serializedPrizeCommit(() async {
        final profile = storage.loadProfile();
        final storedGuard = profile.prizes.lastMonthlyPrizeMonth;
        if (storedGuard != null && storedGuard.compareTo(monthKey) >= 0) return;
        final bestRank = _bestQualifyingRank(ranks, _monthlyCoinsFor);
        final coins = bestRank == null ? 0 : _monthlyCoinsFor(bestRank);
        final updated = profile.awardMonthlyPrize(monthKey, awardCoins: coins);
        await storage.saveProfile(updated);
        if (updated.wallet.coins != state.coins) {
          emit(state.copyWith(coins: updated.wallet.coins));
        }
      });
      final committed = storage.loadProfile().prizes.lastMonthlyPrizeMonth;
      if (committed == null || committed.compareTo(monthKey) < 0) break;
    }
  }

  // ---------------------------------------------------------------------------
  // Challenge payout helpers
  // ---------------------------------------------------------------------------

  /// Check top-10 finishes across up to seven unclaimed Challenge days.
  Future<void> checkChallengePayouts(
    Future<Map<String, Map<Difficulty, int>>> Function({
      required String from,
      required String to,
    }) fetchRanks,
  ) async {
    final yesterday = previousUtcDay(todayProvider());
    final guard = storage.loadProfile().prizes.lastChallengeCheckDate;
    final dates = _boundedDateKeys(
      guard,
      yesterday,
      stepDays: 1,
      limit: 7,
    );
    if (dates.isEmpty) return;
    late final Map<String, Map<Difficulty, int>> ranksByDate;
    try {
      ranksByDate = await fetchRanks(from: dates.first, to: dates.last);
    } catch (error, stack) {
      _onError?.call(error, stack);
      return;
    }

    for (final date in dates) {
      final challengeRank = ranksByDate[date]?[Difficulty.challenge];
      final ranks = challengeRank == null
          ? const <Difficulty, int>{}
          : {Difficulty.challenge: challengeRank};
      await _serializedPrizeCommit(() async {
        final profile = storage.loadProfile();
        final storedGuard = profile.prizes.lastChallengeCheckDate;
        if (storedGuard != null && storedGuard.compareTo(date) >= 0) return;
        final bestRank = _bestQualifyingRank(ranks, _challengeCoinsFor);
        final coins = bestRank == null ? 0 : _challengeCoinsFor(bestRank);
        final updated = profile.awardChallengeCheck(date, awardCoins: coins);
        await storage.saveProfile(updated);
        if (updated.wallet.coins != state.coins) {
          emit(state.copyWith(coins: updated.wallet.coins));
        }
      });
      final committed = storage.loadProfile().prizes.lastChallengeCheckDate;
      if (committed == null || committed.compareTo(date) < 0) break;
    }
  }

  /// Grant a streak-freeze token (e.g. from a rewarded ad). Banked on every tier
  /// up to [kMaxFreezeTokens] each, so a missed day is shielded regardless of
  /// which tier the player resumes. Returns whether anything was granted.
  Future<bool> grantFreezeToken() async {
    var grantedAny = false;
    for (final d in Difficulty.values) {
      final stats = storage.loadStats(d);
      if (stats.streakFreezeTokens < kMaxFreezeTokens) {
        await storage.saveStats(d,
            stats.copyWith(streakFreezeTokens: stats.streakFreezeTokens + 1));
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
}
