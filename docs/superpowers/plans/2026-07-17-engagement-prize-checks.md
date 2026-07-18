# Engagement Prize Check Deduplication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse the four prize checks behind small shared helpers while
fixing failure stamping, concurrent lost updates, local-time period parsing,
invalid challenge ranks, rollback guards, and post-write state reconciliation.

**Architecture:** Leaderboard fetches stay concurrent and feed a shared rank
collector. A cubit-local future chain serializes only commit-time profile
reload/guard/rewrite operations; four explicit public methods retain their
existing signatures and period-specific fields.

**Tech stack:** Dart/Flutter, flutter_bloc Cubit, existing `StorageService`,
Flutter test.

## Global constraints

- Follow frozen root `PLAN.md` exactly; this document records rather than
  redesigns it.
- Do not run any Git-mutating command. Reviewer-owned commit checkpoints are
  represented by read-only diff review only.
- Do not touch `lib/main.dart`, `lib/infrastructure/`, `supabase/`,
  `lib/domain/constants.dart`, or `pubspec.yaml`.
- Preserve the byte-identical public signatures of `checkDailyPrizes`,
  `checkWeeklyPrizes`, `checkMonthlyPrizes`, and `checkChallengePayouts`.
- Keep payout amounts and daily/weekly/monthly/challenge period definitions
  unchanged.
- Every behavior change starts with a focused failing test, then receives the
  minimum implementation and a focused passing run.
- Commit ordering is period math, cheap current-profile guard, fetch outside
  the mutex, abort on `null`, serialized reload, lexical guard recheck,
  compute, one save, and emit iff coins/crowns changed.
- The mutex guarantees serialization only among the four prize checks on one
  cubit; storage-wide atomicity is out of scope.

---

### Task 1: Record the frozen design and executable plan

**Files:**

- Create: `docs/superpowers/specs/2026-07-17-engagement-prize-checks-design.md`
- Create: `docs/superpowers/plans/2026-07-17-engagement-prize-checks.md`

**Interfaces:**

- Consumes: frozen root `PLAN.md`.
- Produces: the exact implementation order, helper contracts, and proof gates.

- [ ] Write both documents before changing any test or production file.
- [ ] Self-review for root-plan coverage, placeholder text, signature drift,
      forbidden paths, and missing failure/reconciliation cases.
- [ ] Run `git diff --check` and inspect a read-only scoped diff. Do not stage or
      commit; the reviewer owns all Git mutations.

### Task 2: Prize-check red-green implementation cycle

Root `PLAN.md` requires the complete regression surface before any production
edit, so Phases 2A–2E below are one task and one red-green cycle: all tests,
one combined old-code failing run, the minimum production implementation, one
combined passing run, then the reviewer-owned commit checkpoint.

#### Phase 2A: Pin payout, fetch, crown, guard, and UTC behavior

**Files:**

- Create: `test/application/daily_prize_test.dart`
- Modify: `test/application/weekly_prize_test.dart`
- Modify: `test/application/monthly_prize_test.dart`
- Modify: `test/application/challenge_payout_test.dart`
- Modify: `test/application/engagement_test.dart`

**Interfaces:**

- Exercises the four existing public callback signatures unchanged.
- Pins `previousUtcDay(String date)` through its existing public domain API.

- [ ] Add daily tests asserting rank-1 success grants/persists 50 coins and the
      `2026-06-22` guard, a second call does not fetch or pay again, and every
      fetch uses a non-challenge difficulty with date `2026-06-22`.
- [ ] Add weekly tests where one tier throws: the guard, coins, and crowns stay
      untouched, then a healthy retry pays and stamps. Add two consecutive
      top-three weeks and assert both weeks' crowns remain in storage and state.
- [ ] Add a weekly mixed-tier test (`hard=1`, `medium=3`, others unqualified)
      asserting 500 coins plus crowns for exactly hard and medium.
- [ ] Add challenge tests for ranks 0, 11, and 1, plus captured arguments
      `Difficulty.challenge` and yesterday's date.
- [ ] Add a lexical guard regression with a stored future guard and assert no
      fetch, payment, or guard rollback.
- [ ] Add zero-payout weekly and challenge listener tests asserting no state
      emission despite successful guard persistence.
- [ ] Add UTC boundary coverage: previous day across year rollover and leap
      day, weekly range across year rollover, and monthly leap-February range;
      retain the existing 28/30/31-day coverage.
- [ ] Run
      `flutter test test/application/daily_prize_test.dart test/application/weekly_prize_test.dart test/application/monthly_prize_test.dart test/application/challenge_payout_test.dart test/application/engagement_test.dart`.
      Require the old code to fail specifically on weekly abort-and-retry,
      rank-zero rejection, lexical guard hardening, and no-emission behavior.
- [ ] Do not modify production in this task. Inspect the read-only scoped diff;
      the reviewer commits after the eventual green gate.

#### Phase 2B: Pin serialization and persistence-failure recovery

**Files:**

- Modify: `test/application/engagement_test.dart`

**Interfaces:**

- Uses `StorageService` test fakes that delay, throw before writing, or delegate
  the write and then throw; production storage remains unchanged.
- Exercises all four public prize checks concurrently.

- [ ] Add a completer-backed storage fake that delays the first daily save.
      Start all four checks together, release the first save, await all futures,
      and assert all four guards plus the sum of all payouts survive in storage
      and state, with weekly crowns retained.
- [ ] Add a pre-write throwing fake. Assert `_onError`, no state emission, no
      stamped guard, then disable the failure and prove the same check succeeds;
      repeat with another period to prove a failed future-chain link is not
      poisoned.
- [ ] Add a write-then-throw fake. Assert the persisted guard/payment exists,
      cubit state reconciles persisted coins/crowns exactly once, and retry is a
      no-op with no duplicate payment.
