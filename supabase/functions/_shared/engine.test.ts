// Cross-language parity + replay-verification tests (Connect-Merge).
//
// The "expected" board/run values below were CAPTURED from the Dart
// implementation via a throwaway test (test/domain/engine/_temp_vectors_test.dart,
// since deleted). They pin the TS port to be byte-identical to Dart. If these
// ever drift, the server board != client board and every legit run would be
// rejected — so these assertions are the CI gate for the determinism port.
//
// Run: deno test supabase/functions/_shared/engine.test.ts

import { assertEquals, assertFalse } from "@std/assert";
import { Prng } from "./prng.ts";
import { DailySeeder, seedForKey } from "./seeder.ts";
import {
  areAdjacent,
  type BoardState,
  collapseChain,
  evaluateStatus,
  hasMergeAvailable,
  isValidChain,
  mergedTierFromSum,
  type MoveEvent,
  refillBoard,
  type RejectionStage,
  type Tile,
  type VerifyResult,
  verifyRun,
  verifyRunChallenge,
} from "./engine.ts";
import {
  ascendBonus,
  canFollow,
  comboMultiplier,
  comboRushMultiplier,
  dropCap,
  GRID_SIZE,
  hasChainOfLength,
  kAdMoveReward,
  kCellCount,
  kChallengeDenseFill,
  kMaxAdContinuesPerDay,
  kMaxPlayableTier,
  kMaxPlayableValueMass,
  kMaxTier,
  kMovesPerDay,
  pairMergeable,
  STARTING_FILL,
  WALL_COUNT,
} from "./constants.ts";

// ---- Captured Dart vectors (PRNG/seedForKey unchanged by the redesign) ----

const DART_SEED_KEY_2026_06_07_LEGENDARY = 550419188;

function assertRejectedStage(
  result: VerifyResult,
  stage: RejectionStage,
): void {
  assertFalse(result.valid);
  if (result.valid) return;
  assertEquals(result.reason, "invalid_run");
  assertEquals(result.stage, stage);
}

Deno.test("canFollow: accepts equal/ascend and rejects descend/skip", () => {
  assertEquals(canFollow(3, 3), true);
  assertEquals(canFollow(3, 4), true);
  assertFalse(canFollow(3, 2));
  assertFalse(canFollow(3, 5));
});

Deno.test("pairMergeable: symmetric tier rule without a cosmetic milestone cap", () => {
  assertEquals(pairMergeable(3, 3), true);
  assertEquals(pairMergeable(3, 4), true);
  assertEquals(pairMergeable(4, 3), true);
  assertFalse(pairMergeable(3, 5));
  assertEquals(pairMergeable(kMaxTier - 1, kMaxTier), true);
  assertEquals(pairMergeable(kMaxTier, kMaxTier), true);
});

const DART_PRNG: Record<string, number[]> = {
  "1": [
    2693262067,
    11749833,
    2265367787,
    4213581821,
    4159151403,
    1207330352,
    2632122864,
    3095568220,
    1828783984,
    4272732017,
    1955374602,
    2099329838,
    596715197,
    1734070562,
    1063107040,
    663542962,
    2100857034,
    289351446,
    1694877057,
    3294703884,
  ],
  "42": [
    2581720956,
    1925393290,
    3661312704,
    2876485805,
    750819978,
    2261697747,
    1173505300,
    2683257857,
    3717185310,
    2028586305,
    1073414265,
    3788413843,
    3202918453,
    1318561460,
    847198783,
    2150616774,
    2948976162,
    2622596789,
    16505353,
    2021992966,
  ],
  "0x9E3779B9": [
    1541420728,
    454851044,
    2900350524,
    3942498910,
    436270539,
    1292797714,
    107332754,
    2003106812,
    1860262629,
    2351451603,
    2189223826,
    1319006189,
    3858527959,
    1458065988,
    439542631,
    1065433749,
    1124176789,
    3650098597,
    824228062,
    2846529103,
  ],
  "keyHash": [
    4278839893,
    1416147163,
    1509739711,
    3814287932,
    3837562946,
    3501279784,
    1635852863,
    2569168105,
    2576248468,
    2155669214,
    853677039,
    3297811397,
    4082003367,
    3270720374,
    1308521369,
    3090506910,
    624426149,
    2081899626,
    3346979326,
    656422535,
  ],
};

