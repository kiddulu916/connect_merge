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
}

extension ChallengeRuleMinChainLength on ChallengeRule {
  /// Minimum legal Connect-Merge chain length under this rule. Every rule
  /// besides [ChallengeRule.longChainsOnly] uses the baseline of 2 (any legal
  /// merge counts); `longChainsOnly` raises it to 3. Single source for the
  /// reject-guard in `GameCubit.playChain` and every rule-aware deadlock/refill
  /// check in `GameEngine`/`DailySeeder`. Must stay in lockstep with the
  /// TypeScript `minChainLengthFor` in `constants.ts`.
  int get minChainLength =>
      this == ChallengeRule.longChainsOnly ? 3 : 2;
}
