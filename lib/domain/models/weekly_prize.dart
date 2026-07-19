import 'difficulty.dart';

/// A permanent record of a rank 1–5 weekly leaderboard finish.
class WeeklyPrize {
  /// ISO week-start date (Monday), e.g. `"2026-06-22"`.
  final String weekStart;

  /// Which difficulty tier this prize was earned on.
  final Difficulty tier;

  /// Leaderboard rank (1–5).
  final int rank;

  const WeeklyPrize({
    required this.weekStart,
    required this.tier,
    required this.rank,
  });

  Map<String, dynamic> toJson() => {
        'weekStart': weekStart,
        'tier': tier.name,
        'rank': rank,
      };

  static WeeklyPrize fromJson(Map<String, dynamic> j) => WeeklyPrize(
        weekStart: j['weekStart'] as String,
        tier: Difficulty.values.byName(j['tier'] as String),
        rank: j['rank'] as int,
      );
}
