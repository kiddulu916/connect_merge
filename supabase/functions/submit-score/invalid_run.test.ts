import { assertEquals } from "@std/assert";
import { REJECTION_STAGES } from "../_shared/engine.ts";
import { type InvalidRunLog, logInvalidRun } from "./invalid_run.ts";

Deno.test("every internal rejection stage logs dimensions but returns only invalid_run", () => {
  for (const stage of [...REJECTION_STAGES, "stale_season"] as const) {
    const records: InvalidRunLog[] = [];
    const body = logInvalidRun(
      { stage, suppliedSeason: 1, difficulty: "easy" },
      (record) => records.push(record),
    );

    assertEquals(body, { valid: false, reason: "invalid_run" }, stage);
    assertEquals(records, [{
      event: "submit_score_invalid_run",
      count: 1,
      stage,
      suppliedSeason: 1,
      difficulty: "easy",
    }], stage);
  }
});
