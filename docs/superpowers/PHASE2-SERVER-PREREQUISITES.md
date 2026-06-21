# Phase 2 Server — Connect-Merge Replay Engine

**Status: code-complete (client + server). Only live DB migration + function
deploy remain.**

`onSubmitRun` is now **wired** in `TierSelectScreen` (online only), so completed
runs will POST their move log. The server engine is **ported to Connect-Merge**
and the **Deno parity tests pass (19/19)**.

⚠️ **Until you apply the migration and deploy the Edge Function (below), live
submissions are INERT**: the currently-deployed (pre-redesign) `submit-score`
will reject `ChainEvent` runs with 422. The client treats submission as
best-effort and swallows the error, so nothing crashes — but no scores are
recorded until the deploy. Do the two steps below to make it live.

---

## What was implemented (this PR)

The server mirror at `supabase/functions/_shared/` was ported from the
pre-redesign pairwise-merge model to Connect-Merge:

| # | Change | File |
|---|--------|------|
| 1 | Parse `ChainEvent` (ordered cell-index path) + `continue` | `engine.ts` (`parseEvent`) |
| 2 | Path geometry validation (orthogonal adjacency, same tier < cap, simple path, no walls) | `engine.ts` (`isValidChain`, `areOrthogonallyAdjacent`) |
| 3 | On-demand drop-tier stream `"$date:$difficulty:drops"` (replaces the bounded list) | `seeder.ts` (`dropTierPrng`, `dropTierAt`) |
| 4 | Multi-drop top-up-to-`startingFill` refill after each chain | `engine.ts` (`verifyRun`) |
| 5 | Spatial `hasMergeAvailable` (adjacent equal tiles only) | `engine.ts` |
| 6 | `collapseChain` + `comboScore` (`(1<<(tier+1)) * comboMultiplier(len)`) | `engine.ts`, `constants.ts` |
| 7 | Seed-derived walls + born-deadlock re-roll (cap `kMaxPlacementAttempts = 5000`, throws on exceed) — must match the client exactly | `seeder.ts` (`wallIndices`, `generate`), `constants.ts` (`WALL_COUNT`) |
| 8 | `season` column + read-RPC filters + Edge-Function write/read | `migrations/0006_connect_merge_season.sql`, `submit-score/index.ts`, `constants.ts` (`kLeaderboardSeason`) |

Determinism is pinned by `supabase/functions/_shared/engine.test.ts`, whose
board/run vectors were freshly captured from the Dart engine (the PRNG and
`seedForKey` vectors are unchanged). The board-parity tests (`legendary`/`easy`
for `2026-06-07`) are the CI gate: if the TS board ≠ the Dart board, they fail.

The client also now sends `p_season` on **all three** read RPCs
(`leaderboard`, `leaderboard_period`, and `friends_leaderboard` — the last was
missed in the original Task 17 change) so the hard reset is complete.

### Server scope note
The server only reconstructs what affects **score + board geometry**. Golden
tiles, the daily objective, coins, and XP never touch `score` or the `moveLog`,
so they are intentionally NOT ported to the server.

---

## Remaining operational steps (to make live submission work)

Run from the repo root.

1. **Deno parity tests — ALREADY PASSING (19/19).** The cross-language
   determinism gate has been run and is green; the board-parity tests prove the
   TS seeder reproduces the Dart board byte-for-byte (walls + re-roll included).
   Re-run any time (e.g. in CI) with:
   ```
   deno test supabase/functions/_shared/engine.test.ts
   ```

2. **Apply the migration** to the linked Supabase project:
   ```
   supabase db push
   ```
   (or run `supabase/migrations/0006_connect_merge_season.sql` against the DB).
   This adds `scores.season` (existing rows default to season 1) and recreates
   the three read RPCs with a `p_season` filter.

3. **Deploy the Edge Function** (now stamps + filters by `season`):
   ```
   supabase functions deploy submit-score
   ```

4. **Wire `onSubmitRun`** — ✅ DONE (in `TierSelectScreen._submitRun`, wired only
   when a `LeaderboardService` is present). Becomes effective the moment steps 2–3
   are deployed; no further client change needed.

---

## Current state

| Gate | State |
|------|-------|
| `onSubmitRun` wired in `TierSelectScreen` | ✅ Wired (online only); runs POST their move log |
| Server engine ported to Connect-Merge | ✅ Verified — Deno parity tests pass 19/19 |
| Edge Function deployed | ⏳ Pending `supabase functions deploy submit-score` |
| `season` migration applied to live DB | ⏳ Pending `supabase db push` |

Live submission starts working once the two ⏳ items are deployed. Until then,
submissions are sent but rejected by the old function (swallowed, no crash).

---

## Reference Files

- Client seeder: `lib/domain/engine/daily_seeder.dart`
- Client engine: `lib/domain/engine/game_engine.dart`
- Server seeder: `supabase/functions/_shared/seeder.ts`
- Server engine: `supabase/functions/_shared/engine.ts`
- Server parity tests: `supabase/functions/_shared/engine.test.ts`
- Submit Edge Function: `supabase/functions/submit-score/index.ts`
- Season migration: `supabase/migrations/0006_connect_merge_season.sql`
- Constants (both sides): `lib/domain/constants.dart`,
  `supabase/functions/_shared/constants.ts`
- Move model: `lib/domain/models/move.dart` (`ChainEvent`)
