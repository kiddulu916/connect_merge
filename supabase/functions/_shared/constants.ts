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
 * Board/tile shapes, ported from `lib/domain/models/tile.dart`,
 * `game_status.dart` and `board_state.dart`. Defined in this zero-import leaf
 * module (rather than in `engine.ts`) so `seeder.ts` can use them without
 * importing `engine.ts` — `engine.ts` imports `seeder.ts` for `DailySeeder`,
 * so the reverse import would form a cycle. `engine.ts` re-exports these
 * under the same names for existing consumers.
 */
export interface Tile {
  id: number;
  tier: number;
}

export type GameStatus = "playing" | "outOfMoves" | "deadlocked";

export interface BoardState {
  cells: (Tile | null)[];
  walls: Set<number>;
  movesRemaining: number;
  score: number;
  nextTileId: number;
  dropIndex: number;
  adContinuesUsed: number;
  movesMade: number;
  status: GameStatus;
  gridSize: number;
}

/**
 * True when `nextTier` may follow `prevTier` in a Connect-Merge chain: equal
 * or exactly one tier higher, never descending or skipping. Must stay in
 * lockstep with `GameEngine.canFollow` in Dart.
 */
export function canFollow(prevTier: number, nextTier: number): boolean {
  return nextTier >= prevTier && nextTier <= prevTier + 1;
}

/**
 * True if two adjacent tier numbers could merge in some direction. Must stay
 * in lockstep with Dart `GameEngine._pairMergeable`.
 */
export function pairMergeable(aTier: number, bTier: number): boolean {
  const lower = aTier < bTier ? aTier : bTier;
  const higher = aTier > bTier ? aTier : bTier;
  return canFollow(lower, higher) && higher < kMaxTier;
}

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
 * Minimum legal Connect-Merge chain length under a rule. Every rule besides
 * `longChainsOnly` uses the baseline of 2 (any legal merge counts);
 * `longChainsOnly` raises it to 3. Single source for `verifyRunChallenge`'s
 * reject-guard and every rule-aware deadlock/refill/seeder check. Must stay
 * in lockstep with Dart `ChallengeRuleMinChainLength.minChainLength`.
 */
export function minChainLengthFor(rule: ChallengeRule): number {
  return rule === "longChainsOnly" ? 3 : 2;
}

/**
 * True if any two orthogonally-adjacent live tiles could legally merge in
 * SOME direction (spatial deadlock check — non-adjacent mergeable tiles do
 * NOT count). Structurally typed on cells (rather than using this file's own
 * `Tile` above) to keep this helper's signature independent of the board
 * shape; duplicated logic, matching this file's existing
 * `pairMergeable`-based pattern, rather than delegating to `engine.ts`'s
 * `hasMergeAvailable`, since `engine.ts` imports this file (importing back
 * would cycle).
 */
function hasAnyMergeablePair(
  cells: ({ tier: number } | null)[],
  gridSize: number,
): boolean {
  for (let i = 0; i < cells.length; i++) {
    const t = cells[i];
    if (t === null) continue;
    const row = Math.floor(i / gridSize);
    const col = i % gridSize;
    if (col + 1 < gridSize) {
      const e = cells[i + 1];
      if (e !== null && pairMergeable(t.tier, e.tier)) return true;
    }
    if (row + 1 < gridSize) {
      const so = cells[i + gridSize];
      if (so !== null && pairMergeable(t.tier, so.tier)) return true;
    }
  }
  return false;
}

function searchChain(
  cells: ({ tier: number } | null)[],
  gridSize: number,
  idx: number,
  visited: Set<number>,
  tier: number,
  length: number,
  minLength: number,
): boolean {
  if (length === minLength) return tier < kMaxTier;
  const row = Math.floor(idx / gridSize);
  const col = idx % gridSize;
  const neighbours: number[] = [];
  if (col + 1 < gridSize) neighbours.push(idx + 1);
  if (col - 1 >= 0) neighbours.push(idx - 1);
  if (row + 1 < gridSize) neighbours.push(idx + gridSize);
  if (row - 1 >= 0) neighbours.push(idx - gridSize);
  for (const n of neighbours) {
    if (visited.has(n)) continue;
    const t = cells[n];
    if (t === null) continue;
    if (!canFollow(tier, t.tier)) continue;
    visited.add(n);
    if (searchChain(cells, gridSize, n, visited, t.tier, length + 1, minLength)) {
      return true;
    }
    visited.delete(n);
  }
  return false;
}

/**
 * True if a legal Connect-Merge chain of at least `minLength` tiles exists
 * anywhere on the board (see `engine.ts` `isValidChain` for what "legal"
 * means). For the pre-existing baseline (`minLength <= 2`) this is exactly
 * `hasAnyMergeablePair`/`hasMergeAvailable`. For a stricter rule
 * (`longChainsOnly`'s 3), this searches every tile as a chain start via DFS
 * along `canFollow`-adjacent, unvisited neighbours. Since chain tiers are
 * non-decreasing, any legal chain of length >= `minLength` has a legal
 * length-exactly-`minLength` prefix, so it suffices to search for one chain
 * of exactly `minLength` tiles rather than every longer one. Must stay in
 * lockstep with Dart `GameEngine.hasChainOfLength`.
 */
export function hasChainOfLength(
  cells: ({ tier: number } | null)[],
  gridSize: number,
  minLength: number,
): boolean {
  if (minLength <= 2) return hasAnyMergeablePair(cells, gridSize);
  for (let i = 0; i < cells.length; i++) {
    const t = cells[i];
    if (t === null) continue;
    if (searchChain(cells, gridSize, i, new Set([i]), t.tier, 1, minLength)) {
      return true;
    }
  }
  return false;
}

/**
 * Combo Rush multiplier: doubles comboMultiplier for N≥3; N=2 stays at 1.
 * Must stay in lockstep with Dart `comboRushMultiplier`.
 */
export function comboRushMultiplier(n: number): number {
  if (n < 3) return comboMultiplier(n);
  return comboMultiplier(n) * 2;
}

/**
 * Leaderboard season (port of Dart `kLeaderboardSeason`). Reset to 1 for
 * launch after the pre-launch database wipe (2026-07-11), so scores from a
 * prior rule set never mix with the current season's. The server uses its OWN
 * constant when writing — it never trusts a client-supplied season. Reset to 1
 * after the 2026-07-31 database wipe (fresh season); bump in lockstep with the
 * Dart copy on any future gameplay-rule change.
 */
export const kLeaderboardSeason = 1;

/**
 * Cap on placement re-roll attempts in the seeder before throwing (port of the
 * Dart I-1 fix). Must match Dart so a pathological seed fails identically.
 */
export const kMaxPlacementAttempts = 5000;