// ---- Captured Connect-Merge board + run vectors (2026-06-07) ----

// legendary: 6×6 grid (36 cells), 6 walls, 15 starting tiles.
const DART_LEGENDARY_WALLS = [0, 1, 5, 6, 17, 26];
const DART_LEGENDARY_CELLS: (Tile | null)[] = (() => {
  const c: (Tile | null)[] = new Array(36).fill(null);
  c[3] = { id: 4, tier: 2 };
  c[7] = { id: 1, tier: 1 };
  c[12] = { id: 11, tier: 1 };
  c[15] = { id: 5, tier: 1 };
  c[16] = { id: 3, tier: 1 };
  c[20] = { id: 10, tier: 2 };
  c[23] = { id: 13, tier: 1 };
  c[24] = { id: 12, tier: 1 };
  c[25] = { id: 0, tier: 2 };
  c[27] = { id: 14, tier: 1 };
  c[28] = { id: 2, tier: 2 };
  c[29] = { id: 6, tier: 1 };
  c[30] = { id: 9, tier: 1 };
  c[32] = { id: 8, tier: 1 };
  c[34] = { id: 7, tier: 2 };
  return c;
})();
const DART_LEGENDARY_NEXT_TILE_ID = 15;
// Greedy 3-chain run captured from TS seeder (paths applied to the evolving board).
const DART_LEGIT_LEGENDARY: MoveEvent[] = [
  { type: "chain", path: [15, 16] },
  { type: "chain", path: [10, 16] },
  { type: "chain", path: [23, 29] },
];
const DART_LEGIT_LEGENDARY_SCORE = 16;
const DART_LEGIT_LEGENDARY_TIER = 3;

// easy: 8×8 grid (64 cells), 2 walls, 40 starting tiles.
const DART_EASY_SEED = 628821332;
const DART_EASY_CELLS: (Tile | null)[] = (() => {
  const c: (Tile | null)[] = new Array(64).fill(null);
  c[0] = { id: 13, tier: 1 };
  c[1] = { id: 12, tier: 1 };
  c[4] = { id: 37, tier: 1 };
  c[5] = { id: 5, tier: 1 };
  c[6] = { id: 4, tier: 2 };
  c[9] = { id: 1, tier: 2 };
  c[11] = { id: 11, tier: 2 };
  c[13] = { id: 36, tier: 2 };
  c[14] = { id: 16, tier: 1 };
  c[17] = { id: 19, tier: 2 };
  c[18] = { id: 22, tier: 1 };
  c[19] = { id: 18, tier: 2 };
  c[21] = { id: 15, tier: 2 };
  c[22] = { id: 30, tier: 1 };
  c[26] = { id: 23, tier: 2 };
  c[27] = { id: 20, tier: 1 };
  c[29] = { id: 35, tier: 1 };
  c[30] = { id: 39, tier: 1 };
  c[31] = { id: 25, tier: 1 };
  c[32] = { id: 17, tier: 1 };
  c[33] = { id: 8, tier: 1 };
  c[34] = { id: 32, tier: 1 };
  c[35] = { id: 27, tier: 2 };
  c[36] = { id: 2, tier: 2 };
  c[38] = { id: 6, tier: 2 };
  c[40] = { id: 26, tier: 1 };
  c[41] = { id: 10, tier: 1 };
  c[44] = { id: 31, tier: 1 };
  c[45] = { id: 7, tier: 2 };
  c[46] = { id: 0, tier: 1 };
  c[47] = { id: 14, tier: 2 };
  c[49] = { id: 33, tier: 1 };
  c[50] = { id: 24, tier: 2 };
  c[52] = { id: 34, tier: 1 };
  c[54] = { id: 21, tier: 2 };
  c[56] = { id: 29, tier: 1 };
  c[57] = { id: 3, tier: 1 };
  c[58] = { id: 38, tier: 1 };
  c[59] = { id: 9, tier: 2 };
  c[62] = { id: 28, tier: 2 };
  return c;
})();
const DART_EASY_NEXT_TILE_ID = 40;
// Greedy 2-chain run captured from TS seeder (paths applied to the evolving board).
const DART_LEGIT_EASY: MoveEvent[] = [
  { type: "chain", path: [0, 1] },
  { type: "chain", path: [1, 9] },
  { type: "chain", path: [4, 5] },
  { type: "chain", path: [5, 6] },
  { type: "chain", path: [11, 19] },
  { type: "chain", path: [13, 21] },
  { type: "chain", path: [14, 22] },
];
const DART_LEGIT_EASY_SCORE = 44;
const DART_LEGIT_EASY_TIER = 3;

