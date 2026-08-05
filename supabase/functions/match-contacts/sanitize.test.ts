// Unit tests for match-contacts request validation.
// Run: deno test supabase/functions/match-contacts/sanitize.test.ts

import { assertEquals } from "@std/assert";
import { MAX_HASHES, sanitizeHashes } from "./sanitize.ts";

const VALID = "a".repeat(64); // 64 hex chars
const VALID2 = "b".repeat(64);

Deno.test("rejects non-array", () => {
  assertEquals(sanitizeHashes(null).ok, false);
  assertEquals(sanitizeHashes("x").ok, false);
  assertEquals(sanitizeHashes({}).ok, false);
});

Deno.test("rejects empty array", () => {
  assertEquals(sanitizeHashes([]).ok, false);
});

Deno.test("rejects oversized list (enumeration cap)", () => {
  const big = new Array(MAX_HASHES + 1).fill(VALID);
  assertEquals(sanitizeHashes(big).ok, false);
});

Deno.test("accepts valid hashes and de-duplicates", () => {
  const res = sanitizeHashes([VALID, VALID, VALID2]);
  assertEquals(res.ok, true);
  if (res.ok) {
    assertEquals(res.hashes.sort(), [VALID, VALID2].sort());
  }
});

Deno.test("drops malformed entries (not 64-hex)", () => {
  const res = sanitizeHashes([VALID, "short", "ZZZ", 123, null, "+14155550100"]);
  assertEquals(res.ok, true);
  if (res.ok) {
    assertEquals(res.hashes, [VALID]);
  }
});

Deno.test("all-malformed yields ok with empty list (caller returns [])", () => {
  const res = sanitizeHashes(["not-a-hash", "also-bad"]);
  assertEquals(res.ok, true);
  if (res.ok) assertEquals(res.hashes, []);
});

Deno.test("uppercase hex is rejected (server expects lowercase)", () => {
  const res = sanitizeHashes(["A".repeat(64)]);
  assertEquals(res.ok, true);
  if (res.ok) assertEquals(res.hashes, []);
});
