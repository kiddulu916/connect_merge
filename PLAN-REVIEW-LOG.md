# Plan Review Log: top-5 leaderboard prizes, challenge top-10 payout, friends period boards

Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.

(The prior task's log — remove the legacy single-pair merge path — lives in git history at c765da8.)

Grill decisions (user-confirmed): lazy client-grant payout model retained (earned at period close, credited on next launch — no midnight server job); literal "slightly increased" payout tables (daily 50/30/15/10/5, weekly 75/45/25/15/10, monthly 100/60/35/20/15 — a deliberate weekly/monthly nerf); challenge = top-10 broad-and-shallow (20 / 15 / 15 / 10×3 / 5×4), uncapped list with top-10 markers kept; friends boards = view-only mirror of all periods (new `friends_leaderboard_period` RPC); challenge stays daily-only in both scopes. Established from code: daily reset + weekly/monthly/all-time boards + completed-period prize timing + reward-free all-time board all already exist; only payout tables, the challenge cap, and the friends period path change. No engine/TS/season change.

## Round 1 — Codex

Material problems:

1. **RLS breaks the proposed RPC.** `players` is self-only under RLS, so a `security invoker` join cannot read friends’ display names; the existing RPC pattern being copied is itself suspect. See [0001_players_scores.sql](C:/Users/dat1k/Projects/connect_merge/supabase/migrations/0001_players_scores.sql:34) and [0006_connect_merge_season.sql](C:/Users/dat1k/Projects/connect_merge/supabase/migrations/0006_connect_merge_season.sql:49).  
   Fix: Use a tightly scoped `SECURITY DEFINER` RPC with an auth guard, pinned search path, explicit columns, and locked-down execute grants—or introduce a safe leaderboard-profile projection.

2. **“Authenticated only” is not achieved by `GRANT` alone.** PostgreSQL grants new functions to `PUBLIC` by default, exactly the vulnerability migration 0004 previously fixed.  
   Fix: Explicitly `REVOKE EXECUTE ... FROM PUBLIC, anon` before granting `authenticated`.

3. **No database test exercises the migration.** Fake Dart RPC tests cannot detect RLS, ACL, ranking, season-filter, or bidirectional-friendship failures.  
   Fix: Add a local-Supabase integration test with two friendship directions, self, non-friend exclusion, season/date filtering, ties, and anon rejection.

4. **Challenge can silently load a period board.** Selecting Weekly/Monthly/All-time and then switching to Challenge hides the period control but leaves `_period` unchanged, so `_load()` calls the period RPC. See [leaderboard_screen.dart](C:/Users/dat1k/Projects/connect_merge/lib/presentation/screens/leaderboard_screen.dart:267).  
   Fix: Force an effective Daily period whenever `difficulty == Difficulty.challenge`, and test the period→Challenge transition in both scopes.

5. **The rank-4/5 crown assumption is false.** One crown switch falls back to a medal, but `_weekCrown` returns `null`, so those crowns disappear from leaderboard rows. See [leaderboard_screen.dart](C:/Users/dat1k/Projects/connect_merge/lib/presentation/screens/leaderboard_screen.dart:299).  
   Fix: Add the medal fallback to `_weekCrown` and widget-test rank 4 and rank 5.

6. **The stated tie guarantee is false for daily and challenge payouts.** The daily RPC limits output to 100 and does not guarantee inclusion of the caller, so a tied rank-5/10 player outside the arbitrary first 100 receives nothing. See [0006_connect_merge_season.sql](C:/Users/dat1k/Projects/connect_merge/supabase/migrations/0006_connect_merge_season.sql:43).  
   Fix: Use a dedicated authenticated caller-rank RPC, or make the leaderboard RPC always union the caller’s ranked row.

7. **Cross-tier payout semantics are undocumented.** Current code pays only the single best qualifying rank across four difficulty boards, even when the player places top five on several boards. See [engagement_cubit.dart](C:/Users/dat1k/Projects/connect_merge/lib/application/engagement_cubit.dart:375).  
   Fix: Explicitly confirm and document “one best payout per period,” or sum per-tier payouts and test that behavior.

8. **“Credited on next launch” fails after a gap.** Each checker evaluates only yesterday/the immediately previous week/month and then advances its guard, permanently skipping older unclaimed wins.  
   Fix: Iterate unclaimed closed periods from the stored guard to the latest eligible period, with an explicit first-run floor.

9. **Prize commits race with other profile writes.** `_prizeCommit` serializes only prize methods, while startup launches them unawaited and purchases/completions can concurrently overwrite the same whole profile. See [main.dart](C:/Users/dat1k/Projects/connect_merge/lib/main.dart:132) and [engagement_cubit.dart](C:/Users/dat1k/Projects/connect_merge/lib/application/engagement_cubit.dart:403).  
   Fix: Route every profile read-modify-write through one storage-level serialized update operation and test prize-versus-purchase concurrency.

10. **The offline-queue tradeoff describes nonexistent behavior.** Failed submissions are logged and discarded; the code explicitly says queue/retry is future work. See [game_cubit.dart](C:/Users/dat1k/Projects/connect_merge/lib/application/game_cubit.dart:550).  
    Fix: Remove the queued-score claim and state offline runs are ineligible, or add durable retry as a separately scoped feature.

11. **Period totals can overflow.** PostgreSQL `sum(int)` returns `bigint`, but the copied RPC casts it back to `int`; all-time totals can exceed 2,147,483,647. See [0006_connect_merge_season.sql](C:/Users/dat1k/Projects/connect_merge/supabase/migrations/0006_connect_merge_season.sql:81).  
    Fix: Return `total bigint` without the `::int` cast and keep mapping through Dart `num.toInt()`.

12. **“Up to 100 rows” is false in Friends scope.** `friends_leaderboard` has no limit, so removing `take(10)` makes Friends Challenge unbounded.  
    Fix: Replace the challenge cap with `take(100)` or add an explicit `p_limit` to the friends RPC.

13. **The no-index claim is unsupported.** The friendship primary key indexes `a` but not reverse-edge lookups by `b`, while the score index places `difficulty` after a date-range column.  
    Fix: Add `friendships(b)` and verify the score path with `EXPLAIN`; only then decide whether a period-specific score index is necessary.

VERDICT: REVISE
### Claude's response (round 1)

Verified against the code before revising. Accepted 10 of 13, partially accepted 2, rejected 1:

- **#1 ACCEPTED (and verified — it's a live pre-existing bug, not just a plan flaw).** `players` has only the self-only `player_self` policy (0001:34); all three read RPCs are `security invoker`, so shipped boards can only return the caller's own row. Plan now converts all four read RPCs to tightly-scoped `SECURITY DEFINER` projections. A world-read policy on `players` was rejected because it would expose `friend_code` via PostgREST.
- **#2 ACCEPTED.** Explicit revoke-from-public/anon before grant, per the repo's own 0004 pattern.
- **#3 PARTIAL.** Full local-Supabase integration-test harness rejected — the repo has none and 0002/0003/0006 shipped RPCs without one; building that infra is out of scope. Instead: a checked-in SQL smoke script run against `supabase db reset`, covering exactly Codex's listed cases (both edge directions, non-friend exclusion, season/date filters, boundary tie, caller-row union, anon rejection, EXPLAIN).
- **#4 ACCEPTED.** Latent stale-`_period` bug on the challenge tab confirmed at `leaderboard_screen.dart:275` — `_load()` never checks difficulty. Challenge is forced to daily in `_load()`, tested in both scopes.
- **#5 ACCEPTED.** `_weekCrown` returns null above rank 3; 🏅 fallback added + widget tests for ranks 4/5.
- **#6 ACCEPTED.** Stronger than Codex stated, even: in a deterministic daily puzzle mass ties at the optimum are *plausible*, not exotic. `leaderboard` RPC now unions the caller's ranked row.
- **#7 ACCEPTED as documentation.** One-best-payout-per-period across tiers kept (summing would ~4× the economy for multi-tier players and wasn't requested); now stated explicitly in the plan.
- **#8 ACCEPTED with bounds.** Catch-up iteration from the stored guard, bounded at 7 days / 4 weeks / 2 months / 7 challenge days; null-guard first run checks only the newest closed period.
- **#9 REJECTED (logged, risk documented).** The profile-write race is a pre-existing trait of *every* profile writer; adopting a serialized `updateProfile` only in prize code would not close the race with non-adopting writers, and the full refactor is separately scoped. Added to Risks and Out of scope.
- **#10 ACCEPTED.** The plan's "offline-queued" wording described nonexistent behavior (submissions are dropped on failure, `game_cubit.dart:550`); risk reworded, durable queue listed as out of scope.
- **#11 ACCEPTED.** `total` becomes `bigint` in both period RPCs; Dart mapping already goes through `num.toInt()`.
- **#12 ACCEPTED.** Client-side `take(100)` on the challenge board (simpler than adding `p_limit` to the friends RPC).
- **#13 PARTIAL.** No speculative `friendships(b)` index — same access pattern as the shipped `friends_leaderboard` on tiny friend sets; the smoke script's EXPLAIN is the gate. Plan wording softened from "no new index needed" to "EXPLAIN decides".

## Round 2 — Codex

Most prior findings are addressed: RLS/ACLs, caller-row inclusion, bigint totals, challenge routing/cap, crowns, cross-tier semantics, missed-period intent, offline-queue wording, and database coverage.

Remaining/new problems:

1. **Global period results become unbounded.** Fixing RLS makes `leaderboard_period` finally return every player to anonymous callers, with no limit.  
   Fix: Add `p_limit` capped at 100 plus caller-row union, matching the daily RPC.

2. **`p_limit` remains attacker-controlled inside a DEFINER RPC.** `NULL` means unlimited and oversized values permit expensive responses.  
   Fix: Apply `least(greatest(coalesce(p_limit, 100), 1), 100)` inside the function and test null/negative/huge inputs.

3. **Catch-up failure semantics are unsafe.** “Newest period actually evaluated” could advance past a failed older period and permanently skip it.  
   Fix: Process oldest-first, stop on the first failed period, and advance only through the last contiguous success; add a failure/retry test.

4. **Catch-up cost is understated.** Worst case is 59 RPCs at startup: 28 daily + 16 weekly + 8 monthly + 7 challenge, with all four checkers launched concurrently.  
   Fix: Batch catch-up ranks server-side into a small fixed number of calls, or reduce the catch-up promise.

5. **The profile-write race is acknowledged, not addressed.** Catch-up adds more prize activity while purchases and completions can still lose whole-profile updates.  
   Fix: Add the storage-level serialized profile update before catch-up, then route all profile mutations through it.

6. **“Forward-only” conflicts with catch-up.** Unclaimed pre-release periods inside the lookback receive the new payout table retroactively.  
   Fix: Define a rollout effective date and either skip earlier periods or apply the prior tables to them.

7. **The reverse-edge index is still needed.** A small result set does not help: without `friendships(b)`, reverse lookups can scan the global friendship table.  
   Fix: Add `create index if not exists idx_friendships_b on friendships(b)`.

8. **The SQL smoke-test execution path is ambiguous.** `supabase db reset` does not automatically execute an arbitrary test script, while putting it in migrations risks deploying fixtures/assertions.  
   Fix: Store it outside `supabase/migrations` and specify the exact post-reset `psql -f` command.

9. **Several shipped comments will remain wrong.** `EngagementState` and prize-check documentation still describe top-three rewards.  
   Fix: Update every `top-3` prize comment found by repository search, not only `WeeklyPrize.rank`.

VERDICT: REVISE
### Claude's response (round 2)

Accepted 7 of 9, rejected 2 (one re-litigated, one replaced by a simpler decision):

- **#1 + #2 ACCEPTED, solved together with #4.** `leaderboard_period` gains a server-clamped `p_limit` (`least(greatest(coalesce(p_limit,100),1),100)`), and instead of unioning caller rows into display RPCs, prize checks move to two new tiny caller-rank RPCs (`my_daily_ranks`, `my_period_ranks`). Display boards become clamped-and-dumb; rank checks become exact under mass ties; catch-up drops from a worst case of 59 RPCs to 7.
- **#3 ACCEPTED.** Catch-up is oldest-first, halts at the first failed period, and advances the guard only through the last contiguous success — with a failure/retry test.
- **#4 ACCEPTED** via the batching above (1 daily-window call + 4 weekly + 2 monthly).
- **#5 REJECTED again (same grounds, unchanged by catch-up).** Catch-up adds a handful of serialized prize commits at startup — the race with non-prize profile writers is the same pre-existing race, same shape. A storage-level serialized `updateProfile` only helps if *every* writer adopts it; that refactor is separately scoped and now explicitly listed as such.
- **#6 REJECTED as machinery, ACCEPTED as a decision.** No effective-date / dual-table logic: unclaimed periods inside the lookback are paid at the new (nerfed) tables. Active users' guards are current at update time so the window is tiny; the simplicity is worth more than transitional payout fidelity. Documented in the plan.
- **#7 ACCEPTED, position reversed.** `auth.uid() in (a, b)` needs indexes on both columns to BitmapOr; the PK covers only `a`, so the reverse edge scans the global friendships table today. One-line `idx_friendships_b` beats an EXPLAIN gate.
- **#8 ACCEPTED.** Smoke script lives at `supabase/tests/leaderboard_smoke.sql` (outside migrations, can never deploy), exact run command specified (`supabase db reset` + `psql ... -f`).
- **#9 ACCEPTED.** Repo-wide `top-3`/`top-three` prize-comment sweep, not just `WeeklyPrize.rank`.

## Round 3 — Codex

Round-two findings addressed: period cap intent, limit clamping, ordered failure handling, lower catch-up fan-out, rollout semantics, reverse-edge index, smoke-test location, and stale comments.

Remaining/new problems:

1. **The new period signature breaks existing clients unless `p_limit` has a SQL default.** `fetchPeriod()` currently sends only four parameters.  
   Fix: Declare `p_limit int default 100` or update every caller to pass it explicitly.

2. **Caller-rank SQL can accidentally return rank 1 for everyone.** Filtering `player_id = auth.uid()` before the window function removes competitors before ranking.  
   Fix: Rank all players in a CTE, then filter to `auth.uid()` in the outer query; test a non-winning caller in both `my_*` RPCs.

3. **The `my_*` date ranges are unbounded trust-boundary inputs.** An authenticated caller can request an entire season and force expensive window/aggregation scans.  
   Fix: Reject reversed/future ranges and enforce seven-day `my_daily_ranks` and 31-day `my_period_ranks` maximums.

4. **“Bound every board” remains false.** Both friends RPCs lack `p_limit`, so large friend graphs produce unbounded results.  
   Fix: Add a clamped, defaulted `p_limit` to both friends RPCs and pass/default 100 in the service.

5. **The seven-call count lacks wiring.** Daily and challenge remain separate startup checkers, so each will call `myDailyRanks` unless a shared coordinator is added.  
   Fix: Add one combined daily/challenge check that fetches ranks once, or document the actual eight-call total.

6. **The `my_*` RPCs do not need DEFINER privileges.** They read only `scores`, whose SELECT policy is already world-readable.  
   Fix: Keep `my_*` as `SECURITY INVOKER`, restricted to `authenticated`, and reserve DEFINER for functions joining protected player data.

7. **The profile lost-update race is still only documented.** This remains a real wallet/purchase data-loss path while the feature adds catch-up commits.  
   Fix: Make storage-level serialized `updateProfile` a prerequisite and migrate every profile read-modify-write caller.

8. **Database verification omits the new period-rank failure mode.** Only a daily tie scenario is specified.  
   Fix: Add a `my_period_ranks` fixture where the caller is rank greater than one and tied at a payout boundary.

VERDICT: REVISE
### Claude's response (round 3)

Accepted 7 of 8, rejected 1 (third re-litigation):

- **#1 ACCEPTED.** `p_limit int default 100` on `leaderboard_period` — existing 4-arg `fetchPeriod()` callers keep working.
- **#2 ACCEPTED — real correctness landmine.** Both `my_*` RPCs rank all players in the inner query and filter to `auth.uid()` outside; a non-winning-caller fixture is added to the smoke script (and #8's period variant).
- **#3 ACCEPTED.** `my_*` range guards: reject reversed/future ranges; span caps of 7 days (`my_daily_ranks`) and 31 days (`my_period_ranks`).
- **#4 ACCEPTED.** Both friends RPCs get the clamped, defaulted `p_limit`.
- **#5 ACCEPTED as a count correction, not a coordinator.** The daily and challenge checkers stay separate (separate guards); the honest worst case is 8 calls, now documented. Merging them to save one RPC would tangle two independent guards — rejected as machinery.
- **#6 ACCEPTED.** `my_*` RPCs are `SECURITY INVOKER` — they read only world-readable `scores`; DEFINER stays reserved for the `players`-joining board projections.
- **#7 REJECTED (third time, same grounds).** The lost-update race predates this feature, is shared by every profile writer, and partial adoption cannot close it. Making a storage-level `updateProfile` + migration of all callers a *prerequisite* would couple an unrelated refactor to a payout-table change. It stays separately scoped, documented in Risks and Out of scope. This is a standing disagreement, not an oversight.
- **#8 ACCEPTED.** `my_period_ranks` smoke fixture with caller rank > 1, tied at a payout boundary.

## Round 4 — Codex

All material prior findings are addressed. The profile-write race remains logged as an accepted standing disagreement and is not counted against this review.

New non-blocking corrections:

- The tradeoff section still says catch-up costs 7 calls; the approach correctly calculates 8. Fix: change 7 to 8.
- The challenge-list note says the friends RPC lacks a server limit, but it now has one. Fix: describe `take(100)` as defense-in-depth or remove it.
- “All-time board: zero work” is stale because its RPC gains RLS repair, bigint totals, and a limit. Fix: change it to “no new gameplay behavior.”
- Tiny smoke fixtures may make PostgreSQL choose sequential scans despite valid indexes. Fix: treat `EXPLAIN` as diagnostic unless the script loads representative volume.

VERDICT: APPROVED
### Claude's response (round 4)

All four non-blocking corrections applied to PLAN.md: 7→8 calls in the tradeoff section; `take(100)` reframed as defense-in-depth; "all-time: zero work" → "no new gameplay behavior (inherits the RPC plumbing fixes)"; smoke-script EXPLAIN downgraded to diagnostic (tiny fixtures favor seq scans).

**Converged: APPROVED in round 4 of 5.** Standing disagreement on record: the storage-level serialized profile-update refactor (Codex rounds 1–3) is acknowledged as a real pre-existing lost-update path but deliberately excluded — it requires migrating every profile writer and is unchanged in kind by this feature.
