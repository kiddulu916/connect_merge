// Pre-replay-verification request validation for submit-score, split into
// its own testable module (mirrors this repo's existing pattern of
// extracting Edge Function logic into small pure files — see best_score.ts,
// match-contacts/sanitize.ts — rather than testing Deno.serve handlers
// directly).
//
// Distinguishes causes that were previously conflated under one
// "invalid_run" reason: a malformed/unrecognized request (client bug, may be
// fixed by a later client update) and a stale date (clock skew or a genuine
// backfill attempt) are both classified separately from "invalid_run",
// which this module never returns — that reason is reserved exclusively for
// an actual replay-verification failure, decided later in index.ts after
// this validation passes.

import { Difficulty, isDifficulty } from "../_shared/constants.ts";

export type ValidatedRequest =
  | { ok: true; date: string; difficulty: Difficulty; moveLog: unknown }
  | { ok: false; reason: "malformed_request" | "stale_date" };

/** Validates and classifies a submit-score request body against the
 * server's own notion of "today" ([utcToday]). Never returns
 * "invalid_run" — that reason belongs solely to replay-verification
 * failure, decided in index.ts after this function returns `ok: true`. */
export function validateSubmitRequest(
  payload: unknown,
  utcToday: string,
): ValidatedRequest {
  if (payload === null || typeof payload !== "object") {
    return { ok: false, reason: "malformed_request" };
  }
  const { date, difficulty, moveLog } = payload as {
    date?: unknown;
    difficulty?: unknown;
    moveLog?: unknown;
  };
  if (typeof date !== "string" || typeof difficulty !== "string") {
    return { ok: false, reason: "malformed_request" };
  }
  if (!isDifficulty(difficulty)) {
    return { ok: false, reason: "malformed_request" };
  }
  // No backfilling other days: the submitted date must be the server's UTC
  // today. This is a stale_date, not a malformed_request — the request
  // shape is fine, only its timing is wrong (clock skew or backfill).
  if (date !== utcToday) {
    return { ok: false, reason: "stale_date" };
  }
  return { ok: true, date, difficulty, moveLog };
}
