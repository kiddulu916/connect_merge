import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/date_utils.dart'
    show formatDate, mondayOfWeek, parseUtcDate, previousUtcDay;
import '../../domain/models/difficulty.dart';
import '../../domain/models/weekly_prize.dart';
import '../../infrastructure/storage_service.dart';
import '../engagement_cubit.dart' show EngagementState;

/// Period-based prize checking (daily / weekly / monthly boards + the daily
/// Challenge payout), split out of [EngagementCubit] for file size. Structural
/// extraction only — no behavior change. See the doc comment on
/// `EngagementCubit` for the full completion-hook picture; this mixin owns
/// everything downstream of "a period has closed, go pay out ranks."
///
/// Split into a separate library (file), so the two members other parts of
/// `EngagementCubit` depend on ([serializedPrizeCommit], used by
/// `markTutorialSeen`, and the [storage]/[todayProvider]/[onErrorHook]
/// plumbing) are exposed without a leading underscore — Dart privacy is
/// per-library, so a `_`-prefixed member declared here would be invisible to
/// the main class body in `engagement_cubit.dart`. Everything else below that
/// only this mixin touches stays privately-named as before.
mixin PrizeCheckingMixin on Cubit<EngagementState> {
  /// Provided by [EngagementCubit].
  StorageService get storage;

  /// Provided by [EngagementCubit].
  String Function() get todayProvider;

  /// Provided by [EngagementCubit] (backs its `onError` constructor param).
  void Function(Object error, StackTrace? stack, {bool fatal})? get onErrorHook;

  Future<void> _prizeCommit = Future.value();

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

  /// Serializes all local-storage writes made by prize checks (and, via
  /// [EngagementCubit.markTutorialSeen], the tutorial-seen flag) so concurrent
  /// callers cannot clobber each other's freshly loaded profile. Non-private
  /// because `markTutorialSeen` — which stays on the `EngagementCubit` class
  /// body in a different file — queues through this same commit chain.
  Future<void> serializedPrizeCommit(Future<void> Function() body) {
    final commit = _prizeCommit.then((_) async {
      try {
        await body();
      } catch (error, stack) {
        onErrorHook?.call(error, stack);
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

  Map<Difficulty, int> _nonChallengeRanks(
    Map<Difficulty, int>? inner,
  ) =>
      Map<Difficulty, int>.fromEntries(
        (inner ?? const {}).entries.where(
              (entry) => entry.key != Difficulty.challenge,
            ),
      );

  Map<Difficulty, int> _challengeOnlyRanks(
    Map<Difficulty, int>? inner,
  ) {
    final challengeRank = inner?[Difficulty.challenge];
    return challengeRank == null
        ? const <Difficulty, int>{}
        : {Difficulty.challenge: challengeRank};
  }

  List<WeeklyPrize> _weeklyCrowns(
    Map<Difficulty, int> ranks,
    String weekFrom,
  ) =>
      ranks.entries
          .where((entry) => _weeklyCoinsFor(entry.value) > 0)
          .map((entry) => WeeklyPrize(
                weekStart: weekFrom,
                tier: entry.key,
                rank: entry.value,
              ))
          .toList();

  Future<void> _checkPeriod({
    required List<String> periodKeys,
    required Future<Map<Difficulty, int>?> Function(String key) ranksFor,
    required String? Function(PlayerProfile) guardOf,
    required int Function(int rank) coinsFor,
    required PlayerProfile Function(
      PlayerProfile profile,
      String key,
      int coins,
      Map<Difficulty, int> ranks,
    ) award,
    required bool syncWeeklyPrizes,
  }) async {
    for (final key in periodKeys) {
      final ranks = await ranksFor(key);
      if (ranks == null) break;
      await serializedPrizeCommit(() async {
        final profile = storage.loadProfile();
        final storedGuard = guardOf(profile);
        if (storedGuard != null && storedGuard.compareTo(key) >= 0) return;
        final bestRank = _bestQualifyingRank(ranks, coinsFor);
        final coins = bestRank == null ? 0 : coinsFor(bestRank);
        final updated = award(profile, key, coins, ranks);
        await storage.saveProfile(updated);
        // Preserve each path's original emit exactly: coins-only paths must
        // not synchronize weekly prizes from a separately loaded profile.
        if (syncWeeklyPrizes) {
          if (updated.wallet.coins != state.coins ||
              !_sameWeeklyPrizes(
                  updated.prizes.weeklyPrizes, state.weeklyPrizes)) {
            emit(state.copyWith(
              coins: updated.wallet.coins,
              weeklyPrizes: updated.prizes.weeklyPrizes,
            ));
          }
        } else {
          if (updated.wallet.coins != state.coins) {
            emit(state.copyWith(coins: updated.wallet.coins));
          }
        }
      });
      final committed = guardOf(storage.loadProfile());
      if (committed == null || committed.compareTo(key) < 0) break;
    }
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
      onErrorHook?.call(error, stack);
      return;
    }

    await _checkPeriod(
      periodKeys: dates,
      ranksFor: (date) async => _nonChallengeRanks(ranksByDate[date]),
      guardOf: (profile) => profile.prizes.lastDailyPrizeDate,
      coinsFor: _dailyCoinsFor,
      award: (profile, key, coins, _) =>
          profile.awardDailyPrize(key, awardCoins: coins),
      syncWeeklyPrizes: false,
    );
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
    await _checkPeriod(
      periodKeys: weeks,
      ranksFor: (weekFrom) async {
        final weekTo = _weekSunday(weekFrom);
        final Map<Difficulty, int> fetched;
        try {
          fetched = await fetchRanks(from: weekFrom, to: weekTo);
        } catch (error, stack) {
          onErrorHook?.call(error, stack);
          return null;
        }
        return _nonChallengeRanks(fetched);
      },
      guardOf: (profile) => profile.prizes.lastWeeklyPrizeDate,
      coinsFor: _weeklyCoinsFor,
      award: (profile, key, coins, ranks) => profile.awardWeeklyPrize(
        key,
        awardCoins: coins,
        crowns: _weeklyCrowns(ranks, key),
      ),
      syncWeeklyPrizes: true,
    );
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
    await _checkPeriod(
      periodKeys: months,
      ranksFor: (monthKey) async {
        final Map<Difficulty, int> fetched;
        try {
          fetched = await fetchRanks(
            from: _firstOfMonth(monthKey),
            to: _lastOfMonth(monthKey),
          );
        } catch (error, stack) {
          onErrorHook?.call(error, stack);
          return null;
        }
        return _nonChallengeRanks(fetched);
      },
      guardOf: (profile) => profile.prizes.lastMonthlyPrizeMonth,
      coinsFor: _monthlyCoinsFor,
      award: (profile, key, coins, _) =>
          profile.awardMonthlyPrize(key, awardCoins: coins),
      syncWeeklyPrizes: false,
    );
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
      onErrorHook?.call(error, stack);
      return;
    }

    await _checkPeriod(
      periodKeys: dates,
      ranksFor: (date) async => _challengeOnlyRanks(ranksByDate[date]),
      guardOf: (profile) => profile.prizes.lastChallengeCheckDate,
      coinsFor: _challengeCoinsFor,
      award: (profile, key, coins, _) =>
          profile.awardChallengeCheck(key, awardCoins: coins),
      syncWeeklyPrizes: false,
    );
  }
}
