// TS port of lib/domain/engine/game_engine.dart + the replay verifier
// (Connect-Merge).
//
// `verifyRun(date, difficulty, moveLog)` regenerates the `(date,difficulty)`
// board (with walls + born-deadlock re-roll), applies each ChainEvent in order
// (validating path geometry), tops the board back up to the difficulty's
// starting fill after each chain (multi-drop refill), and returns the
// authoritative score + highest tier, or rejects. The ordering mirrors
// GameCubit.playChain / GameCubit.grantAdReward exactly.

import { Prng } from "./prng.ts";
import { challengeRule, DailySeeder, type DailyStart } from "./seeder.ts";
import {
  ascendBonus,
  type BoardState,
  canFollow,
  type ChallengeRule,
  comboMultiplier,
  comboRushMultiplier,
  type Difficulty,
  type GameStatus,
  hasChainOfLength,
  isDifficulty,
  kAdMoveReward,
  kChallengeDenseFill,
  kChallengeMoves,
  kChallengeSparseFill,
  kChallengeWallMazeCount,
  kMaxAdContinuesPerDay,
  kMovesPerDay,
  minChainLengthFor,
  STARTING_FILL,
  type Tile,
} from "./constants.ts";

// `Tile`/`GameStatus`/`BoardState` are defined in constants.ts (see the
// comment there) and re-exported here so existing `import { BoardState, ... }
// from "./engine.ts"` call sites keep working unchanged.
export type { BoardState, GameStatus, Tile };

// Move events (mirror lib/domain/models/move.dart). Accept both the spec's
// short form ({t:"chain"}) and Dart's toJson form ({type:"chain"}).
export interface ChainEvent {
  type: "chain";
  path: number[];
}
export interface ContinueEvent {
  type: "continue";
}
export type MoveEvent = ChainEvent | ContinueEvent;

export const REJECTION_STAGES = [
  "invalid_difficulty",
  "malformed_log",
  "malformed_event",
  "chain_wrong_status",
  "illegal_chain",
  "continue_wrong_status",
  "continue_count_exceeded",
  "ad_usage_exceeded",
  "continue_without_merge",
  "moves_underflow",
  "challenge_malformed_log",
  "challenge_malformed_event",
  "challenge_chain_wrong_status",
  "challenge_chain_too_short",
  "challenge_illegal_chain",
  "challenge_continue_forbidden",
  "challenge_moves_underflow",
] as const;
export type RejectionStage = (typeof REJECTION_STAGES)[number];

export type VerifyResult =
  | { valid: true; score: number; highestTier: number }
  | {
    valid: false;
    score: 0;
    highestTier: 0;
    reason: "invalid_run";
    stage: RejectionStage;
  };

// ---- pure rules (port of GameEngine) ----

/**
 * True when cells [a] and [b] are any of the eight neighboring cells, without
 * row wrap-around. Must stay in lockstep with Dart `GameEngine.areAdjacent`.
 */
export function areAdjacent(a: number, b: number, gridSize: number): boolean {
  const ra = Math.floor(a / gridSize), ca = a % gridSize;
  const rb = Math.floor(b / gridSize), cb = b % gridSize;
  const dr = Math.abs(ra - rb), dc = Math.abs(ca - cb);
  return dr <= 1 && dc <= 1 && (dr !== 0 || dc !== 0);
}

/**
 * A legal Connect-Merge path: length >= 2, no repeats, every cell holds a
 * live tile, consecutive cells 8-directionally adjacent, and each step's tier is
 * either equal to or exactly one higher than the previous tile's tier (never
 * descends, never skips a tier). Since the path is thus non-decreasing, the
 * final tile is always the peak. Walls hold no tile, so they are rejected by
 * the null-cell check; diagonals may pass between two flanking walls. There is
 * no gameplay tier cap. Must stay in lockstep with Dart.
 */
export function isValidChain(s: BoardState, path: number[]): boolean {
  if (!Array.isArray(path) || path.length < 2) return false;
  const seen = new Set<number>();
  let prev: Tile | null = null;
  for (let i = 0; i < path.length; i++) {
    const idx = path[i];
    if (idx < 0 || idx >= s.cells.length) return false;
    if (seen.has(idx)) return false;
    seen.add(idx);
    const t = s.cells[idx];
    if (t === null || t === undefined) return false;
    if (prev !== null) {
      if (!canFollow(prev.tier, t.tier)) return false;
      if (!areAdjacent(path[i - 1], idx, s.gridSize)) return false;
    }
    prev = t;
  }
  return prev !== null;
}

