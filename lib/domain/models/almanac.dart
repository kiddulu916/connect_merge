import '../constants.dart';

/// A single tier's entry in the Merge Almanac (Phase 2).
///
/// Pure collection model: the player has reached this [tier] (a tile of value
/// `2^tier`) [count] times across all runs. The tier's mastery badge unlocks
/// once [count] reaches [kAlmanacMasteryThreshold]. None of this touches
/// `BoardState.score` — it is purely client-side completion flair.
class AlmanacEntry {
  /// Tile tier (1..kMaxTier). The displayed value is `2^tier`.
  final int tier;

  /// How many runs have reached this tier as their highest. Monotonic.
  final int count;

  const AlmanacEntry({required this.tier, required this.count});

  /// The displayed tile value (`2^tier`).
  int get value => 1 << tier;

  /// Whether this tier's mastery badge is unlocked (reached enough times).
  bool get mastered => count >= kAlmanacMasteryThreshold;

  /// Progress (0.0..1.0) toward mastering this tier.
  double get progress {
    if (kAlmanacMasteryThreshold <= 0) return 1;
    final p = count / kAlmanacMasteryThreshold;
    return p > 1 ? 1 : p;
  }
}

/// The full Merge Almanac: a per-tier collection of [AlmanacEntry]s derived from
/// a `tier -> times reached` count map (persisted on `PlayerProfile`). Pure.
class Almanac {
  /// `tier -> times that tier was the highest reached in a run`.
  final Map<int, int> counts;

  const Almanac({this.counts = const {}});

  /// Build from raw storage counts (string-keyed JSON map tolerated via
  /// [fromStorage]). The empty almanac is the migration-free default.
  static const empty = Almanac();

  /// Ordered entries for every live tier (1..kMaxTier), even unreached ones
  /// (count 0), so the "book" always shows the full collection to fill in.
  List<AlmanacEntry> get entries => [
        for (var tier = 1; tier <= kMaxTier; tier++)
          AlmanacEntry(tier: tier, count: counts[tier] ?? 0),
      ];

  /// How many tiers have their mastery badge unlocked.
  int get masteredCount => entries.where((e) => e.mastered).length;

  /// How many distinct tiers have been reached at least once.
  int get discoveredCount => entries.where((e) => e.count > 0).length;

  /// Times the given [tier] has been reached.
  int countFor(int tier) => counts[tier] ?? 0;

  /// Whether the given [tier]'s mastery badge is unlocked.
  bool isMastered(int tier) => countFor(tier) >= kAlmanacMasteryThreshold;

  /// Decode from the storage map (`Map<String,int>` keyed by tier string),
  /// dropping any malformed keys. Migration-free: absent/empty => [empty].
  static Almanac fromStorage(Map<String, int> raw) {
    final counts = <int, int>{};
    raw.forEach((k, v) {
      final tier = int.tryParse(k);
      if (tier != null && v > 0) counts[tier] = v;
    });
    return Almanac(counts: counts);
  }

  /// Encode to the storage map (`Map<String,int>` keyed by tier string).
  Map<String, int> toStorage() =>
      counts.map((k, v) => MapEntry(k.toString(), v));
}