// ---- PRNG parity ----

Deno.test("PRNG matches Dart vectors byte-for-byte", () => {
  const cases: [string, number][] = [
    ["1", 1],
    ["42", 42],
    ["0x9E3779B9", 0x9e3779b9],
    ["keyHash", DART_SEED_KEY_2026_06_07_LEGENDARY],
  ];
  for (const [label, seed] of cases) {
    const p = new Prng(seed);
    const got = Array.from({ length: 20 }, () => p.nextU32());
    assertEquals(
      got,
      DART_PRNG[label],
      `PRNG sequence mismatch for seed ${label}`,
    );
  }
});

Deno.test("seedForKey matches Dart byte-order reduction", async () => {
  assertEquals(
    await seedForKey("2026-06-07:legendary"),
    DART_SEED_KEY_2026_06_07_LEGENDARY,
  );
  assertEquals(await seedForKey("2026-06-07:easy"), DART_EASY_SEED);
});

// ---- Board parity (walls + re-roll) ----

Deno.test("legendary board for 2026-06-07 matches Dart (walls + re-roll)", async () => {
  const start = await new DailySeeder("2026-06-07", "legendary").generate();
  assertEquals(start.board.cells, DART_LEGENDARY_CELLS);
  assertEquals(start.board.nextTileId, DART_LEGENDARY_NEXT_TILE_ID);
  assertEquals(
    [...start.board.walls].sort((a, b) => a - b),
    DART_LEGENDARY_WALLS,
  );
  // A re-rolled board is, by construction, never born-deadlocked.
  assertEquals(hasMergeAvailable(start.board), true);
});

Deno.test("easy board for 2026-06-07 matches Dart (walls + placement)", async () => {
  const start = await new DailySeeder("2026-06-07", "easy").generate();
  assertEquals(start.board.cells, DART_EASY_CELLS);
  assertEquals(start.board.nextTileId, DART_EASY_NEXT_TILE_ID);
  assertEquals([...start.board.walls].sort((a, b) => a - b), [25, 42]);
});

Deno.test(
  "no born-short boards under minChainLength 3 (Long Chains Only) across 2026-06",
  async () => {
    // Mirrors the actual verifyRunChallenge call site: dense starting fill +
    // minChainLength 3, so the re-roll must find a board that already
    // satisfies the rule's stricter minimum, not just any 2-chain.
    for (let day = 1; day <= 28; day++) {
      const date = `2026-06-${String(day).padStart(2, "0")}`;
      const start = await new DailySeeder(date, "challenge").generate({
        startingFillOverride: kChallengeDenseFill,
        minChainLength: 3,
      });
      assertEquals(
        hasChainOfLength(start.board.cells, start.board.gridSize, 3),
        true,
        `Born-short board (no 3-chain): ${date} challenge`,
      );
    }
  },
);

// ---- Replay parity ----

Deno.test("verifyRun on captured legit legendary run matches Dart score", async () => {
  const r = await verifyRun("2026-06-07", "legendary", DART_LEGIT_LEGENDARY);
  assertEquals(r.valid, true);
  assertEquals(r.score, DART_LEGIT_LEGENDARY_SCORE);
  assertEquals(r.highestTier, DART_LEGIT_LEGENDARY_TIER);
});

Deno.test("verifyRun on captured legit easy run matches Dart score", async () => {
  const r = await verifyRun("2026-06-07", "easy", DART_LEGIT_EASY);
  assertEquals(r.valid, true);
  assertEquals(r.score, DART_LEGIT_EASY_SCORE);
  assertEquals(r.highestTier, DART_LEGIT_EASY_TIER);
});

