/// The daily-selected special rule for a Challenge mode board.
///
/// The index within [values] is the seed-derived index:
///   `Prng(DailySeeder.seedForKey('$date:challenge')).nextInt(6)`.
/// The index must NEVER change (it is part of the deterministic contract).
enum ChallengeRule {
  budgetCut,      // 0 — 15 moves instead of 30
  longChainsOnly, // 1 — chains of length < 3 are rejected
  denseStart,     // 2 — starting fill = 14
  sparseStart,    // 3 — starting fill = 3
  wallMaze,       // 4 — 8 seed-placed wall cells
  comboRush,      // 5 — comboMultiplier doubled for N>=3
}

extension ChallengeRuleLabel on ChallengeRule {
  String get label => switch (this) {
        ChallengeRule.budgetCut => 'Budget Cut',
        ChallengeRule.longChainsOnly => 'Long Chains Only',
        ChallengeRule.denseStart => 'Dense Start',
        ChallengeRule.sparseStart => 'Sparse Start',
        ChallengeRule.wallMaze => 'Wall Maze',
        ChallengeRule.comboRush => 'Combo Rush',
      };

  String get description => switch (this) {
        ChallengeRule.budgetCut => 'Only 15 moves. Make each one count.',
        ChallengeRule.longChainsOnly => 'Chains must be 3+ tiles. No quick pairs.',
        ChallengeRule.denseStart => 'Board starts nearly full. Plan ahead.',
        ChallengeRule.sparseStart => 'Board starts almost empty. Build your way up.',
        ChallengeRule.wallMaze => '8 walls block your paths. Navigate carefully.',
        ChallengeRule.comboRush => 'Chains of 3+ score double. Chain everything.',
      };
}
