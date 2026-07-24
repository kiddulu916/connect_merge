// match-contacts Edge Function.
//
// Privacy-first contacts matching. The client normalizes + SHA256-hashes each
// contact's phone/email ON DEVICE; only the hash list reaches this function.
// Raw phone/email NEVER leave the device. The function matches the submitted
// hashes against opted-in players' stored contact hashes (contact_hashes table)
// and returns only the matching opted-in player ids + display names. Players who
// have NOT opted in are invisible — so friend codes remain the primary path.
//
// Abuse mitigation (enumeration): the input list is size-capped and the caller
// must be authenticated. The function never reveals which specific hash matched
// a player, only the set of matched players.
//
// Responses:
//   200 { matches: [{ playerId, displayName }] }
//   400 { error:"bad_request" }   (malformed / too many hashes)
//   401 { error:"unauthorized" }

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.107.0";
import { sanitizeHashes } from "./sanitize.ts";
import { corsHeaders, getAuthedUserId, jsonResponse } from "../_shared/http.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const CORS_HEADERS = corsHeaders("*");

function json(body: unknown, status: number): Response {
  return jsonResponse(CORS_HEADERS, body, status);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  // 1. Authenticate the caller (also the implicit rate-limit subject).
  const callerId = await getAuthedUserId(req, SUPABASE_URL, ANON_KEY);
  if (callerId == null) return json({ error: "unauthorized" }, 401);

  // 2. Parse + validate. Only a list of 64-hex SHA256 hashes is accepted.
  let payload: { hashes?: unknown };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "bad_request" }, 400);
  }
  const sanitized = sanitizeHashes(payload.hashes);
  if (!sanitized.ok) {
    return json({ error: "bad_request" }, 400);
  }
  const hashes = sanitized.hashes;
  if (hashes.length === 0) {
    return json({ matches: [] }, 200);
  }

  // 3. Match against opted-in players' stored hashes (service role bypasses RLS
  //    for the cross-player lookup; contact_hashes is never client-readable).
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  const { data: matchedRows, error: matchErr } = await admin
    .from("contact_hashes")
    .select("player_id")
    .in("hash", hashes);
  if (matchErr) {
    return json({ error: "bad_request" }, 400);
  }

  // Unique matched player ids, excluding the caller themselves.
  const playerIds = [
    ...new Set(
      (matchedRows ?? [])
        .map((r: { player_id: string }) => r.player_id)
        .filter((id: string) => id !== callerId),
    ),
  ];
  if (playerIds.length === 0) {
    return json({ matches: [] }, 200);
  }

  // 4. Resolve display names for the matched players.
  const { data: players, error: playersErr } = await admin
    .from("players")
    .select("id, display_name")
    .in("id", playerIds);
  if (playersErr) {
    return json({ error: "bad_request" }, 400);
  }

  const matches = (players ?? []).map(
    (p: { id: string; display_name: string }) => ({
      playerId: p.id,
      displayName: p.display_name,
    }),
  );

  return json({ matches }, 200);
});