Deno.test("verifyRun accepts the spec short-form {t:...} event shape", async () => {
  const shortForm = DART_LEGIT_EASY.map((e) =>
    e.type === "chain" ? { t: "chain", path: e.path } : { t: "continue" }
  );
  const r = await verifyRun("2026-06-07", "easy", shortForm);
  assertEquals(r.valid, true);
  assertEquals(r.score, DART_LEGIT_EASY_SCORE);
});

// ---- Tamper rejection ----

Deno.test("rejects an illegal chain (wall cells, always empty)", async () => {
  const tampered: MoveEvent[] = [
    ...DART_LEGIT_LEGENDARY,
    { type: "chain", path: [0, 1] }, // wall cells — always empty
  ];
  assertRejectedStage(
    await verifyRun("2026-06-07", "legendary", tampered),
    "illegal_chain",
  );
});

Deno.test("accepts an ascending chain (adjacent tiles one tier apart)", async () => {
  // easy initial: cell 5 (tier1) is orthogonally adjacent to cell 6 (tier2) —
  // this is now a legal ascend-by-1 chain, not a rejection case.
  const r = await verifyRun("2026-06-07", "easy", [{
    type: "chain",
    path: [5, 6],
  }]);
  assertEquals(r.valid, true);
  assertEquals(r.score, (2 ** 2) * comboMultiplier(2) + ascendBonus(2));
});

Deno.test("rejects a non-adjacent chain", async () => {
  // easy initial: cells 9 and 11 share tier 2 and are in the same row but not adjacent (gap=2).
  const r = await verifyRun("2026-06-07", "easy", [{
    type: "chain",
    path: [9, 11],
  }]);
  assertFalse(r.valid);
});

Deno.test("rejects a continue while still playing (not out of moves)", async () => {
  const r = await verifyRun("2026-06-07", "easy", [
    { type: "chain", path: [0, 1] }, // valid first move
    { type: "continue" }, // illegal: board is still playing
  ]);
  assertRejectedStage(r, "continue_wrong_status");
});

Deno.test("rejects an invalid difficulty", async () => {
  assertRejectedStage(
    await verifyRun("2026-06-07", "impossible", DART_LEGIT_LEGENDARY),
    "invalid_difficulty",
  );
});

Deno.test("rejects a malformed move log", async () => {
  assertRejectedStage(
    await verifyRun("2026-06-07", "legendary", null),
    "malformed_log",
  );
  assertRejectedStage(
    await verifyRun("2026-06-07", "legendary", [{ type: "teleport" }]),
    "malformed_event",
  );
  assertRejectedStage(
    await verifyRun("2026-06-07", "legendary", [{ type: "chain" }]),
    "malformed_event",
  );
  assertRejectedStage(
    await verifyRun("2026-06-07", "legendary", [{ type: "chain", path: [1] }]),
    "illegal_chain",
  );
});

Deno.test("challenge verifier tags malformed, short-chain, and continue stages", async () => {
  assertRejectedStage(
    await verifyRunChallenge("2026-07-24", null),
    "challenge_malformed_log",
  );
  assertRejectedStage(
    await verifyRunChallenge("2026-07-24", [{ type: "teleport" }]),
    "challenge_malformed_event",
  );
  assertRejectedStage(
    await verifyRunChallenge("2026-07-24", [{ type: "chain", path: [0, 1] }]),
    "challenge_chain_too_short",
  );
  assertRejectedStage(
    await verifyRunChallenge("2026-07-18", [{ type: "continue" }]),
    "challenge_continue_forbidden",
  );
});

// ---- Pure unit tests (formula-pinned, no Dart capture needed) ----

function boardWith(
  tiles: Record<number, Tile>,
  walls: number[] = [],
): BoardState {
  const cells: (Tile | null)[] = new Array(kCellCount).fill(null);
  for (const [k, v] of Object.entries(tiles)) cells[Number(k)] = v;
  return {
    cells,
    walls: new Set(walls),
    movesRemaining: 30,
    score: 0,
    nextTileId: 100,
    dropIndex: 0,
    adContinuesUsed: 0,
    movesMade: 0,
    status: "playing",
    gridSize: 5,
  };
}

