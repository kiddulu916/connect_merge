import { RejectionStage } from "../_shared/engine.ts";
import { Difficulty } from "../_shared/constants.ts";

export type InvalidRunStage = RejectionStage | "stale_season";

export interface InvalidRunLog {
  event: "submit_score_invalid_run";
  count: 1;
  stage: InvalidRunStage;
  suppliedSeason: number | null;
  difficulty: Difficulty;
}

export interface InvalidRunContext {
  stage: InvalidRunStage;
  suppliedSeason: number | null;
  difficulty: Difficulty;
}

export const INVALID_RUN_BODY = {
  valid: false,
  reason: "invalid_run",
} as const;

/**
 * Emits a structured, counter-friendly server record while preserving the
 * single client-visible invalid-run response contract.
 */
export function logInvalidRun(
  context: InvalidRunContext,
  log: (record: InvalidRunLog) => void = (record) => console.warn(record),
): typeof INVALID_RUN_BODY {
  log({
    event: "submit_score_invalid_run",
    count: 1,
    ...context,
  });
  return INVALID_RUN_BODY;
}