/**
 * Returns floor(log2(sum)) via integer division. This stays correct for every
 * positive safe-integer caller, including test-constructed boards beyond the
 * real seeded-play bound. Must stay behaviorally identical to Dart.
 */
export function mergedTierFromSum(sum: number): number {
  if (!Number.isSafeInteger(sum) || sum <= 0) {
    throw new RangeError("mergedTierFromSum requires a positive safe integer");
  }
  let tier = 0;
  let remaining = sum;
  while (remaining >= 2) {
    remaining = Math.floor(remaining / 2);
    tier += 1;
  }
  return tier;
}

/**
 * Collapse a validated path onto its endpoint (path.last): endpoint becomes
 * the floor-power-of-two tier of the path's total value while keeping its id,
 * all other path cells empty, score gains the combo total PLUS an ascendBonus
 * for every ascend transition, and one move is spent. Must stay in lockstep
 * with Dart `GameEngine.collapseChain`.
 */
export function collapseChain(
  s: BoardState,
  path: number[],
  multiplierFn?: (n: number) => number,
): BoardState {
  const endIdx = path[path.length - 1];
  const end = s.cells[endIdx]!;
  const fn = multiplierFn ?? comboMultiplier;
  let sum = 0;
  let ascendTotal = 0;
  for (const idx of path) sum += 2 ** s.cells[idx]!.tier;
  const resultTier = mergedTierFromSum(sum);
  for (let i = 1; i < path.length; i++) {
    const prevTier = s.cells[path[i - 1]]!.tier;
    const curTier = s.cells[path[i]]!.tier;
    if (curTier === prevTier + 1) {
      ascendTotal += ascendBonus(curTier);
    }
  }
  const cells = s.cells.slice();
  for (const idx of path) cells[idx] = null;
  cells[endIdx] = { id: end.id, tier: resultTier };
  return {
    ...s,
    cells,
    score: s.score + (2 ** resultTier) * fn(path.length) + ascendTotal,
    movesRemaining: s.movesRemaining - 1,
    movesMade: s.movesMade + 1,
  };
}

export function emptyIndices(s: BoardState): number[] {
  const out: number[] = [];
  for (let i = 0; i < s.cells.length; i++) {
    if (s.cells[i] === null && !s.walls.has(i)) out.push(i);
  }
  return out;
}

export function filledCount(s: BoardState): number {
  let n = 0;
  for (const c of s.cells) if (c !== null) n++;
  return n;
}

export function applyDrop(
  s: BoardState,
  tier: number,
  landing: Prng,
): BoardState {
  const empties = emptyIndices(s);
  if (empties.length === 0) {
    return { ...s, dropIndex: s.dropIndex + 1 };
  }
  const idx = empties[landing.nextInt(empties.length)];
  const cells = s.cells.slice();
  cells[idx] = { id: s.nextTileId, tier };
  return {
    ...s,
    cells,
    nextTileId: s.nextTileId + 1,
    dropIndex: s.dropIndex + 1,
  };
}

/**
 * Fill to `targetFill` and guarantee a chain of `minChainLength` tiles when
 * space permits (default 2, the pre-existing baseline for every rule besides
 * `longChainsOnly`, which raises it to 3). Mirrors Dart `GameEngine.refill`;
 * Dart's golden-drop flag is deliberately absent because cosmetic/economy
 * state never affects authoritative replay.
 */
export function refillBoard(
  board: BoardState,
  targetFill: number,
  tierAt: (dropIndex: number) => number,
  landing: Prng,
  minChainLength = 2,
): BoardState {
  while (emptyIndices(board).length > 0) {
    const needsFill = filledCount(board) < targetFill;
    const needsMerge = !hasChainOfLength(
      board.cells,
      board.gridSize,
      minChainLength,
    );
    if (!needsFill && !needsMerge) break;
    const tier = tierAt(board.dropIndex);
    board = applyDrop(board, tier, landing);
  }
  return board;
}