function smallBoard(cells: (Tile | null)[], dropIndex = 0): BoardState {
  return {
    cells,
    walls: new Set(),
    movesRemaining: 30,
    score: 0,
    nextTileId: 100,
    dropIndex,
    adContinuesUsed: 0,
    movesMade: 0,
    status: "playing",
    gridSize: 2,
  };
}

Deno.test("refillBoard: fills to target when a merge already exists", () => {
  const board = smallBoard([
    { id: 1, tier: 1 },
    { id: 2, tier: 1 },
    null,
    null,
  ]);
  const result = refillBoard(board, 3, () => 4, new Prng(1));
  assertEquals(result.cells.filter((tile) => tile !== null).length, 3);
  assertEquals(result.dropIndex, 1);
});

Deno.test("refillBoard: tops up beyond target until full without a merge", () => {
  const board = smallBoard([
    { id: 1, tier: 1 },
    { id: 2, tier: 3 },
    { id: 3, tier: 5 },
    null,
  ]);
  const result = refillBoard(board, 3, () => 7, new Prng(1));
  assertEquals(result.cells.filter((tile) => tile !== null).length, 4);
  assertEquals(result.dropIndex, 1);
  assertFalse(hasMergeAvailable(result));
});

Deno.test("refillBoard: full board stops without reading tierAt", () => {
  let reads = 0;
  const board = smallBoard([
    { id: 1, tier: 1 },
    { id: 2, tier: 3 },
    { id: 3, tier: 3 },
    { id: 4, tier: 1 },
  ]);
  const result = refillBoard(
    board,
    4,
    () => {
      reads++;
      return 1;
    },
    new Prng(1),
  );
  assertEquals(result, board);
  assertEquals(reads, 0);
});

Deno.test("refillBoard: reads current dropIndex for every applied drop", () => {
  const reads: number[] = [];
  const board = smallBoard([
    { id: 1, tier: 1 },
    { id: 2, tier: 1 },
    null,
    null,
  ], 7);
  const result = refillBoard(
    board,
    4,
    (dropIndex) => {
      reads.push(dropIndex);
      return 1;
    },
    new Prng(1),
  );
  assertEquals(reads, [7, 8]);
  assertEquals(result.dropIndex, 9);
});

Deno.test("mergedTierFromSum: exact powers stay exact and lossy sums round down", () => {
  assertEquals(mergedTierFromSum(2 + 2), 2);
  assertEquals(mergedTierFromSum(2 + 2 + 2 + 2), 3);
  assertEquals(mergedTierFromSum(4 + 4 + 4 + 4), 4);
  assertEquals(mergedTierFromSum(2 + 4), 2);
});

Deno.test("mergedTierFromSum: integer boundaries cover and exceed the play bound", () => {
  const maxMoves = kMovesPerDay + kMaxAdContinuesPerDay * kAdMoveReward;
  const maxRefillsPerMove = GRID_SIZE.easy ** 2 - WALL_COUNT.easy - 1;
  const maxDropValue = 2 ** dropCap(maxMoves * maxRefillsPerMove - 1);
  const maxInitialMass = STARTING_FILL.easy * 2 ** dropCap(0);
  const derivedMass = maxMoves * maxRefillsPerMove * maxDropValue +
    maxInitialMass;
  assertEquals(derivedMass, kMaxPlayableValueMass);
  assertEquals(mergedTierFromSum(2 ** 17), kMaxPlayableTier);
  assertEquals(mergedTierFromSum(2 ** 18 - 1), 17);
  assertEquals(mergedTierFromSum(2 ** 18), 18);
  assertEquals(kMaxPlayableValueMass, 152416);
  assertEquals(mergedTierFromSum(kMaxPlayableValueMass), kMaxPlayableTier);
  assertEquals(mergedTierFromSum(Number.MAX_SAFE_INTEGER), 52);
});

