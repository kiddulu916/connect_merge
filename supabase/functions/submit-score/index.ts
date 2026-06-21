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

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.107.0";
import { verifyRun } from "../_shared/engine.ts";
import { isDifficulty, kLeaderboardSeason } from "../_shared/constants.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
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
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "unauthorized" }, 401);

  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) {
    return json({ error: "unauthorized" }, 401);
  }
  const userId = userData.user.id;

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
  const result = await verifyRun(date, difficulty, moveLog);
  if (!result.valid) {
    return json({ valid: false, reason: "invalid_run" }, 422);
  }

  // 4. Upsert best score for (player, date, difficulty) using the service role.
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  // Ensure the player row exists (FK target). If the client hasn't set a name
  // yet, we cannot enforce a leaderboard entry — but display name is required by
  // the client flow before submitting. Read the existing best to keep the max.
  const { data: existing } = await admin
    .from("scores")
    .select("score, highest_tier")
    .eq("player_id", userId)
    .eq("utc_date", date)
    .eq("difficulty", difficulty)
    .eq("season", kLeaderboardSeason)
    .maybeSingle();

  // Keep the higher of the existing best vs this run.
  const keepExisting = existing != null && existing.score >= result.score;
  const keepScore = keepExisting ? existing!.score : result.score;
  const keepTier = keepExisting ? existing!.highest_tier : result.highestTier;

  if (!existing || result.score > existing.score) {
    const { error: upsertErr } = await admin.from("scores").upsert(
      {
        player_id: userId,
        utc_date: date,
        difficulty,
        season: kLeaderboardSeason,
        score: result.score,
        highest_tier: result.highestTier,
      },
      { onConflict: "player_id,utc_date,difficulty" },
    );
    if (upsertErr) {
      // FK violation (no player row) or other DB error.
      return json({ valid: false, reason: "submit_failed" }, 422);
    }
  }

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
