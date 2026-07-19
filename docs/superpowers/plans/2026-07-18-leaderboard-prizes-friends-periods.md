# Leaderboard Prizes and Friends Period Boards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair leaderboard reads under self-only player RLS, add bounded
caller-rank prize seams and friends period boards, and ship the frozen payout,
catch-up, and presentation behavior.

**Architecture:** Bounded definer display projections are separate from
invoker caller-rank queries over world-readable scores. Existing injected
service seams feed serialized, oldest-first client prize commits and the
existing leaderboard row UI.

**Tech Stack:** PostgreSQL/Supabase SQL, Dart 3, Flutter, flutter_bloc,
supabase_flutter, Flutter test.

## Global Constraints

- Follow frozen root `PLAN.md` exactly; this document records rather than redesigns it.
- Do not touch `lib/domain/engine/`, `lib/domain/constants.dart`, `supabase/functions/`, or golden-vector fixtures.
- Do not add dependencies or change `kLeaderboardSeason`.
- Every SQL function pins `set search_path = public` and uses explicit revoke-before-grant ACLs.
- Every display limit uses `least(greatest(coalesce(p_limit, 100), 1), 100)`.
- Caller-rank functions rank all players before filtering to `auth.uid()`.
- Catch-up is bounded, oldest-first, stops on first failure, and advances only a contiguous successful prefix.
- Every behavior change starts with a focused failing test and receives the minimum implementation.
- Final proof is a fresh `flutter analyze` followed by a full `flutter test`.

---

### Task 1: Record the approved design and execution plan

**Files:**

- Create: `docs/superpowers/specs/2026-07-18-leaderboard-prizes-friends-periods-design.md`
- Create: `docs/superpowers/plans/2026-07-18-leaderboard-prizes-friends-periods.md`

**Interfaces:**

- Consumes: frozen root `PLAN.md`.
- Produces: the database, service, catch-up, UI, and proof contracts used below.

- [ ] Write both dated documents before tests or production changes.
- [ ] Re-read root `PLAN.md` and verify every Approach step maps to a task.
- [ ] Run `git diff --check` and inspect the two new documents.

### Task 2: Add the bounded leaderboard read migration and smoke script

**Files:**

- Create: `supabase/migrations/0010_leaderboard_read_rpcs.sql`
- Create: `supabase/tests/leaderboard_smoke.sql`

**Interfaces:**

- Produces: `leaderboard(date,text,int,int)`,
  `leaderboard_period(text,date,date,int,int)`,
  `friends_leaderboard(date,text,int,int)`,
  `friends_leaderboard_period(text,date,date,int,int)`,
  `my_daily_ranks(date,date,int)`, and `my_period_ranks(date,date,int)`.
- Preserves: existing named-parameter callers and season filtering.

- [ ] Write smoke assertions for both friendship directions, self inclusion,
      non-friend exclusion, season/date filters, boundary ties, non-winner
      ranks, all limit clamps, range rejections, and anon ACL rejection.
- [ ] Add diagnostic `EXPLAIN` statements for `idx_scores_board_season` and
      `idx_friendships_b` without asserting plan shapes.
- [ ] Run `supabase --version` and `supabase db --help` before invoking the CLI.
- [ ] Run `supabase db reset`, then
      `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f supabase/tests/leaderboard_smoke.sql`.
- [ ] If the local database runtime is unavailable, preserve the runnable
      smoke script and report the exact environmental blocker.

### Task 3: Add service caller-rank and friends-period seams

**Files:**

- Modify: `test/infrastructure/leaderboard_service_test.dart`
- Modify: `test/infrastructure/friends_service_test.dart`
- Modify: `lib/infrastructure/leaderboard_service.dart`
- Modify: `lib/infrastructure/friends_service.dart`

**Interfaces:**

- Produces: `Future<Map<String, Map<Difficulty, int>>> myDailyRanks({required String from, required String to})`.
- Produces: `Future<Map<Difficulty, int>> myPeriodRanks({required String from, required String to})`.
- Produces: `Future<List<LeaderboardEntry>> friendsLeaderboardPeriod({required Difficulty difficulty, required String from, required String to})`.

