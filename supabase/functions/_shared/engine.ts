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
import { DailySeeder } from "./seeder.ts";
import {
  comboMultiplier,
  type Difficulty,
  isDifficulty,
  kAdMoveReward,
  kMaxAdContinuesPerDay,
  kMaxTier,
  STARTING_FILL,
} from "./constants.ts";

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

export interface VerifyResult {
  valid: boolean;
  score: number;
  highestTier: number;
  reason?: string;
}

// ---- pure rules (port of GameEngine) ----

/** True when cells [a] and [b] are orthogonal neighbours (no diag, no wrap). */
export function areOrthogonallyAdjacent(a: number, b: number, gridSize: number): boolean {
  const ra = Math.floor(a / gridSize), ca = a % gridSize;
  const rb = Math.floor(b / gridSize), cb = b % gridSize;
  return Math.abs(ra - rb) + Math.abs(ca - cb) === 1;
}

/**
 * A legal Connect-Merge path: length >= 2, no repeats, every cell holds a live
 * tile sharing one tier below the cap, consecutive cells orthogonally adjacent.
 * Walls hold no tile, so they are rejected by the null-cell check.
 */
export function isValidChain(s: BoardState, path: number[]): boolean {
  if (!Array.isArray(path) || path.length < 2) return false;
  const seen = new Set<number>();
  const first = s.cells[path[0]];
  if (first === undefined || first === null || first.tier >= kMaxTier) {
    return false;
  }
  const tier = first.tier;
  for (let i = 0; i < path.length; i++) {
    const idx = path[i];
    if (idx < 0 || idx >= s.cells.length) return false;
    if (seen.has(idx)) return false;
    seen.add(idx);
    const t = s.cells[idx];
    if (t === null || t === undefined || t.tier !== tier) return false;
    if (i > 0 && !areOrthogonallyAdjacent(path[i - 1], idx, s.gridSize)) return false;
  }
  return true;
}

/** Points for collapsing a chain of [chainLength] tiles of [mergedTier]. */
export function comboScore(mergedTier: number, chainLength: number): number {
  return (1 << (mergedTier + 1)) * comboMultiplier(chainLength);
}

/**
 * Collapse a validated path onto its endpoint (path.last): endpoint becomes
 * tier+1 keeping its id, all other path cells empty, score gains the combo
 * total, one move spent. Caller must have checked isValidChain.
 */
export function collapseChain(s: BoardState, path: number[]): BoardState {
  const endIdx = path[path.length - 1];
  const end = s.cells[endIdx]!;
  const mergedTier = end.tier;
  const cells = s.cells.slice();
  for (const idx of path) cells[idx] = null;
  cells[endIdx] = { id: end.id, tier: mergedTier + 1 };
  return {
    ...s,
    cells,
    score: s.score + comboScore(mergedTier, path.length),
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

export function applyDrop(s: BoardState, tier: number, landing: Prng): BoardState {
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
 * True if any two orthogonally-adjacent live tiles share a tier below the cap
 * (spatial deadlock — non-adjacent equal tiles do NOT count).
 */
export function hasMergeAvailable(s: BoardState): boolean {
  const gs = s.gridSize;
  for (let i = 0; i < s.cells.length; i++) {
    const t = s.cells[i];
    if (t === null || t.tier >= kMaxTier) continue;
    const row = Math.floor(i / gs);
    const col = i % gs;
    if (col + 1 < gs) {
      const e = s.cells[i + 1];
      if (e !== null && e.tier === t.tier) return true;
    }
    if (row + 1 < gs) {
      const so = s.cells[i + gs];
      if (so !== null && so.tier === t.tier) return true;
    }
  }
  return false;
}

export function evaluateStatus(s: BoardState): BoardState {
  if (s.movesRemaining <= 0) {
    return { ...s, status: "outOfMoves" };
  }
  if (!hasMergeAvailable(s)) {
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

const REJECT: VerifyResult = {
  valid: false,
  score: 0,
  highestTier: 0,
  reason: "invalid_run",
};

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
  if (!isDifficulty(difficulty)) return REJECT;
  if (!Array.isArray(log)) return REJECT;

  const seeder = new DailySeeder(date, difficulty as Difficulty);
  const start = await seeder.generate();
  const dropPrng = await seeder.dropTierPrng();
  const landing = await seeder.landingPrng();
  const startingFill = STARTING_FILL[difficulty as Difficulty];

  let board = start.board;
  let continues = 0;

  for (const raw of log) {
    const ev = parseEvent(raw);
    if (ev === null) return REJECT;

    if (ev.type === "chain") {
      // Mirror GameCubit.playChain: must currently be playing + legal path.
      if (board.status !== "playing") return REJECT;
      if (!isValidChain(board, ev.path)) return REJECT;
      board = collapseChain(board, ev.path);
      // Mirror GameCubit new refill loop (Task 4): fill to startingFill AND
      // guarantee hasMergeAvailable, or stop when board is full.
      while (emptyIndices(board).length > 0) {
        const needsFill = filledCount(board) < startingFill;
        const needsMerge = !hasMergeAvailable(board);
        if (!needsFill && !needsMerge) break;
        const tier = seeder.dropTierAt(dropPrng, board.dropIndex);
        board = applyDrop(board, tier, landing);
      }
      board = evaluateStatus(board);
    } else {
      // Mirror GameCubit.grantAdReward / canOfferAd guard.
      if (board.status !== "outOfMoves") return REJECT;
      if (continues >= kMaxAdContinuesPerDay) return REJECT;
      if (board.adContinuesUsed >= kMaxAdContinuesPerDay) return REJECT;
      if (!hasMergeAvailable(board)) return REJECT;
      continues += 1;
      board = {
        ...board,
        movesRemaining: board.movesRemaining + kAdMoveReward,
        adContinuesUsed: board.adContinuesUsed + 1,
        status: "playing",
      };
    }

    if (board.movesRemaining < 0) return REJECT;
  }

  return {
    valid: true,
    score: board.score,
    highestTier: highestTier(board),
  };
}