Deno.test("a real-bound sum can collapse to tier 17 without a legality cap", () => {
  const b = boardWith({
    0: { id: 1, tier: 16 },
    1: { id: 2, tier: 16 },
  });
  assertEquals(isValidChain(b, [0, 1]), true);
  assertEquals(collapseChain(b, [0, 1]).cells[1]?.tier, kMaxPlayableTier);
});

Deno.test("areAdjacent: all eight neighbors, but no row wrap or gaps", () => {
  assertEquals(areAdjacent(0, 1, 5), true);
  assertEquals(areAdjacent(0, 5, 5), true);
  assertEquals(areAdjacent(0, 6, 5), true);
  assertEquals(areAdjacent(1, 5, 5), true);
  assertEquals(areAdjacent(4, 5, 5), false); // row wrap
  assertEquals(areAdjacent(0, 2, 5), false); // gap
});

Deno.test("isValidChain: accepts a connected same-tier run, rejects bad paths", () => {
  const b = boardWith({
    0: { id: 1, tier: 2 },
    1: { id: 2, tier: 2 },
    6: { id: 3, tier: 2 }, // index 6 adjacent to 1
  });
  assertEquals(isValidChain(b, [0, 1, 6]), true);
  assertFalse(isValidChain(b, [0])); // too short
  assertFalse(isValidChain(b, [0, 1, 0])); // repeat
  assertFalse(isValidChain(b, [0, 5])); // cell 5 empty
});

Deno.test("isValidChain: accepts an ascend-by-1 step, rejects descend and skip", () => {
  const b = boardWith({
    0: { id: 1, tier: 2 },
    1: { id: 2, tier: 3 }, // east of 0, one tier higher
    2: { id: 3, tier: 5 }, // east of 1, skips a tier
  });
  assertEquals(isValidChain(b, [0, 1]), true); // ascend by 1
  assertFalse(isValidChain(b, [1, 0])); // descend (3 -> 2)
  assertFalse(isValidChain(b, [1, 2])); // skip (3 -> 5)
});

Deno.test("isValidChain: accepts a run-then-ascend-then-run chain", () => {
  const b = boardWith({
    0: { id: 1, tier: 1 },
    1: { id: 2, tier: 1 },
    6: { id: 3, tier: 1 },
    7: { id: 4, tier: 2 },
    8: { id: 5, tier: 2 },
    13: { id: 6, tier: 3 },
  });
  assertEquals(isValidChain(b, [0, 1, 6, 7, 8, 13]), true);
});

Deno.test("isValidChain: accepts an ascend chain beyond the 2048 milestone", () => {
  const b = boardWith({
    0: { id: 1, tier: kMaxTier - 1 },
    1: { id: 2, tier: kMaxTier },
  });
  assertEquals(isValidChain(b, [0, 1]), true);
});

Deno.test("isValidChain: rejects a path onto a wall cell", () => {
  const b = boardWith({ 0: { id: 1, tier: 2 } }, [1]);
  assertFalse(isValidChain(b, [0, 1])); // cell 1 is a wall (no tile)
});

Deno.test("isValidChain: diagonal steps may cross two walled flanking cells", () => {
  const b = boardWith({
    0: { id: 1, tier: 2 },
    6: { id: 2, tier: 2 },
  }, [1, 5]);
  assertEquals(isValidChain(b, [0, 6]), true);
});

Deno.test("collapseChain: endpoint uses floor-power-of-two sum and keeps id", () => {
  const b = boardWith({
    0: { id: 10, tier: 2 },
    1: { id: 11, tier: 2 },
    6: { id: 12, tier: 2 }, // endpoint
  });
  const r = collapseChain(b, [0, 1, 6]);
  assertEquals(r.cells[0], null);
  assertEquals(r.cells[1], null);
  assertEquals(r.cells[6], { id: 12, tier: 3 });
  assertEquals(r.score, (2 ** 3) * comboMultiplier(3)); // 16
  assertEquals(r.movesRemaining, 29);
});

