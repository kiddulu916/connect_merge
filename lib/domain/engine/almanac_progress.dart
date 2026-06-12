import '../models/almanac.dart';

/// Pure Merge Almanac progression (Phase 2).
///
/// Folds a finished run's [highestTier] into the running per-tier count map.
/// The count for the reached tier increments by exactly one; counts are
/// **monotonic** (never decrease). This never reads or writes `BoardState`
/// beyond the already-computed `highestTier`, so replay fairness is untouched.

/// Returns updated almanac counts after a run reached [highestTier]. A
/// `highestTier <= 0` (no live tile) leaves the counts unchanged.
Map<String, int> foldRunIntoAlmanac(
  Map<String, int> counts,
  int highestTier,
) {
  if (highestTier <= 0) return Map<String, int>.from(counts);
  final next = Map<String, int>.from(counts);
  final key = highestTier.toString();
  next[key] = (next[key] ?? 0) + 1;
  return next;
}

/// Convenience: fold a run into an [Almanac] value, returning the new almanac.
Almanac applyRunToAlmanac(Almanac almanac, int highestTier) =>
    Almanac.fromStorage(foldRunIntoAlmanac(almanac.toStorage(), highestTier));