/**
 * True if any two 8-directionally adjacent live tiles could legally merge in
 * SOME direction (spatial deadlock — non-adjacent mergeable tiles do NOT
 * count). Delegates to the single scan in `constants.ts` (`hasAnyMergeablePair`,
 * reached via `hasChainOfLength` at minLength 2) so the adjacency scan is
 * written exactly once in TypeScript. Must stay in lockstep with Dart
 * `GameEngine.hasMergeAvailable`.
 */
export function hasMergeAvailable(s: BoardState): boolean {
  return hasChainOfLength(s.cells, s.gridSize, 2);
}

/**
 * Resolve end-of-day status: out of moves first, then deadlock, else playing.
 * `minChainLength` defaults to 2 (the pre-existing baseline); `longChainsOnly`
 * passes 3 so a run only deadlocks once no chain of the rule's required
 * length remains, not merely no 2-chain.
 */
export function evaluateStatus(s: BoardState, minChainLength = 2): BoardState {
  if (s.movesRemaining <= 0) {
    return { ...s, status: "outOfMoves" };
  }
  if (!hasChainOfLength(s.cells, s.gridSize, minChainLength)) {
    return { ...s, status: "deadlocked" };
  }
  return { ...s, status: "playing" };
}

export function highestTier(s: BoardState): number {
  let m = 0;
  for (const c of s.cells) {
    if (c !== null && c.tier > m) m = c.tier;
  }
  return m;
}

// ---- replay verifier ----

/** Normalize a raw move-log entry (spec short form or Dart toJson form). */
function parseEvent(raw: unknown): MoveEvent | null {
  if (typeof raw !== "object" || raw === null) return null;
  const o = raw as Record<string, unknown>;
  const t = (o.t ?? o.type) as unknown;
  if (t === "chain") {
    const path = o.path;
    if (!Array.isArray(path) || path.length === 0) return null;
    for (const x of path) {
      if (typeof x !== "number" || !Number.isInteger(x)) return null;
    }
    return { type: "chain", path: path as number[] };
  }
  if (t === "continue") {
    return { type: "continue" };
  }
  return null;
}

function reject(stage: RejectionStage): VerifyResult {
  return {
    valid: false,
    score: 0,
    highestTier: 0,
    reason: "invalid_run",
    stage,
  };
}

/**
 * Regenerate the `(date,difficulty)` board and replay the move log to compute
 * the authoritative score. Any illegal chain, out-of-budget continue, or
 * malformed log yields `{ valid: false }`. Mirrors GameCubit.playChain:
 * collapse -> top-up-to-startingFill refill -> evaluateStatus.
 */
export async function verifyRun(
  date: string,
  difficulty: string,
  log: unknown,
): Promise<VerifyResult> {
  if (!isDifficulty(difficulty)) return reject("invalid_difficulty");
  if (!Array.isArray(log)) return reject("malformed_log");

  const seeder = new DailySeeder(date, difficulty as Difficulty);
  const start = await seeder.generate();
  const dropPrng = await seeder.dropTierPrng();
  const landing = await seeder.landingPrng();
  const startingFill = STARTING_FILL[difficulty as Difficulty];

  let board = start.board;
  let continues = 0;

  for (const raw of log) {
    const ev = parseEvent(raw);
    if (ev === null) return reject("malformed_event");

    if (ev.type === "chain") {
      // Mirror GameCubit.playChain: must currently be playing + legal path.
      if (board.status !== "playing") return reject("chain_wrong_status");
      if (!isValidChain(board, ev.path)) return reject("illegal_chain");
      board = collapseChain(board, ev.path);
      board = refillBoard(
        board,
        startingFill,
        (dropIndex) => seeder.dropTierAt(dropPrng, dropIndex),
        landing,
      );
      board = evaluateStatus(board);
    } else {
      // Mirror GameCubit.grantAdReward / canOfferAd guard.
      if (board.status !== "outOfMoves") return reject("continue_wrong_status");
      if (continues >= kMaxAdContinuesPerDay) {
        return reject("continue_count_exceeded");
      }
      if (board.adContinuesUsed >= kMaxAdContinuesPerDay) {
        return reject("ad_usage_exceeded");
      }
      if (!hasMergeAvailable(board)) return reject("continue_without_merge");
      continues += 1;
      board = {
        ...board,
        movesRemaining: board.movesRemaining + kAdMoveReward,
        adContinuesUsed: board.adContinuesUsed + 1,
        status: "playing",
      };
    }

    if (board.movesRemaining < 0) return reject("moves_underflow");
  }

  return {
    valid: true,
    score: board.score,
    highestTier: highestTier(board),
  };
}

