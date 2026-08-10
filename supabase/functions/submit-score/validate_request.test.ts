import { validateSubmitRequest } from "./validate_request.ts";
import { kLeaderboardSeason } from "../_shared/constants.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

const TODAY = "2026-08-08";

Deno.test("validateSubmitRequest: accepts a well-formed same-day request", () => {
  const result = validateSubmitRequest(
    {
      date: TODAY,
      difficulty: "easy",
      moveLog: [],
      season: kLeaderboardSeason,
    },
    TODAY,
  );
  assertEquals(result, {
    ok: true,
    date: TODAY,
    difficulty: "easy",
    moveLog: [],
    season: kLeaderboardSeason,
  });
});

Deno.test("validateSubmitRequest: null payload is malformed_request", () => {
  assertEquals(validateSubmitRequest(null, TODAY), {
    ok: false,
    reason: "malformed_request",
  });
});

Deno.test("validateSubmitRequest: non-object payload is malformed_request", () => {
  assertEquals(validateSubmitRequest("not an object", TODAY), {
    ok: false,
    reason: "malformed_request",
  });
});

Deno.test("validateSubmitRequest: missing/mistyped date is malformed_request", () => {
  assertEquals(
    validateSubmitRequest(
      { date: 123, difficulty: "easy", moveLog: [] },
      TODAY,
    ),
    { ok: false, reason: "malformed_request" },
  );
});

Deno.test("validateSubmitRequest: missing/mistyped difficulty is malformed_request", () => {
  assertEquals(
    validateSubmitRequest({ date: TODAY, difficulty: 5, moveLog: [] }, TODAY),
    { ok: false, reason: "malformed_request" },
  );
});

Deno.test("validateSubmitRequest: unrecognized difficulty is malformed_request", () => {
  assertEquals(
    validateSubmitRequest(
      { date: TODAY, difficulty: "impossible", moveLog: [] },
      TODAY,
    ),
    { ok: false, reason: "malformed_request" },
  );
});

Deno.test("validateSubmitRequest: a date that isn't the server's today is stale_date, not malformed_request", () => {
  assertEquals(
    validateSubmitRequest(
      {
        date: "2026-08-01",
        difficulty: "easy",
        moveLog: [],
        season: kLeaderboardSeason,
      },
      TODAY,
    ),
    { ok: false, reason: "stale_date" },
  );
});

Deno.test("validateSubmitRequest: missing season is internally stale but externally invalid_run", () => {
  assertEquals(
    validateSubmitRequest(
      { date: TODAY, difficulty: "easy", moveLog: [] },
      TODAY,
    ),
    {
      ok: false,
      reason: "invalid_run",
      stage: "stale_season",
      suppliedSeason: null,
      difficulty: "easy",
    },
  );
});

Deno.test("validateSubmitRequest: mismatched season is internally stale but externally invalid_run", () => {
  assertEquals(
    validateSubmitRequest(
      { date: TODAY, difficulty: "easy", moveLog: [], season: 1 },
      TODAY,
    ),
    {
      ok: false,
      reason: "invalid_run",
      stage: "stale_season",
      suppliedSeason: 1,
      difficulty: "easy",
    },
  );
});

Deno.test("validateSubmitRequest: stale season takes precedence over stale date", () => {
  assertEquals(
    validateSubmitRequest(
      {
        date: "2026-06-06",
        difficulty: "easy",
        moveLog: [],
        season: kLeaderboardSeason - 1,
      },
      TODAY,
    ),
    {
      ok: false,
      reason: "invalid_run",
      stage: "stale_season",
      suppliedSeason: kLeaderboardSeason - 1,
      difficulty: "easy",
    },
  );
});
