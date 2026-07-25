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
