import { assertEquals } from "@std/assert";
import {
  type ChallengeRule,
  type Difficulty,
  GRID_SIZE,
  kLeaderboardSeason,
} from "./constants.ts";
import { verifyRun, verifyRunChallenge } from "./engine.ts";
import fixture from "./golden_vectors.json" with { type: "json" };
import { challengeRule } from "./seeder.ts";

const REQUIRED_VECTOR_NAMES = new Set([
  "standard-easy",
  "standard-medium",
  "standard-hard",
  "standard-legendary",
  "challenge-budgetCut",
  "challenge-longChainsOnly",
  "challenge-denseStart",
  "challenge-sparseStart",
  "challenge-wallMaze",
  "challenge-comboRush",
  "standard-all-three-continues",
  "standard-no-continues",
]);

const REQUIRED_REJECTION_NAMES = new Set([
  "reject-fourth-continue",
  "reject-standard-post-budget-chain",
  "reject-budgetCut-post-budget-chain",
  "reject-non-budget-challenge-post-budget-chain",
  "reject-longChainsOnly-two-chain",
  "reject-legacy-merge-event",
]);

interface HonestVector {
  name: string;
  date: string;
  difficulty: string;
  rule?: ChallengeRule;
  moveLog: unknown[];
  expected: {
    valid: true;
    score: number;
    highestTier: number;
    status: string;
  };
}

interface RejectionVector {
  name: string;
  date: string;
  difficulty: string;
  rule?: ChallengeRule;
  moveLog: unknown[];
  expected: { valid: false };
}

const vectors = fixture.vectors as HonestVector[];
const rejections = fixture.rejections as RejectionVector[];

Deno.test("golden-vector fixture has the required dual-engine coverage", () => {
  assertEquals(fixture.season, kLeaderboardSeason);
  assertEquals(
    new Set(vectors.map((vector) => vector.name)),
    REQUIRED_VECTOR_NAMES,
  );
  assertEquals(
    new Set(rejections.map((rejection) => rejection.name)),
    REQUIRED_REJECTION_NAMES,
  );
  assertEquals(
    vectors.some(hasAllDiagonalChain),
    true,
    "fixture must exercise at least one all-diagonal chain",
  );
});

function hasAllDiagonalChain(vector: HonestVector): boolean {
  const gridSize = GRID_SIZE[vector.difficulty as Difficulty];
  return vector.moveLog.some((raw) => {
    if (typeof raw !== "object" || raw === null) return false;
    const event = raw as { type?: unknown; path?: unknown };
    if (
      event.type !== "chain" || !Array.isArray(event.path) ||
      event.path.length < 2
    ) {
      return false;
    }
    const path = event.path as number[];
    return path.slice(1).every((cell, index) => {
      const previous = path[index];
      const current = cell as number;
      const rowDelta = Math.abs(
        Math.floor(previous / gridSize) - Math.floor(current / gridSize),
      );
      const columnDelta = Math.abs(previous % gridSize - current % gridSize);
      return rowDelta === 1 && columnDelta === 1;
    });
  });
}

Deno.test("golden-vector honest runs replay through the TypeScript engine", async () => {
  for (const vector of vectors) {
    if (vector.difficulty === "challenge") {
      assertEquals(
        await challengeRule(vector.date),
        vector.rule,
        `${vector.name}: challenge-rule derivation drifted`,
      );
    }
    const result = vector.difficulty === "challenge"
      ? await verifyRunChallenge(vector.date, vector.moveLog)
      : await verifyRun(vector.date, vector.difficulty, vector.moveLog);
    assertEquals(
      {
        valid: result.valid,
        score: result.score,
        highestTier: result.highestTier,
      },
      {
        valid: vector.expected.valid,
        score: vector.expected.score,
        highestTier: vector.expected.highestTier,
      },
      vector.name,
    );
  }
});

Deno.test("golden-vector rejection sentinels are rejected", async () => {
  for (const rejection of rejections) {
    assertEquals(rejection.expected.valid, false, rejection.name);
    const result = rejection.difficulty === "challenge"
      ? await verifyRunChallenge(rejection.date, rejection.moveLog)
      : await verifyRun(
        rejection.date,
        rejection.difficulty,
        rejection.moveLog,
      );
    assertEquals(result.valid, false, rejection.name);
  }
});