- [ ] Run `flutter test test/application/engagement_test.dart` and require the
      old code to fail the concurrent-save, swallowed-save-error, retry-chain,
      and post-write reconciliation assertions for the expected reasons.
- [ ] Do not modify production in this task. Inspect the read-only scoped diff;
      the reviewer commits after the eventual green gate.

#### Phase 2C: Make date-only period arithmetic explicitly UTC

**Files:**

- Modify: `lib/domain/models/streak.dart`
- Modify: `lib/application/engagement_cubit.dart`
- Test: `test/application/engagement_test.dart`
- Test: `test/application/weekly_prize_test.dart`
- Test: `test/application/monthly_prize_test.dart`

**Interfaces:**

- Preserves `String previousUtcDay(String date)`.
- Preserves private weekly/monthly helper outputs and all period definitions.

- [ ] In `previousUtcDay`, split `YYYY-MM-DD`, parse the three components, and
      pass `day - 1` to `DateTime.utc`; touch no other streak code.
- [ ] In weekly/monthly statics, remove local `DateTime.parse` construction.
      Parse date components and use `DateTime.utc` for Monday, Sunday, previous
      week, and previous month calculations.
- [ ] Run the three focused boundary suites and require pass:
      `flutter test test/application/engagement_test.dart test/application/weekly_prize_test.dart test/application/monthly_prize_test.dart`.
- [ ] Inspect the read-only scoped diff; do not stage or commit.

#### Phase 2D: Add shared prize helpers and total payout functions

**Files:**

- Modify: `lib/application/engagement_cubit.dart`
- Test: all five prize/engagement test files from Task 2.

**Interfaces:**

- Produces `_serializedPrizeCommit(Future<void> Function() body)`.
- Produces `_myRankByTier(List<Difficulty> tiers, Future<List<LeaderboardEntry>> Function(Difficulty) fetch)` returning `Future<Map<Difficulty, int>?>`.
- Produces `_bestQualifyingRank(Map<Difficulty, int> ranks, int Function(int) coinsForRank)` returning `int?`.
- Produces total `_dailyCoinsFor`, `_weeklyCoinsFor`, `_monthlyCoinsFor`, and
  `_challengeCoinsFor` functions; challenge returns zero for `rank < 1`.

- [ ] Add a future-chain field initialized to a completed future. Implement
      `_serializedPrizeCommit` so every link catches, reports through `_onError`,
      reloads persisted state after an error, emits only when persisted
      coins/crowns differ, and always completes normally so later links run.
- [ ] Implement `_myRankByTier` as the single sequential per-tier fetch loop.
      Return raw player ranks; on any exception call `_onError` and return null.
- [ ] Implement `_bestQualifyingRank` by selecting the lowest map value whose
      payout function returns a positive value.
- [ ] Wrap the existing payout tables as total functions and add the explicit
      challenge `rank < 1` zero guard without changing positive-rank amounts.
- [ ] Keep production changes minimal and private; add no config record, schema,
      dependency, or public API.

#### Phase 2E: Rewrite the four public checks through the shared helpers

**Files:**

- Modify: `lib/application/engagement_cubit.dart`
- Test: `test/application/daily_prize_test.dart`
- Test: `test/application/weekly_prize_test.dart`
- Test: `test/application/monthly_prize_test.dart`
- Test: `test/application/challenge_payout_test.dart`
- Test: `test/application/engagement_test.dart`

**Interfaces:**

- Preserves all four public names and callback signatures byte-for-byte.
- Consumes every private interface produced by Task 5.

- [ ] Rewrite daily: compute yesterday, precheck `lastDailyPrizeDate >= date`,
      fetch all non-challenge ranks, then serialize reload/recheck/payout/stamp,
      one save, and changed-wallet emission.
- [ ] Rewrite weekly: compute the prior closed Monday-Sunday range, precheck
      `lastWeeklyPrizeDate >= weekFrom`, abort on any tier fetch error, then
      serialize reload/recheck, best-rank coins, one crown per qualifying tier,
      one save, and changed coins/crowns emission.
- [ ] Rewrite monthly: compute previous month/range, precheck
      `lastMonthlyPrizeMonth >= monthKey`, fetch non-challenge ranks, then
      serialize reload/recheck/payout/stamp, one save, and changed-wallet emit.
- [ ] Rewrite challenge: compute yesterday, precheck
      `lastChallengeCheckDate >= date`, fetch only challenge, then serialize
      reload/recheck/payout/stamp, one save, and changed-wallet emit.
- [ ] Run the five focused test files together and require all green.
- [ ] Run `dart format` only on the seven approved Dart test/production paths,
      rerun the focused tests, and inspect the read-only scoped diff. Do not
      stage or commit.

### Task 3: Self-review and full proof

**Files:**

- Review all files changed by Tasks 1–6.

- [ ] Re-read root `PLAN.md` line by line and verify every requirement has a
      corresponding implementation and assertion; remove any scope creep.
- [ ] Confirm forbidden paths and all public signatures are untouched.
- [ ] Run `flutter analyze` and require `No issues found!` with exit code 0.
- [ ] Run `flutter test` and require exit code 0 with the full suite passing.
- [ ] Run `git diff --check`, inspect `git diff --stat`, and inspect
      `git status -sb` using read-only commands only.
- [ ] Report exact output tails, changed files, new tests and their pinned
      behavior, and any closest-faithful deviations. The reviewer owns commits.

## Out of scope

- Any Git mutation.
- Storage/profile schema or infrastructure changes.
- `main.dart`, Supabase, replay engine, constants, season, or pubspec changes.
- Payout amount or period-definition changes.
- Streak transition changes beyond `previousUtcDay` UTC construction.
- Cross-cubit atomicity.
