/// Tunable game constants — the single source of truth for game feel.
library;

import 'models/difficulty.dart';

// Legacy constant — 5×5 test boards only. All game code now uses
// board.gridSize / board.cells.length or difficulty.gridSize / difficulty.cellCount.
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

/// Phase 4 — undo. Free undos a player gets per tier-day before a rewarded ad is
/// required for further undos. The undo only rewinds local board/PRNG/move-log
/// state to keep the run replay-consistent; it never alters the seed-fixed drop
/// schedule, so this cap is purely a frustration-relief / ad-frequency lever.
const int kFreeUndosPerDay = 1;

/// Phase 4 — depth of the bounded undo history stack. Caps memory and prevents
/// undo-to-start abuse (a player can never rewind more than this many merges).
const int kUndoStackDepth = 3;

/// Phase 4 — stats calendar history retention. The append-only day-result log is
/// capped to this many most-recent entries (oldest dropped) so storage stays
/// bounded (~one year of daily results across tiers).
const int kHistoryRetentionDays = 366;

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

/// Connect-Merge — superlinear combo multiplier for a chain of [n] tiles.
/// `n == 2` returns 1 so the minimal collapse scores exactly `2^(tier+1)`,
/// identical to the legacy pairwise merge. Formula: 1 + (n-2)(n-1)/2.
/// Pure tuning knob — adjust the curve here only.
int comboMultiplier(int n) {
  if (n < 2) return 0;
  return 1 + ((n - 2) * (n - 1)) ~/ 2;
}

/// Number of the next drop tiers shown openly in the planning queue.
const int kDropQueueVisible = 3;

/// How many drops ahead the rewarded ad-hint reveals (beyond the free queue).
const int kAdHintLookahead = 3;

/// Flat coin reward for completing the daily objective (client-side wallet
/// only — never touches score). Tuning knob.
const int kObjectiveRewardCoins = 25;

/// Bumped when the persisted snapshot schema changes. An in-progress snapshot
/// whose version != this is discarded on load (a daily resets anyway).
const int kSnapshotVersion = 3;

/// Bumped at the Connect-Merge relaunch. Submitted with every score and used to
/// filter leaderboard reads, so pre-relaunch scores never appear (hard reset).
const int kLeaderboardSeason = 2;

/// Seed-placed wall cells per difficulty (block tiles, break paths). Scales up with difficulty. Tuning knob.
int wallCountFor(Difficulty d) => switch (d) {
      Difficulty.easy => 2,
      Difficulty.medium => 4,
      Difficulty.hard => 5,
      Difficulty.legendary => 6,
      Difficulty.challenge => 0, // walls set by rule override (wallMaze uses 8)
    };

/// Combo Rush challenge rule: doubled multiplier for chains of length >= 3;
/// N=2 chains score normally (multiplier stays at 1).
int comboRushMultiplier(int n) {
  if (n < 3) return comboMultiplier(n);
  return comboMultiplier(n) * 2;
}

/// Challenge mode: move budget under the Budget Cut rule.
const int kChallengeMoves = 15;

/// Challenge mode: wall count for the Wall Maze rule.
const int kChallengeWallMazeCount = 8;

/// Challenge mode: dense starting fill (Dense Start rule).
const int kChallengeDenseFill = 14;

/// Challenge mode: sparse starting fill (Sparse Start rule).
const int kChallengeSparseFill = 3;
