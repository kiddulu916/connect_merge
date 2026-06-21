# Phase 2 Server — Connect-Merge Replay Engine

**Status: code-complete in the repo. Operational deploy steps remain (below).**

Production still does NOT call `onSubmitRun` (`TierSelectScreen` wires it to
`null`), so no live run reaches the server yet. The server engine has now been
**ported to the Connect-Merge model** so it is ready to verify runs once
`onSubmitRun` is wired. Before enabling online submit you must additionally
**apply the DB migration, deploy the Edge Function, and run the Deno parity
tests** (see "Remaining operational steps").

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

## Remaining operational steps (before wiring `onSubmitRun`)

Run from the repo root.

1. **Run the Deno parity tests** (the cross-language determinism gate). Deno was
   not available in the authoring environment, so this has NOT been executed yet:
   ```
   deno test supabase/functions/_shared/engine.test.ts
   ```
   All tests must pass. The board-parity tests prove the TS seeder reproduces the
   Dart board byte-for-byte (walls + re-roll included). If they fail, the TS port
   diverged from Dart — do not deploy until green.

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

4. **Wire `onSubmitRun`** in `TierSelectScreen` (pass the real
   `LeaderboardService.submitRun` instead of `null`) only after steps 1–3 pass.

---

## Current production safety

| Gate | State |
|------|-------|
| `onSubmitRun` is `null` in `TierSelectScreen` | No run reaches the server |
| Server engine ported to Connect-Merge | Ready to verify (pending `deno test` + deploy) |
| `season` migration not yet applied to live DB | Apply via step 2 before go-live |

All gates lift together when `onSubmitRun` is wired (step 4).

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
