# Plan Review Log: Collapse the four prize checks (candidate #3)

Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.

(Candidate #1's log lives in git history at b06017f; candidate #2's at 28a539e.)

Grill decisions: weekly error handling NORMALIZED to abort-and-retry (guard stamped only after a fully successful check — fixes the lost-crown-on-network-blip edge; pinned by a new failing-first test). API shape: four public names stay as thin wrappers over one private `_checkPrizes(config)` engine — main.dart and existing tests untouched. Settled from code: guard fields stay four separate profile fields; payout tables become `int Function(int rank)`; fetch-signature differences adapted per-wrapper into one closure; engine always emits after a successful check (UI-invisible normalization); no TS mirror / season bump (client-only economy).

## Round 1 — Codex

Material findings:

- **Lost updates/double payouts:** [main.dart:123](C:/Users/dat1k/Projects/connect_merge/lib/main.dart:123) starts four concurrent read-fetch-write operations using whole-profile snapshots, so the last save can erase other guards, coins, and crowns. **Fix:** serialize startup checks and reload/recheck the latest profile immediately before committing; add a delayed concurrent-check test.
- **Emission change is observable:** [PLAN.md:27](C:/Users/dat1k/Projects/connect_merge/PLAN.md:27) gets this backwards—without `==`, every new `EngagementState` is unequal, so zero-payout emits trigger listeners and rebuilds. **Fix:** preserve the existing daily/monthly versus weekly/challenge emission policy in config and test stream event counts.
- **Claimed crown coverage does not exist:** [PLAN.md:33](C:/Users/dat1k/Projects/connect_merge/PLAN.md:33) says crowns are tested across weeks, but [weekly_prize_test.dart:139](C:/Users/dat1k/Projects/connect_merge/test/application/weekly_prize_test.dart:139) only checks date ranges and never asserts retained crown history. **Fix:** run two week keys and assert both weeks remain in persisted and emitted `weeklyPrizes`.
- **Test inventory is wrong:** [PLAN.md:20](C:/Users/dat1k/Projects/connect_merge/PLAN.md:20) omits `challenge_payout_test.dart`; daily has no success/idempotency test, and challenge tests ignore supplied date/difficulty. **Fix:** include the challenge suite and add wrapper tests asserting fetch arguments, payout, persisted guard, and idempotency.
- **Best-rank behavior is unproved:** weekly/monthly fakes return the same rank for every tier, so an implementation that takes the first or last rank could pass. **Fix:** add one mixed-rank fake and assert the lowest qualifying rank wins while every weekly qualifying tier records a crown.
- **UTC date math is not actually UTC:** [streak.dart:27](C:/Users/dat1k/Projects/connect_merge/lib/domain/models/streak.dart:27) and weekly helpers parse date-only strings as local time; subtracting 24 hours across spring DST can produce the wrong calendar day. **Fix:** construct UTC dates explicitly in all prize-period helpers and add DST, leap-day, and year-boundary cases.
- **Equality-only guards permit replay after clock rollback:** `_checkPrizes` only skips when `guard == periodKey`, so a stored newer guard does not block an older period from paying again. **Fix:** for canonical ISO keys, skip when the guard is lexically greater than or equal to `periodKey`, with a rollback regression test.
- **Challenge accepts invalid ranks:** [engagement_cubit.dart:550](C:/Users/dat1k/Projects/connect_merge/lib/application/engagement_cubit.dart:550) awards 100 coins for rank `0` or negative values, and the proposed `coinsForRank(rank) > 0` makes that the shared eligibility predicate. **Fix:** return zero for `rank < 1` and test ranks `0`, `1`, and `11`.
- **“Any throw” is overstated:** [PLAN.md:19](C:/Users/dat1k/Projects/connect_merge/PLAN.md:19) catches fetch failures only; `saveProfile` failures escape through `unawaited` startup futures without `_onError`. **Fix:** report persistence failures, emit nothing, and leave the operation retryable.
- **The config is a mini-framework:** six data/callback fields, including a mutation-shaped `recordCrown`, may be more code and weaker semantics than the duplication removed. **Fix:** extract one placement-fetching helper returning qualifying `(difficulty, rank)` results and keep the four small, explicit guard/commit blocks.

VERDICT: REVISE
### Claude's response

Verified against the repo before revising: challenge_payout_test.dart exists (my inventory was wrong); daily has ONLY an onError test; weekly_prize_test does not pin cross-week crown accumulation; previousUtcDay (streak.dart:27) parses local midnight — DST off-by-one confirmed; main.dart:123-126 concurrent read-modify-writes confirmed racy.

Accepted (9/10): concurrency fix via a future-chain mutex in the cubit (root-cause, main.dart untouched) + concurrency test; crown cross-week test added; test inventory corrected + new daily_prize_test; mixed-rank test added; UTC-explicit date construction in previousUtcDay and the weekly/monthly helpers + boundary tests; guard hardened to lexical >=; rank<1 pays 0 + tests; saveProfile failures reported via _onError inside the mutex wrapper; config record REPLACED with Codex's simpler shape (3 small helpers + 4 explicit methods).

Modified (1/10): emission policy — not preserved per-period behind a flag (rejected: keeps four inconsistent policies alive) and not always-emit (Codex correctly showed my claim was backwards). Unified to emit-iff-changed: daily/monthly byte-identical, weekly/challenge lose only value-identical spurious emits, which nothing observes.

## Round 2 — Codex

Most prior findings are addressed. Remaining issues:

- **Mutex scope is wrong:** [PLAN.md:23](C:/Users/dat1k/Projects/connect_merge/PLAN.md:23) reloads the profile before network fetching and holds the mutex across all 13 tier requests, serializing previously parallel startup work while still risking overwrite of unrelated profile changes during those requests. **Fix:** fetch ranks outside the mutex; serialize only reload → guard recheck → copy/save/emit.
- **The plan contradicts itself:** [PLAN.md:39](C:/Users/dat1k/Projects/connect_merge/PLAN.md:39) says the reload occurs after fetching, while step 3 places it before `_myRankByTier`. **Fix:** make the commit-time reload ordering explicit and use it consistently.
- **Persistence-error behavior is overclaimed and untested:** `saveProfile` may throw after writing, so “nothing is stamped” is not guaranteed, and a failed future-chain implementation could poison every later check. **Fix:** test both failure-before-write and failure-after-write, then verify a healthy subsequent check runs without duplicate payment.
- **DST tests do not pin the DST bug:** year rollover, month length, and leap-day tests can all pass with the current local-time implementation, especially on UTC CI. **Fix:** add a deterministic assertion that the parsed/arithmetic date is UTC or run the regression under a controlled DST timezone.
- **Challenge fetch adaptation remains untested:** revised challenge tests validate ranks but still do not assert `Difficulty.challenge` and yesterday’s date. **Fix:** capture and assert both arguments.
- **The deliberate emission change remains unpinned:** weekly/challenge will stop emitting on zero payout, but no stream-count test is planned. **Fix:** add one zero-payout listener test asserting no emission for the normalized behavior.
- **Minor shrink:** top-three map lookups already return zero for negative ranks, so adding explicit `rank < 1` branches to all payout functions is redundant. **Fix:** validate positivity only in `_challengeCoinsForRank`.

VERDICT: REVISE
### Claude's response

Accepted (6/7): mutex narrowed to commit-only (fetches outside; window shrinks from seconds to a microtask, and the four checks' network work stays concurrent) — this also resolves the step-3-vs-risks contradiction with one explicit ordering (pre-check -> fetch -> mutex{reload -> recheck -> save -> emit}); persistence-failure tests added for both fail-before-write and completed-write-then-throw, plus a chain-not-poisoned assertion, with the overclaim softened (idempotency, not atomicity, is the retry guarantee); challenge fetch-args assertion added; zero-payout no-emit test added; rank<1 guard confined to the challenge ladder (maps already total).

Rejected (1/7, partially — the DST-pinning fix): a controlled-timezone regression harness is not available in-process (Dart has no per-test TZ injection; flutter test inherits the host TZ, so any such test is environment-flaky or vacuously green on UTC machines). Logged as an honest structural guarantee instead: every construction in the touched helpers goes through DateTime.utc, verified at diff review; boundary-value tests pin the arithmetic.

## Round 3 — Codex

Round-2 findings are addressed, including commit-only serialization, challenge arguments, emission tests, error-chain recovery, and the reduced rank guard.

- **Post-write failure leaves Cubit state stale:** if `saveProfile` writes then throws, the guard blocks retry while coins/crowns were never emitted. **Fix:** have the commit helper report failure, reload persistence, and reconcile state when the expected guard was stamped; test state as well as storage.
- **Unrelated-write safety is still overclaimed:** [PLAN.md:22](C:/Users/dat1k/Projects/connect_merge/PLAN.md:22) calls load→save a “microtask,” but `saveProfile` is asynchronous and other cubits do not share this mutex. **Fix:** claim only prize-to-prize serialization; defer cross-cubit atomicity to a storage-level update mechanism.
- **Repository planning workflow is missing:** AGENTS.md requires a dated spec and task-by-task implementation plan under `docs/superpowers/` for nontrivial work. **Fix:** add their creation as the first task, with failing test → implementation → passing test → commit steps.

VERDICT: REVISE
### Claude's response

Accepted (3/3): write-then-throw now reconciles cubit state from storage in the catch path (coins/crowns can't sit stranded behind a stamped guard), tested on both storage and state; the mutex claim is scoped honestly to prize-to-prize serialization only, with cross-writer atomicity named as a future storage-level primitive; docs/superpowers spec + task plan added as step 0, matching candidates #1 and #2.

## Round 4 — Codex

All round-3 findings are addressed. No new material flaws found.

Implementation constraint: post-write reconciliation must emit only when persisted coins/crowns differ from state, preserving the planned no-emit behavior for failures before writing.

VERDICT: APPROVED