export interface ChallengeStart {
  rule: ChallengeRule;
  start: DailyStart;
  startingFill: number;
  movesOverride: number;
  minChainLength: number;
  multiplierFn: (n: number) => number;
}

/**
 * Resolve the per-rule generation overrides for today's Challenge board and
 * seed the starting board. Single source for how the daily challenge board is
 * built, so the board-parity digest and verifyRunChallenge cannot diverge on
 * it. Mirrors the challenge branch of Dart `GameCubit.init`.
 */
export async function seedChallengeStart(
  date: string,
): Promise<ChallengeStart> {
  const rule = await challengeRule(date);
  const startingFill = rule === "denseStart"
    ? kChallengeDenseFill
    : rule === "sparseStart"
    ? kChallengeSparseFill
    : rule === "longChainsOnly"
    ? kChallengeDenseFill
    : STARTING_FILL["challenge"];
  const wallCountOverride = rule === "wallMaze" ? kChallengeWallMazeCount : 0;
  const movesOverride = rule === "budgetCut" ? kChallengeMoves : kMovesPerDay;
  const multiplierFn = rule === "comboRush"
    ? comboRushMultiplier
    : comboMultiplier;
  const minChainLength = minChainLengthFor(rule);
  const seeder = new DailySeeder(date, "challenge");
  const start = await seeder.generate({
    startingFillOverride: startingFill,
    wallCountOverride,
    movesOverride,
    minChainLength,
  });
  return {
    rule,
    start,
    startingFill,
    movesOverride,
    minChainLength,
    multiplierFn,
  };
}

/**
 * Challenge-mode replay verifier. Derives the day's ChallengeRule, regenerates
 * the challenge board with rule-specific overrides, and replays the move log
 * applying rule constraints:
 *   - budgetCut:      board starts with kChallengeMoves (15) moves.
 *   - longChainsOnly: reject ChainEvent paths shorter than minChainLengthFor
 *                     (3); board also starts denser (kChallengeDenseFill) and
 *                     refill/re-roll/deadlock-detection all require a chain
 *                     of that length, not just any 2-chain.
 *   - denseStart:     board seeded with kChallengeDenseFill tiles.
 *   - sparseStart:    board seeded with kChallengeSparseFill tiles.
 *   - wallMaze:       board seeded with kChallengeWallMazeCount walls.
 *   - comboRush:      score computed with comboRushMultiplier.
 */
export async function verifyRunChallenge(
  date: string,
  log: unknown,
): Promise<VerifyResult> {
  if (!Array.isArray(log)) return reject("challenge_malformed_log");

  const { start, startingFill, minChainLength, multiplierFn } =
    await seedChallengeStart(date);

  const seeder = new DailySeeder(date, "challenge");
  const dropPrng = await seeder.dropTierPrng();
  const landing = await seeder.landingPrng();

  let board = start.board;

  for (const raw of log) {
    const ev = parseEvent(raw);
    if (ev === null) return reject("challenge_malformed_event");

    if (ev.type === "chain") {
      if (board.status !== "playing") {
        return reject("challenge_chain_wrong_status");
      }
      // Reject paths shorter than the active rule's minimum.
      if (ev.path.length < minChainLength) {
        return reject("challenge_chain_too_short");
      }
      if (!isValidChain(board, ev.path)) {
        return reject("challenge_illegal_chain");
      }
      board = collapseChain(board, ev.path, multiplierFn);
      board = refillBoard(
        board,
        startingFill,
        (dropIndex) => seeder.dropTierAt(dropPrng, dropIndex),
        landing,
        minChainLength,
      );
      board = evaluateStatus(board, minChainLength);
    } else {
      // Challenge mode has no ad-continues; treat any continue as illegal.
      return reject("challenge_continue_forbidden");
    }

    if (board.movesRemaining < 0) return reject("challenge_moves_underflow");
  }

  return {
    valid: true,
    score: board.score,
    highestTier: highestTier(board),
  };
}
