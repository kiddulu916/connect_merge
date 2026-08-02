import { upsertBestScore } from "./best_score.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

Deno.test("upsertBestScore calls the season-scoped RPC and returns its row", async () => {
  let calledFunction: string | undefined;
  let calledParams: Record<string, unknown> | undefined;
  const best = await upsertBestScore(async (fn, params) => {
    calledFunction = fn;
    calledParams = params;
    return {
      data: [{ score: 900, highest_tier: 7 }],
      error: null,
    };
  }, {
    playerId: "player-1",
    date: "2026-07-18",
    difficulty: "hard",
    season: 3,
    score: 900,
    highestTier: 7,
  });

  assertEquals(calledFunction, "upsert_best_score");
  assertEquals(calledParams, {
    p_player_id: "player-1",
    p_utc_date: "2026-07-18",
    p_difficulty: "hard",
    p_season: 3,
    p_score: 900,
    p_highest_tier: 7,
  });
  assertEquals(best, { score: 900, highestTier: 7 });
});

Deno.test("upsertBestScore rejects RPC errors and malformed rows", async () => {
  const params = {
    playerId: "player-1",
    date: "2026-07-18",
    difficulty: "hard",
    season: 3,
    score: 900,
    highestTier: 7,
  };

  assertEquals(
    await upsertBestScore(
      async () => ({ data: null, error: { message: "FK" } }),
      params,
    ),
    null,
  );
  assertEquals(
    await upsertBestScore(
      async () => ({ data: [{ score: "900" }], error: null }),
      params,
    ),
    null,
  );
});
