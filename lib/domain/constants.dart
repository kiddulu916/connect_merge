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

/// Daily cap on the rewarded reveal-next-drop hint (Phase 4). The hint is
/// read-only (it reveals seed-fixed info, never alters the board) so the cap is
/// purely an ad-frequency control, not a fairness lever.
const int kMaxHintsPerDay = 3;

/// Daily cap on rewarded streak-freeze grants (Phase 4). One token bridges one
/// missed UTC day; banked tokens are additionally capped by
/// kMaxStreakFreezeTokens in storage.
const int kMaxFreezeGrantsPerDay = 1;

/// Maximum number of drops that can ever occur in one day.
const int kMaxDrops = kMovesPerDay + kAdMoveReward * kMaxAdContinuesPerDay; // 39

/// Phase 1 (engagement engine) — golden tiles. A deterministic, seed-derived
/// subset (~[kGoldenDropPercent]% on average) of the day's drops are "golden".
/// Merging a golden tile credits [kGoldenMergeBonus] coins to the client-side
/// wallet. Golden is a purely visual/economy property: it NEVER touches
/// `BoardState.score` or `moveLog`, so replay verification stays untouched.
const int kGoldenDropPercent = 8;
const int kGoldenMergeBonus = 5;

/// Phase 1 — Daily Loot Chest reward bands (coins). The day's reward is derived
/// from the daily seed (`"$date:loot"`), so it is identical for every player,
/// cheat-proof, and free. Bands: mostly small, occasional jackpot — the
/// variable-reward dopamine core. Exposed here for playtest tuning.
const int kLootCommonBase = 10;
const int kLootCommonSpan = 15;
const int kLootUncommonBase = 30;
const int kLootUncommonSpan = 30;
const int kLootJackpotBase = 100;
const int kLootJackpotSpan = 50;

/// Roll thresholds (0..99) for the loot bands: roll < common => common band,
/// < uncommon => uncommon band, else jackpot. A rare cosmetic shard drops at
/// or above [kLootShardThreshold].
const int kLootCommonRollMax = 70;
const int kLootUncommonRollMax = 95;
const int kLootShardThreshold = 97;

/// Phase 1 — near-miss framing. The largest score gap below a personal best
/// that still reads as "so close" (only surfaced when no tile-pair near-miss
/// applies). Kept small so the line stays honest.
const int kNearMissScoreWindow = 50;

/// Phase 1 — midday "your boards are waiting" nudge, minutes past local
/// midnight (12:00 by default). Reuses the [reminderMinutes]-style slot.
const int kMiddayReminderMinutes = 12 * 60;

/// Phase 2 (meta-progression) — player level / XP. XP is purely a client-side
/// flair derived from already-recorded cumulative score: `lifetimeXp` accrues
/// `score ~/ kXpPerScore` each completed run. It NEVER affects `BoardState.score`
/// or replay verification, and the level curve is monotonic non-decreasing.
const int kXpPerScore = 10;

/// Base divisor for the level curve: `level = floor(sqrt(xp / kXpPerLevelBase))`.
/// Larger => slower leveling. Open tuning item.
const int kXpPerLevelBase = 50;

/// Phase 2 — Merge Almanac. A run records its `highestTier` into the per-tier
/// almanac count (`tier -> times reached`). A tier's mastery badge unlocks once
/// that tier has been reached [kAlmanacMasteryThreshold] times. Pure collection
/// flair; never touches score.
const int kAlmanacMasteryThreshold = 5;

/// Phase 2 — earned cosmetics economy. Coin prices for purchasable tile themes.
/// Open tuning items (watch coin sink/earn ratio for runaway inflation).
const int kCosmeticPriceCommon = 150;
const int kCosmeticPriceRare = 400;

/// Phase 2 — flat soft-currency reward for completing a tier's day. Credited via
/// the same [onCoinsEarned] wallet hook as golden tiles, so it NEVER touches
/// `BoardState.score`. A rewarded ad can double the run's earned coins.
const int kCompletionCoinReward = 20;

/// Upper bound (inclusive) of the drop tier band for drop number [n].
/// Drops are drawn from tiers [1 .. dropCap(n)]. The band widens by drop
/// INDEX (not board state) so the item sequence is identical for all players.
int dropCap(int n) {
  final c = 2 + (n ~/ 6);
  return c > 6 ? 6 : c;
}
