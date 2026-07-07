// Tunable game constants — TS port of lib/domain/constants.dart. Must stay in
// lockstep with the Dart constants for cross-language replay parity.

/** Board is a fixed kGridSize × kGridSize matrix. */
export const kGridSize = 5;
export const kCellCount = kGridSize * kGridSize; // 25

/** Tier 0 = empty. Tiers 1..kMaxTier are live tiles (displayed as 2^tier). */
export const kMaxTier = 11; // 2^11 = 2048

/** Daily move budget. One move == one successful merge. */
export const kMovesPerDay = 30;

/** Moves granted per rewarded video, and the daily cap on rewarded continues. */
export const kAdMoveReward = 3;
export const kMaxAdContinuesPerDay = 3;

/** Maximum number of drops that can ever occur in one day. */
export const kMaxDrops = kMovesPerDay + kAdMoveReward * kMaxAdContinuesPerDay; // 39

/**
 * Upper bound (inclusive) of the drop tier band for drop number [n].
 * Drops are drawn from tiers [1 .. dropCap(n)]. The band widens by drop INDEX
 * (not board state) so the item sequence is identical for all players.
 */
export function dropCap(n: number): number {
  const c = 2 + Math.floor(n / 6);
  return c > 6 ? 6 : c;
}

/** Difficulty tiers. `name` is the stable seed-key token. */
export const DIFFICULTIES = ["easy", "medium", "hard", "legendary", "challenge"] as const;
export type Difficulty = (typeof DIFFICULTIES)[number];

/** Number of tiles placed on the board at the start of the day, per difficulty. */
export const STARTING_FILL: Record<Difficulty, number> = {
  easy: 40,
  medium: 25,
  hard: 20,
  legendary: 15,
  challenge: 8, // nominal default; overridden by rule in verifyRunChallenge
};

/** Grid side length per difficulty (port of Difficulty.gridSize in Dart). */
export const GRID_SIZE: Record<Difficulty, number> = {
  easy: 8,
  medium: 7,
  hard: 6,
  legendary: 6,
  challenge: 6,
};

export function isDifficulty(s: string): s is Difficulty {
  return (DIFFICULTIES as readonly string[]).includes(s);
}

// ---- Connect-Merge additions (must stay in lockstep with Dart) ----

/**
 * Superlinear combo multiplier for a chain of [n] tiles (port of
 * lib/domain/constants.dart `comboMultiplier`). `n === 2` returns 1 so a 2-chain
 * scores exactly the legacy single-merge value. Formula: 1 + (n-2)(n-1)/2.
 */
export function comboMultiplier(n: number): number {
  if (n < 2) return 0;
  return 1 + Math.floor(((n - 2) * (n - 1)) / 2);
}

/**
 * Bonus added once per ascend transition inside a chain (a step where the
 * next tile's tier is exactly one higher than the previous tile's). Uses the
 * same power-of-two convention as tile values. Must stay in lockstep with
 * Dart `ascendBonus`.
 */
export function ascendBonus(intoTier: number): number {
  return 1 << intoTier;
}

/** Seed-placed wall cells per difficulty (port of Dart `wallCountFor`). */
export const WALL_COUNT: Record<Difficulty, number> = {
  easy: 2,
  medium: 4,
  hard: 5,
  legendary: 6,
  challenge: 0, // overridden by wallMaze rule
};

export const kChallengeMoves = 15;
export const kChallengeWallMazeCount = 8;
export const kChallengeDenseFill = 14;
export const kChallengeSparseFill = 3;

/** Challenge rules — index must match Dart ChallengeRule.values order. */
export const CHALLENGE_RULES = [
  "budgetCut",
  "longChainsOnly",
  "denseStart",
  "sparseStart",
  "wallMaze",
  "comboRush",
] as const;
export type ChallengeRule = (typeof CHALLENGE_RULES)[number];

/**
 * Combo Rush multiplier: doubles comboMultiplier for N≥3; N=2 stays at 1.
 * Must stay in lockstep with Dart `comboRushMultiplier`.
 */
export function comboRushMultiplier(n: number): number {
  if (n < 3) return comboMultiplier(n);
  return comboMultiplier(n) * 2;
}

/**
 * Leaderboard season (port of Dart `kLeaderboardSeason`). Bumped to 3 when the
 * ascending-chain-merge rule shipped, so pre-bump (season 2) scores never mix
 * with post-bump scores. The server uses its OWN constant when writing — it
 * never trusts a client-supplied season.
 */
export const kLeaderboardSeason = 3;

/**
 * Cap on placement re-roll attempts in the seeder before throwing (port of the
 * Dart I-1 fix). Must match Dart so a pathological seed fails identically.
 */
export const kMaxPlacementAttempts = 5000;
