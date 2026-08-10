// Pre-replay-verification request validation for submit-score, split into
// its own testable module (mirrors this repo's existing pattern of
// extracting Edge Function logic into small pure files — see best_score.ts,
// match-contacts/sanitize.ts — rather than testing Deno.serve handlers
// directly).
//
// Distinguishes causes that were previously conflated under one
// "invalid_run" reason: malformed requests and stale dates remain separately
// classified. A missing/mismatched leaderboard season is intentionally
// returned as the existing external "invalid_run" reason while carrying the
// internal-only `stale_season` stage used by server observability.

import {
  Difficulty,
  isDifficulty,
  kLeaderboardSeason,
} from "../_shared/constants.ts";

export type ValidatedRequest =
  | {
    ok: true;
    date: string;
    difficulty: Difficulty;
    moveLog: unknown;
    season: number;
  }
  | { ok: false; reason: "malformed_request" | "stale_date" }
  | {
    ok: false;
    reason: "invalid_run";
    stage: "stale_season";
    suppliedSeason: number | null;
    difficulty: Difficulty;
  };

/** Validates and classifies a submit-score request body against the
 * server's own notion of "today" ([utcToday]). A season mismatch returns the
 * existing external `invalid_run` reason with an internal-only stage tag. */
export function validateSubmitRequest(
  payload: unknown,
  utcToday: string,
): ValidatedRequest {
  if (payload === null || typeof payload !== "object") {
    return { ok: false, reason: "malformed_request" };
  }
  const { date, difficulty, moveLog, season } = payload as {
    date?: unknown;
    difficulty?: unknown;
    moveLog?: unknown;
    season?: unknown;
  };
  if (typeof date !== "string" || typeof difficulty !== "string") {
    return { ok: false, reason: "malformed_request" };
  }
  if (!isDifficulty(difficulty)) {
    return { ok: false, reason: "malformed_request" };
  }
  if (season !== kLeaderboardSeason) {
    return {
      ok: false,
      reason: "invalid_run",
      stage: "stale_season",
      suppliedSeason: typeof season === "number" ? season : null,
      difficulty,
    };
  }
  // No backfilling other days: the submitted date must be the server's UTC
  // today. This is a stale_date, not a malformed_request — the request
  // shape is fine, only its timing is wrong (clock skew or backfill).
  if (date !== utcToday) {
    return { ok: false, reason: "stale_date" };
  }
  return { ok: true, date, difficulty, moveLog, season };
}
