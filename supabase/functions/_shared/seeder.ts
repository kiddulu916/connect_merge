// TS port of lib/domain/engine/daily_seeder.dart (Connect-Merge).
//
// Turns a `(YYYY-MM-DD, Difficulty)` pair into the day's board. Independent
// deterministic PRNG sub-streams, each keyed off `"$date:$difficulty"`:
//   - stream A (seedA): initial board placement (with born-deadlock re-roll).
//   - stream B (seedB): landing-cell selection at drop time.
//   - "walls" sub-stream: seed-placed blocked cells.
//   - "drops" sub-stream: on-demand drop tiers (unbounded; lock-step w/ dropIndex).
//
// NOTE vs Dart: Dart's generate() also produces a trailing `dropTiers` list on
// stream A after placement; that list is unused by Connect-Merge (drops come
// from the independent "drops" stream) and never affects the board, so this port
// omits it. The board cells/walls and every drop are byte-identical to Dart.

import { Prng } from "./prng.ts";
import {
  CHALLENGE_RULES,
  type ChallengeRule,
  type Difficulty,
  dropCap,
  GRID_SIZE,
  kMaxPlacementAttempts,
  kMovesPerDay,
  pairMergeable,
  STARTING_FILL,
  WALL_COUNT,
} from "./constants.ts";
import type { BoardState, Tile } from "./engine.ts";

/** Everything the day needs, derived deterministically from the date. */
export interface DailyStart {
  board: BoardState;
}

/**
 * Hashes an arbitrary seed key (e.g. "2026-06-07:hard") to a 32-bit seed.
 * Byte order must match Dart exactly:
 *   bytes[0] | bytes[1]<<8 | bytes[2]<<16 | bytes[3]<<24  (then & 0xFFFFFFFF).
 */
export async function seedForKey(key: string): Promise<number> {
  const data = new TextEncoder().encode(key);
  const digest = await crypto.subtle.digest("SHA-256", data);
  const b = new Uint8Array(digest);
  return (b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)) >>> 0;
}

/**
 * Spatial deadlock check used during placement re-roll. Scans east+south
 * neighbours once each and shares `pairMergeable` with the replay engine.
 */
function hasAdjacentMergeablePair(
  cells: (Tile | null)[],
  gridSize: number,
): boolean {
  const cellCount = cells.length;
  for (let i = 0; i < cellCount; i++) {
    const t = cells[i];
    if (t === null) continue;
    const row = Math.floor(i / gridSize);
    const col = i % gridSize;
    if (col + 1 < gridSize) {
      const e = cells[i + 1];
      if (e !== null && pairMergeable(t.tier, e.tier)) return true;
    }
    if (row + 1 < gridSize) {
      const s = cells[i + gridSize];
      if (s !== null && pairMergeable(t.tier, s.tier)) return true;
    }
  }
  return false;
}

export class DailySeeder {
  readonly date: string; // UTC YYYY-MM-DD
  readonly difficulty: Difficulty;

  constructor(date: string, difficulty: Difficulty) {
    this.date = date;
    this.difficulty = difficulty;
  }

  get key(): string {
    return `${this.date}:${this.difficulty}`;
  }

  async seedA(): Promise<number> {
    return await seedForKey(this.key);
  }

  async seedB(): Promise<number> {
    return (await seedForKey(this.key)) ^ 0x9e3779b9;
  }

  /** Seed-placed wall cells with an explicit count (extracted helper). */
  async wallIndicesWithCount(count: number): Promise<Set<number>> {
    if (count === 0) return new Set();
    const gridSize = GRID_SIZE[this.difficulty];
    const cellCount = gridSize * gridSize;
    const w = new Prng(await seedForKey(`${this.key}:walls`));
    const out = new Set<number>();
    while (out.size < count) {
      out.add(w.nextInt(cellCount));
    }
    return out;
  }

  /** Seed-placed wall cells (port of DailySeeder.wallIndices), "walls" stream. */
  async wallIndices(): Promise<Set<number>> {
    return this.wallIndicesWithCount(WALL_COUNT[this.difficulty]);
  }

  async generate(opts?: {
    startingFillOverride?: number;
    wallCountOverride?: number;
    movesOverride?: number;
  }): Promise<DailyStart> {
    const a = new Prng(await this.seedA());
    const wallCount = opts?.wallCountOverride ?? WALL_COUNT[this.difficulty];
    const walls = await this.wallIndicesWithCount(wallCount);
    const startingFill = opts?.startingFillOverride ?? STARTING_FILL[this.difficulty];
    const movesRemaining = opts?.movesOverride ?? kMovesPerDay;
    const gridSize = GRID_SIZE[this.difficulty];
    const cellCount = gridSize * gridSize;

    // Re-roll placement until the board has at least one adjacent mergeable pair
    // (avoids a born-deadlocked, unplayable day under the spatial deadlock rule).
    // Deterministic: same seed -> same attempt sequence -> same first valid board.
    let cells: (Tile | null)[] = [];
    let nextId = 0;
    let attempts = 0;
    while (true) {
      attempts += 1;
      if (attempts > kMaxPlacementAttempts) {
        throw new Error(
          `DailySeeder.generate: no non-deadlocked placement for ${this.key} ` +
            `after ${kMaxPlacementAttempts} attempts`,
        );
      }
      cells = new Array(cellCount).fill(null);
      nextId = 0;
      let placed = 0;
      while (placed < startingFill) {
        const idx = a.nextInt(cellCount);
        if (cells[idx] !== null || walls.has(idx)) continue; // skip walls
        cells[idx] = { id: nextId++, tier: 1 + a.nextInt(2) };
        placed += 1;
      }
      if (hasAdjacentMergeablePair(cells, gridSize)) break;
    }

    const board: BoardState = {
      cells,
      walls,
      movesRemaining,
      score: 0,
      nextTileId: nextId,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 0,
      status: "playing",
      gridSize,
    };
    return { board };
  }

  /** Fresh landing stream (stream B). */
  async landingPrng(): Promise<Prng> {
    return new Prng(await this.seedB());
  }

  /**
   * Fresh on-demand drop-tier stream ("drops" sub-stream), advanced in drop-index
   * order via [dropTierAt]. Mirrors Dart `DailySeeder.dropTierPrng`.
   */
  async dropTierPrng(): Promise<Prng> {
    return new Prng(await seedForKey(`${this.key}:drops`));
  }

  /** Tier for drop number [n] from [p] (caller advances in index order). */
  dropTierAt(p: Prng, n: number): number {
    return 1 + p.nextInt(dropCap(n));
  }
}

/** Derives today's ChallengeRule from the "$date:challenge" seed. */
export async function challengeRule(date: string): Promise<ChallengeRule> {
  const seed = await seedForKey(`${date}:challenge`);
  const prng = new Prng(seed);
  const idx = prng.nextInt(6);
  return CHALLENGE_RULES[idx];
}
