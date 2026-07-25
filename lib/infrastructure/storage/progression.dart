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
