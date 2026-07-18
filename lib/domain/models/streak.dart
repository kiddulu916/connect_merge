import '../date_utils.dart' show previousUtcDay;

/// Result of a pure streak transition: the new streak value and whether a freeze
/// token was consumed to bridge a one-day gap.
class StreakResult {
  final int streak;
  final bool freezeConsumed;

  const StreakResult({required this.streak, required this.freezeConsumed});

  @override
  bool operator ==(Object other) =>
      other is StreakResult &&
      other.streak == streak &&
      other.freezeConsumed == freezeConsumed;

  @override
  int get hashCode => Object.hash(streak, freezeConsumed);

  @override
  String toString() =>
      'StreakResult(streak: $streak, freezeConsumed: $freezeConsumed)';
}

/// Pure streak transition.
///
/// Rules (all dates are canonical UTC YYYY-MM-DD):
///  - `last == today`         -> unchanged (idempotent; already counted today).
///  - `last == yesterday`     -> prev + 1 (consecutive day).
///  - `last == null`          -> 1 (first ever completion).
///  - gap (older than yday)   -> if [hasFreeze]: keep `prev` and consume a token
///                               (one freeze bridges exactly one missed day);
///                               else: reset to 1.
StreakResult nextStreak({
  required int prev,
  required String? last,
  required String today,
  required bool hasFreeze,
}) {
  if (last == today) {
    return StreakResult(streak: prev, freezeConsumed: false);
  }
  final yesterday = previousUtcDay(today);
  if (last == yesterday) {
    return StreakResult(streak: prev + 1, freezeConsumed: false);
  }
  if (last == null) {
    return const StreakResult(streak: 1, freezeConsumed: false);
  }
  // Gap of 2+ days. A single freeze token covers exactly one missed day, keeping
  // the streak alive (treated as if yesterday were completed -> prev + 1).
  if (hasFreeze) {
    return StreakResult(streak: prev + 1, freezeConsumed: true);
  }
  return const StreakResult(streak: 1, freezeConsumed: false);
}