- [ ] Add failing payload/mapping tests for all three methods, including
      `total` to `LeaderboardEntry.score` and current season parameters.
- [ ] Run the two infrastructure test files and confirm failures are missing-method failures.
- [ ] Add only the three service methods using the existing injected RPC seams.
- [ ] Rerun both infrastructure test files and require green.

### Task 4: Implement payout tables and bounded catch-up

**Files:**

- Modify: `test/application/daily_prize_test.dart`
- Modify: `test/application/weekly_prize_test.dart`
- Modify: `test/application/monthly_prize_test.dart`
- Modify: `test/application/challenge_payout_test.dart`
- Modify: `test/application/engagement_test.dart`
- Modify: `lib/application/engagement_cubit.dart`
- Modify: `lib/main.dart`
- Modify: `lib/domain/models/weekly_prize.dart`

**Interfaces:**

- `checkDailyPrizes` and `checkChallengePayouts` consume the `myDailyRanks` method shape.
- `checkWeeklyPrizes` and `checkMonthlyPrizes` consume the `myPeriodRanks` method shape.
- Preserves: four public checker names, serialized commit helper, guard fields,
  one payout per period across tiers, and weekly per-tier crown records.

- [ ] Add failing boundary tests: ordinary rank 5 pays and rank 6 does not;
      Challenge rank 10 pays 5 and rank 11 does not.
- [ ] Add failing catch-up tests for null guards, oldest-first gaps, daily seven
      days, weekly four weeks, monthly two months, and a mid-window fetch failure
      that halts then retries from the failed period.
- [ ] Run the five application test files and confirm failures reflect the old
      payout values, callback shapes, and single-period behavior.
- [ ] Implement the exact payout tables and minimal UTC period enumeration.
- [ ] Replace display-RPC callbacks in `main.dart` with the caller-rank methods.
- [ ] Update all source prize comments from top-three to ranks 1–5 where applicable.
- [ ] Rerun the five focused application tests and `test/application/engagement_test.dart`.

### Task 5: Mirror every period in Friends and coerce Challenge to daily

**Files:**

- Modify: `test/presentation/leaderboard_screen_test.dart`
- Modify: `lib/presentation/screens/leaderboard_screen.dart`

**Interfaces:**

- Consumes: `FriendsService.friendsLeaderboardPeriod`.
- Preserves: `LeaderboardPeriod.range`, global routing, Challenge prize markers,
  and `LeaderboardRow` reuse.

- [ ] Add failing widget tests for period controls in Friends scope, friends
      period RPC routing, period-to-Challenge daily routing in both scopes,
      100 visible Challenge rows, rank-11 without a marker, and rank-4/5 crowns.
- [ ] Run `flutter test test/presentation/leaderboard_screen_test.dart` and
      confirm the old screen fails those behaviors.
- [ ] Show period controls in both scopes for non-Challenge tiers.
- [ ] Compute the effective daily period for Challenge inside `_load`, route
      Friends period calls, change `take(10)` to `take(100)`, and add the medal fallback.
- [ ] Rerun the screen and period-range test files and require green.

### Task 6: Verify the complete feature

**Files:**

- Review every file changed by Tasks 1–5.

**Interfaces:**

- Consumes: every root `PLAN.md` requirement and non-goal.
- Produces: analyzer/test proof and a scoped change report.

- [ ] Run `dart format` on changed Dart files only.
- [ ] Run all focused service, application, and presentation suites.
- [ ] Re-read root `PLAN.md` line by line and remove scope creep.
- [ ] Confirm forbidden paths, season, dependencies, and golden fixtures are untouched.
- [ ] Run `flutter analyze` and require `No issues found!`.
- [ ] Run `flutter test` and require `All tests passed!`.
- [ ] Run `git diff --check`, inspect `git diff --stat`, and inspect `git status --short`.
- [ ] Report one line per changed file, proof output, and every deviation with its reason.

## Out of Scope

- Server-side wallets, snapshots, cron, or scheduled payouts.
- Friends-board prizes or a combined cross-tier board.
- Engine, TypeScript replay, season, or golden-vector changes.
- Claimed-period re-evaluation or dual payout tables.
- Storage-wide profile serialization or an offline submit queue.
