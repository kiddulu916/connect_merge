// submit-score Edge Function.
//
// Auth -> parse -> replay-verify -> upsert best score -> return rank.
// The client submits ONLY the move log; the server regenerates the
// (date,difficulty) board, replays the log to compute the authoritative score,
// and is the only writer to `scores` (via the service-role key, which bypasses
// RLS — clients have no insert/update policy).
//
// Responses:
//   200 { valid, score, highestTier, rank }
//   401 no/invalid auth
//   422 { valid:false, reason:"invalid_run" }  (illegal log / wrong date / etc.)
//   422 { valid:false, reason:"submit_failed" } (retryable database failure)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.107.0";
import { verifyRun, verifyRunChallenge } from "../_shared/engine.ts";
import { isDifficulty, kLeaderboardSeason } from "../_shared/constants.ts";
import { corsHeaders, getAuthedUserId, jsonResponse } from "../_shared/http.ts";
import { upsertBestScore } from "./best_score.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const CORS_HEADERS = corsHeaders("*");

function json(body: unknown, status: number): Response {
  return jsonResponse(CORS_HEADERS, body, status);
}

/** Server's notion of "today" in UTC (YYYY-MM-DD). */
function utcToday(): string {
  return new Date().toISOString().slice(0, 10);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  // 1. Authenticate: resolve the caller's user id from their JWT.
  const userId = await getAuthedUserId(req, SUPABASE_URL, ANON_KEY);
  if (userId == null) return json({ error: "unauthorized" }, 401);

  // 2. Parse + validate the request shape.
  let payload: { date?: unknown; difficulty?: unknown; moveLog?: unknown };
  try {
    payload = await req.json();
  } catch {
    return json({ valid: false, reason: "invalid_run" }, 422);
  }
  const { date, difficulty, moveLog } = payload;
  if (typeof date !== "string" || typeof difficulty !== "string") {
    return json({ valid: false, reason: "invalid_run" }, 422);
  }
  if (!isDifficulty(difficulty)) {
    return json({ valid: false, reason: "invalid_run" }, 422);
  }
  // No backfilling other days: the submitted date must be the server's UTC today.
  if (date !== utcToday()) {
    return json({ valid: false, reason: "invalid_run" }, 422);
  }

  // 3. Replay-verify. The server is the only score authority.
  const result = difficulty === "challenge"
    ? await verifyRunChallenge(date, moveLog)
    : await verifyRun(date, difficulty, moveLog);
  if (!result.valid) {
    return json({ valid: false, reason: "invalid_run" }, 422);
  }

  // 4. Upsert best score for (player, date, difficulty) using the service role.
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  // Atomically keep the best score for this player/date/tier/season. The RPC is
  // service-role-only; replay verification above remains the trust boundary.
  const best = await upsertBestScore(
    async (fn, params) => {
      const { data, error } = await admin.rpc(fn, params);
      return { data, error };
    },
    {
      playerId: userId,
      date,
      difficulty,
      season: kLeaderboardSeason,
      score: result.score,
      highestTier: result.highestTier,
    },
  );
  if (best == null) {
    // FK violation (no player row) or other DB/RPC error.
    return json({ valid: false, reason: "submit_failed" }, 422);
  }
  const keepScore = best.score;
  const keepTier = best.highestTier;

  // 5. Compute the player's rank for (date, difficulty) by their best score.
  const { count: higherCount } = await admin
    .from("scores")
    .select("*", { count: "exact", head: true })
    .eq("utc_date", date)
    .eq("difficulty", difficulty)
    .eq("season", kLeaderboardSeason)
    .gt("score", keepScore);

  const rank = (higherCount ?? 0) + 1;

  return json(
    { valid: true, score: keepScore, highestTier: keepTier, rank },
    200,
  );
});
