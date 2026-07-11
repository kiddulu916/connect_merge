// delete-account Edge Function.
//
// Erases a player's account: deleting the auth.users row cascades through
// players -> scores / friendships / contact_hashes (all FKs are ON DELETE
// CASCADE), so one admin deleteUser wipes everything server-side.
//
// Two callers, one function (deployed with verify_jwt DISABLED — the web form
// is unauthenticated by design; auth is handled per-path below):
//
//   1. In-app (Profile screen): called via functions.invoke with the player's
//      own session JWT. Deletes auth.uid() — no id in the payload, nothing to
//      spoof.
//   2. Web form (connectmerge.app/delete-my-data): no session exists (auth is
//      anonymous-only), so possession of the Player ID (the auth UUID, 122
//      bits, shown only to its owner in the app) IS the credential. The
//      response NEVER reveals whether the id matched an account — no
//      existence oracle.
//
// Feedback (web form only): optional username/reason are stored in
// deletion_feedback (no user id — the account is being erased) and ONLY when
// a real account was deleted, so the table can't be spammed anonymously.
//
// Responses: always 200 { ok: true } for well-formed requests, whether or not
// the id existed. 400 only for malformed input, 405 wrong method.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.107.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

// Only the delete-my-data page on the production site may call this from a
// browser. (The in-app path is a native HTTP call — CORS does not apply.)
// The apex connectmerge.app 308-redirects to www, so www is the real origin.
const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "https://www.connectmerge.app",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  // Path 1: in-app. A valid session JWT identifies the account; delete it.
  const authHeader = req.headers.get("Authorization");
  if (authHeader) {
    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData } = await userClient.auth.getUser();
    if (userData?.user) {
      await admin.auth.admin.deleteUser(userData.user.id);
      return json({ ok: true }, 200);
    }
    // An Authorization header that doesn't resolve (e.g. the anon key alone)
    // falls through to the web path.
  }

  // Path 2: web form. The Player ID in the body is the credential.
  let payload: { player_id?: unknown; username?: unknown; reason?: unknown };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "bad_request" }, 400);
  }
  const { player_id: playerId, username, reason } = payload;
  if (typeof playerId !== "string" || !UUID_RE.test(playerId.trim())) {
    return json({ error: "bad_request" }, 400);
  }

  const { error: deleteErr } = await admin.auth.admin.deleteUser(
    playerId.trim(),
  );

  // Feedback only when an account was actually deleted: inserting on every
  // request would make this endpoint an anonymous free-write into the table.
  if (!deleteErr) {
    const name = typeof username === "string" ? username.trim() : "";
    const text = typeof reason === "string" ? reason.trim() : "";
    if (name !== "" || text !== "") {
      await admin.from("deletion_feedback").insert({
        username: name === "" ? null : name.slice(0, 40),
        reason: text === "" ? null : text.slice(0, 2000),
      });
    }
  }

  // Generic response either way — no existence oracle.
  return json({ ok: true }, 200);
});
