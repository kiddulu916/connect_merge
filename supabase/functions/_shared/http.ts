// Shared Edge Function HTTP plumbing: CORS response building and JWT-based
// caller auth. Pure transport helpers — no game-rule logic, so this file is
// NOT part of the Dart/TS engine mirror (see engine.ts's own header comment).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.107.0";

export function corsHeaders(origin: string): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}

export function jsonResponse(
  headers: Record<string, string>,
  body: unknown,
  status: number,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...headers, "Content-Type": "application/json" },
  });
}

/**
 * Resolves the caller's user id from the request's Authorization header by
 * asking Supabase Auth to validate the JWT. Returns null when there is no
 * header or it doesn't resolve to a user (caller decides how to respond).
 */
export async function getAuthedUserId(
  req: Request,
  supabaseUrl: string,
  anonKey: string,
): Promise<string | null> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return null;
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data, error } = await userClient.auth.getUser();
  if (error || !data?.user) return null;
  return data.user.id;
}
