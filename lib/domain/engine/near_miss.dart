import '../constants.dart';
import '../models/board_state.dart';

/// Near-miss framing: turn a finished board into the single most motivating
/// "so close" line — or `null` when nothing compelling exists.
///
/// Pure over [BoardState] (+ an optional personal best). Returns `null` rather
/// than fabricating pressure, honouring the wholesome-tone requirement.
class NearMiss {
  const NearMiss._();

  /// The most motivating near-miss message, or `null` if none applies.
  ///
  /// Priority:
  ///  1. Two unmerged tiles of the same highest mergeable tier left on a
  ///     finished board ⇒ "1 merge from tier `2^(tier+1)`!".
  ///  2. Else, if [bestScore] is set and the final score is within
  ///     [kNearMissScoreWindow] points below it ⇒ "N points from your best".
  static String? message(BoardState s, {int? bestScore}) {
    final pair = _oneMergeFromTier(s);
    if (pair != null) {
      return '1 merge from tier ${1 << pair}!';
    }
    if (bestScore != null && bestScore > 0) {
      final gap = bestScore - s.score;
      if (gap > 0 && gap <= kNearMissScoreWindow) {
        return '$gap points from your best';
      }
    }
    return null;
  }

  /// The next tier the player would have reached if they could merge the
  /// highest pair of equal, below-cap tiles still on the board — or `null` if
  /// no such pair exists. Returns the *resulting* tier (`tier + 1`).
  static int? _oneMergeFromTier(BoardState s) {
    final counts = <int, int>{};
    for (final c in s.cells) {
      if (c == null || c.tier >= kMaxTier) continue;
      counts[c.tier] = (counts[c.tier] ?? 0) + 1;
    }
    int? bestTier;
    counts.forEach((tier, count) {
      if (count >= 2 && (bestTier == null || tier > bestTier!)) {
        bestTier = tier;
      }
    });
    return bestTier == null ? null : bestTier! + 1;
  }
}
