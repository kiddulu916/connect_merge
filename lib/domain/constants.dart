/// Tunable game constants — the single source of truth for game feel.
library;

/// Board is a fixed kGridSize × kGridSize matrix.
const int kGridSize = 5;
const int kCellCount = kGridSize * kGridSize; // 25

/// Tier 0 = empty. Tiers 1..kMaxTier are live tiles (displayed as 2^tier).
const int kMaxTier = 11; // 2^11 = 2048

/// Daily move budget. One move == one successful merge.
const int kMovesPerDay = 30;

/// Board population is now per-difficulty (see [Difficulty.startingFill]). Each
/// merge frees a cell and each drop fills one, so occupancy stays at the chosen
/// tier's starting fill all day. All starting fills must be <= kMaxTier for
/// deadlock to be reachable (pigeonhole: all-unique tiers needs <= 11 tiles).

/// Moves granted per rewarded video, and the daily cap on rewarded continues.
const int kAdMoveReward = 3;
const int kMaxAdContinuesPerDay = 3;

/// Maximum number of drops that can ever occur in one day.
const int kMaxDrops = kMovesPerDay + kAdMoveReward * kMaxAdContinuesPerDay; // 39

/// Upper bound (inclusive) of the drop tier band for drop number [n].
/// Drops are drawn from tiers [1 .. dropCap(n)]. The band widens by drop
/// INDEX (not board state) so the item sequence is identical for all players.
int dropCap(int n) {
  final c = 2 + (n ~/ 6);
  return c > 6 ? 6 : c;
}
