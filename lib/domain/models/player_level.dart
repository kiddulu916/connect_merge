import 'dart:math' as math;

import '../constants.dart';

/// Pure player-level / XP math (Phase 2).
///
/// XP is a purely client-side flair derived from already-recorded cumulative
/// score — it NEVER affects `BoardState.score` or replay verification. The level
/// curve is intentionally a square-root so each level costs progressively more
/// XP, and it is **monotonic non-decreasing**: more XP can never lower the level.

/// XP earned by a single completed run of the given [score]. Floor division so
/// the curve is integral and a 0-score run yields 0 XP.
int xpForScore(int score) {
  if (score <= 0) return 0;
  return score ~/ kXpPerScore;
}

/// The player level for a cumulative [xp]. Level 0 is the floor (no negative
/// levels). `level = floor(sqrt(xp / kXpPerLevelBase))` — monotonic in [xp].
int levelForXp(int xp) {
  if (xp <= 0) return 0;
  return math.sqrt(xp / kXpPerLevelBase).floor();
}

/// Total cumulative XP required to first reach [level]. Inverse of [levelForXp]:
/// `xp = level^2 * kXpPerLevelBase`. Level 0 needs 0 XP.
int xpForLevel(int level) {
  if (level <= 0) return 0;
  return level * level * kXpPerLevelBase;
}

/// Cumulative XP still needed to advance from the current [xp] to the next level
/// (always > 0). Used by the UI to draw a "progress to next level" bar.
int xpForNextLevel(int xp) {
  final next = levelForXp(xp) + 1;
  final needed = xpForLevel(next) - xp;
  return needed > 0 ? needed : 1;
}

/// Fraction (0.0..1.0) of progress through the current level toward the next.
double levelProgress(int xp) {
  final current = levelForXp(xp);
  final floor = xpForLevel(current);
  final ceil = xpForLevel(current + 1);
  final span = ceil - floor;
  if (span <= 0) return 0;
  final into = (xp - floor).clamp(0, span);
  return into / span;
}
