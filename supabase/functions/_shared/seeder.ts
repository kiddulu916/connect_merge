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
  type Difficulty,
  dropCap,
  kCellCount,
  kGridSize,
  kMaxPlacementAttempts,
  kMaxTier,
  kMovesPerDay,
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
 * Local copy of the spatial deadlock check (port of GameEngine.hasMergeAvailable)
 * used during placement re-roll. Inlined here to avoid a seeder<->engine import
 * cycle (engine.ts imports DailySeeder). Scans east+south neighbours once each.
 */
function hasAdjacentSameTier(cells: (Tile | null)[]): boolean {
  for (let i = 0; i < kCellCount; i++) {
    const t = cells[i];
    if (t === null || t.tier >= kMaxTier) continue;
    const row = Math.floor(i / kGridSize);
    const col = i % kGridSize;
    if (col + 1 < kGridSize) {
      const e = cells[i + 1];
      if (e !== null && e.tier === t.tier) return true;
    }
    if (row + 1 < kGridSize) {
      const s = cells[i + kGridSize];
      if (s !== null && s.tier === t.tier) return true;
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

  /** Seed-placed wall cells (port of DailySeeder.wallIndices), "walls" stream. */
  async wallIndices(): Promise<Set<number>> {
    const count = WALL_COUNT[this.difficulty];
    if (count === 0) return new Set();
    const w = new Prng(await seedForKey(`${this.key}:walls`));
    const out = new Set<number>();
    while (out.size < count) {
      out.add(w.nextInt(kCellCount)); // rejection sampling; deterministic
    }
    return out;
  }

  async generate(): Promise<DailyStart> {
    const a = new Prng(await this.seedA());
    const walls = await this.wallIndices();
    const startingFill = STARTING_FILL[this.difficulty];

    // Re-roll placement until the board has at least one adjacent same-tier pair
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
      cells = new Array(kCellCount).fill(null);
      nextId = 0;
      let placed = 0;
      while (placed < startingFill) {
        const idx = a.nextInt(kCellCount);
        if (cells[idx] !== null || walls.has(idx)) continue; // skip walls
        cells[idx] = { id: nextId++, tier: 1 + a.nextInt(2) };
        placed += 1;
      }
      if (hasAdjacentSameTier(cells)) break;
    }

    const board: BoardState = {
      cells,
      walls,
      movesRemaining: kMovesPerDay,
      score: 0,
      nextTileId: nextId,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 0,
      status: "playing",
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