Deno.test("collapseChain: ascending chain scores base combo PLUS an ascend bonus per transition", () => {
  const b = boardWith({
    0: { id: 10, tier: 1 },
    1: { id: 11, tier: 1 },
    6: { id: 12, tier: 2 },
    7: { id: 13, tier: 2 },
    8: { id: 14, tier: 3 },
  });
  const r = collapseChain(b, [0, 1, 6, 7, 8]);
  assertEquals(r.cells[8], { id: 14, tier: 4 });
  assertEquals(
    r.score,
    (2 ** 4) * comboMultiplier(5) + ascendBonus(2) + ascendBonus(3),
  );
});

Deno.test("collapseChain: a flat (same-tier) chain has zero ascend bonus", () => {
  const b = boardWith({
    0: { id: 10, tier: 2 },
    1: { id: 11, tier: 2 },
  });
  const r = collapseChain(b, [0, 1]);
  assertEquals(r.score, (2 ** 3) * comboMultiplier(2));
});

Deno.test("collapseChain: lossy 2+4 sum floors to tier 2 and still scores", () => {
  const b = boardWith({
    0: { id: 10, tier: 1 },
    1: { id: 11, tier: 2 },
  });
  const r = collapseChain(b, [0, 1]);
  assertEquals(r.cells[1], { id: 11, tier: 2 });
  assertEquals(r.score, (2 ** 2) * comboMultiplier(2) + ascendBonus(2));
});

Deno.test("collapseChain: four twos pin default and Combo Rush scores", () => {
  const b = boardWith({
    0: { id: 10, tier: 1 },
    1: { id: 11, tier: 1 },
    6: { id: 12, tier: 1 },
    7: { id: 13, tier: 1 },
  });
  const regular = collapseChain(b, [0, 1, 6, 7]);
  const rush = collapseChain(b, [0, 1, 6, 7], comboRushMultiplier);
  assertEquals(regular.cells[7], { id: 13, tier: 3 });
  assertEquals(regular.score, (2 ** 3) * comboMultiplier(4));
  assertEquals(rush.score, (2 ** 3) * comboRushMultiplier(4));
});

Deno.test("collapseChain: uses exponentiation beyond bitwise shift range", () => {
  const b = boardWith({
    0: { id: 1, tier: 31 },
    1: { id: 2, tier: 31 },
  });
  const r = collapseChain(b, [0, 1]);
  assertEquals(r.cells[1], { id: 2, tier: 32 });
  assertEquals(r.score, 2 ** 32);
  assertFalse(r.score === (1 << 32));
});

Deno.test("hasMergeAvailable: needs ADJACENT equal tiles (spatial deadlock)", () => {
  const apart = boardWith({ 0: { id: 1, tier: 1 }, 2: { id: 2, tier: 1 } });
  assertFalse(hasMergeAvailable(apart));
  const together = boardWith({ 0: { id: 1, tier: 1 }, 6: { id: 2, tier: 1 } });
  assertEquals(hasMergeAvailable(together), true);
});

Deno.test("hasMergeAvailable: also finds an ascend-adjacent pair (differs by exactly 1 tier)", () => {
  const b = boardWith({ 0: { id: 1, tier: 2 }, 1: { id: 2, tier: 3 } });
  assertEquals(hasMergeAvailable(b), true);
});

Deno.test("hasMergeAvailable: a 2-tier gap is NOT available", () => {
  const b = boardWith({ 0: { id: 1, tier: 2 }, 1: { id: 2, tier: 4 } });
  assertFalse(hasMergeAvailable(b));
});

// ---- hasChainOfLength tests (Long Chains Only deadlock fix) ----

Deno.test("hasChainOfLength: minLength <= 2 is byte-identical to hasMergeAvailable", () => {
  const apart = boardWith({ 0: { id: 1, tier: 1 }, 2: { id: 2, tier: 1 } });
  const together = boardWith({ 0: { id: 1, tier: 1 }, 1: { id: 2, tier: 1 } });
  assertEquals(
    hasChainOfLength(apart.cells, apart.gridSize, 2),
    hasMergeAvailable(apart),
  );
  assertEquals(
    hasChainOfLength(together.cells, together.gridSize, 2),
    hasMergeAvailable(together),
  );
  assertEquals(hasChainOfLength(together.cells, together.gridSize, 2), true);
});

Deno.test("hasChainOfLength: only a 2-chain exists => no chain of length 3", () => {
  const b = boardWith({
    0: { id: 1, tier: 1 },
    1: { id: 2, tier: 1 },
    6: { id: 3, tier: 5 },
  });
  assertFalse(hasChainOfLength(b.cells, b.gridSize, 3));
});

Deno.test("hasChainOfLength: a real 3-chain (straight line) satisfies length 3", () => {
  const b = boardWith({
    0: { id: 1, tier: 1 },
    1: { id: 2, tier: 1 },
    2: { id: 3, tier: 2 },
  });
  assertEquals(hasChainOfLength(b.cells, b.gridSize, 3), true);
  assertEquals(isValidChain(b, [0, 1, 2]), true);
});

Deno.test("hasChainOfLength: a diagonal-only chain satisfies length 3", () => {
  const b = boardWith({
    0: { id: 1, tier: 2 },
    6: { id: 2, tier: 2 },
    12: { id: 3, tier: 2 },
  });
  assertEquals(hasChainOfLength(b.cells, b.gridSize, 3), true);
  assertEquals(isValidChain(b, [0, 6, 12]), true);
});

Deno.test(
  "hasChainOfLength: a chain beyond the 2048 milestone still counts",
  () => {
    const b = boardWith({
      0: { id: 1, tier: kMaxTier - 2 },
      1: { id: 2, tier: kMaxTier - 1 },
      2: { id: 3, tier: kMaxTier },
    });
    assertEquals(hasChainOfLength(b.cells, b.gridSize, 3), true);
  },
);

Deno.test(
  "hasChainOfLength: does not falsely find a chain across a non-adjacent path",
  () => {
    const b = boardWith({
      0: { id: 1, tier: 1 },
      1: { id: 2, tier: 1 },
      20: { id: 3, tier: 1 },
      21: { id: 4, tier: 1 },
    });
    assertFalse(hasChainOfLength(b.cells, b.gridSize, 3));
  },
);

Deno.test(
  "refillBoard: keeps dropping past a 2-chain-satisfied state when minLength is 3",
  () => {
    const board = smallBoard([
      { id: 1, tier: 1 },
      { id: 2, tier: 1 },
      null,
      null,
    ]);
    const result = refillBoard(board, 2, () => 1, new Prng(1), 3);
    assertEquals(hasChainOfLength(result.cells, result.gridSize, 3), true);
  },
);

Deno.test(
  "refillBoard: stops at a full board even if minChainLength is never satisfied",
  () => {
    const board = smallBoard([{ id: 1, tier: 1 }, null, null, null]);
    const result = refillBoard(board, 1, () => kMaxTier, new Prng(1), 5);
    assertEquals(result.cells.every((c) => c !== null), true);
    assertFalse(hasChainOfLength(result.cells, result.gridSize, 5));
  },
);

Deno.test(
  "evaluateStatus: minChainLength 3 deadlocks on a bare 2-chain (Long Chains Only soft-lock fix)",
  () => {
    const onlyTwoChain = boardWith({
      0: { id: 1, tier: 1 },
      1: { id: 2, tier: 1 },
    });
    assertEquals(evaluateStatus(onlyTwoChain, 3).status, "deadlocked");
    assertEquals(evaluateStatus(onlyTwoChain).status, "playing");

    const realThreeChain = boardWith({
      0: { id: 1, tier: 1 },
      1: { id: 2, tier: 1 },
      2: { id: 3, tier: 2 },
    });
    assertEquals(evaluateStatus(realThreeChain, 3).status, "playing");
  },
);

// ---- comboRushMultiplier tests ----

Deno.test("comboRushMultiplier N=2 matches comboMultiplier (no doubling)", () => {
  assertEquals(comboRushMultiplier(2), comboMultiplier(2));
});

Deno.test("comboRushMultiplier N=3 returns doubled multiplier", () => {
  assertEquals(comboRushMultiplier(3), comboMultiplier(3) * 2);
});

Deno.test("comboRushMultiplier N=4 returns doubled multiplier", () => {
  assertEquals(comboRushMultiplier(4), comboMultiplier(4) * 2);
});
