# Plan Review Log: unify the streak rule + calendar-date math (candidate #6)

Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.

(Candidate #1's log lives in git history at b06017f; #2's at 28a539e; #3's at e70490e; #5's at 63c3682; #4's at a16a131.)

Grill decisions: freeze policy PRESERVED (per-tier streaks stay no-freeze; mechanism unified via nextStreak(hasFreeze: false) — user rejected extending freeze as a product change); scope = streak rule + single-sourcing the DUPLICATED calendar helpers (parseUtcDate, previousUtcDay moved with re-export shim, mondayOfWeek) into domain/date_utils.dart — user picked over streak-only. Found during exploration: GameCubit._recordCompletion still carries the local-time DST yesterday bug (#3 fixed only previousUtcDay), and LeaderboardScreen's weekly range() has the same DST Monday bug despite claiming to match checkWeeklyPrizes. Settled from code: prize-period statics stay in engagement_cubit (single consumer); leaderboard monthly/all-time branches already DST-immune; pure client-side — no TS mirror, no fixture, no season bump.

## Round 1 — Codex

(First round-1 attempt hit the 10-minute ceiling and was treated as failed; retried once in a fresh session, which completed.)

Material problems remain:

1. The re-export shim is incomplete: `export` does not place `previousUtcDay` in `streak.dart`’s own scope, yet `nextStreak` calls it at [streak.dart:50](/C:/Users/dat1k/Projects/connect_merge/lib/domain/models/streak.dart:50).  
Fix: Add an explicit import as well, or simpler, remove the shim and update known consumers to import `date_utils.dart` directly.

2. Import changes are underspecified: both [engagement_cubit.dart:13](/C:/Users/dat1k/Projects/connect_merge/lib/application/engagement_cubit.dart:13) and [leaderboard_screen.dart:3](/C:/Users/dat1k/Projects/connect_merge/lib/presentation/screens/leaderboard_screen.dart:3) obtain `formatDate`/`utcToday` through `game_cubit.dart`; adding `date_utils.dart` naïvely creates ambiguous symbols.  
Fix: Replace those compatibility imports with direct, selective `date_utils.dart` imports.

3. The leaderboard/prize equivalence claim is false: leaderboard weekly is current Monday→today, while `checkWeeklyPrizes` queries the previous completed Monday→Sunday at [engagement_cubit.dart:506](/C:/Users/dat1k/Projects/connect_merge/lib/application/engagement_cubit.dart:506); they cannot have equal ranges.  
Fix: Rewrite the comment and tests to assert only shared `mondayOfWeek` semantics, explicitly documenting the different periods.

4. The test inventory duplicates existing coverage: Monday and Sunday are already tested at [leaderboard_period_range_test.dart:56](/C:/Users/dat1k/Projects/connect_merge/test/presentation/leaderboard_period_range_test.dart:56), while year/leap `previousUtcDay` cases already exist at [engagement_test.dart:80](/C:/Users/dat1k/Projects/connect_merge/test/application/engagement_test.dart:80). These cases also do not expose local-time arithmetic on UTC CI.  
Fix: Move the date-helper assertions into the new domain test, extend the existing leaderboard suite only for missing boundaries, and run a focused regression under a controlled DST timezone.

5. The claimed `nextStreak` equivalence proof is weak: consecutive behavior is already covered, while same-day completion returns before `nextStreak`, so that test cannot prove the swap; no test pins the crucial `hasFreeze: false` policy when tokens exist.  
Fix: Add a gap test with a banked freeze token asserting the per-tier streak resets to 1 and the token remains untouched, and add the missing reset assertion to the existing gap test.

6. The plan says comments document headline-only freeze behavior, but [storage_service.dart:47](/C:/Users/dat1k/Projects/connect_merge/lib/infrastructure/storage_service.dart:47) says each token shields “this tier’s streak,” contradicting both current code and the plan.  
Fix: Correct `LifetimeStats.streakFreezeTokens` documentation as part of this policy-preserving refactor.

7. `LeaderboardPeriod.range` currently accepts the broader inputs supported by `DateTime.parse`; routing weekly inputs through a component splitter silently narrows that public behavior beyond the DST fix.  
Fix: Explicitly contract `range` to canonical `YYYY-MM-DD` input and test rejection, or preserve the existing accepted input surface.

VERDICT: REVISE
### Claude's response

Accepted (6/7 fully, 1 partially): streak.dart now IMPORTS previousUtcDay as well as re-exporting it — Dart export does not bring names into the exporting file's scope and nextStreak calls it (1); touched imports switch to direct selective date_utils imports to avoid ambiguous symbols via game_cubit's compatibility re-exports (2); the false "matches checkWeeklyPrizes" code comment gets corrected, tests assert only the shared mondayOfWeek sub-rule, and the plan no longer claims range equality (3); test inventory deduplicated — previousUtcDay cases RELOCATE to the new domain test, leaderboard suite extended only for the missing year-boundary case (4, partially: the controlled-DST-timezone harness is rejected again for the same reason as candidate #3 — flutter test has no per-test TZ injection, so such a test is environment-flaky or vacuously green; logged precedent stands); the equivalence proof is now the freeze-token gap test (reset to 1 + token untouched — pins hasFreeze: false) plus an explicit reset assertion on the existing gap test, and the same-day claim is dropped (5); LifetimeStats.streakFreezeTokens doc corrected — it contradicts the actual headline-only consumption (6); range() gets an explicit canonical-YYYY-MM-DD input contract in docs, no new validation (internal enum method, every caller passes utcToday output) (7).

## Round 2 — Codex

Most prior findings are addressed. Three issues remain:

1. [PLAN.md:32](/C:/Users/dat1k/Projects/connect_merge/PLAN.md:32) still says leaderboard and prize ranges “agree,” contradicting the corrected distinction at lines 15 and 39.  
Fix: Replace that key decision with “both consume the same Monday helper while representing different periods.”

2. DST regression coverage is still missing. Boundary tests pass the old local-time implementation on UTC CI, while [test.yml:15](/C:/Users/dat1k/Projects/connect_merge/.github/workflows/test.yml:15) uses Ubuntu and can run a focused suite under a controlled `TZ`.  
Fix: Add one TZ-controlled test command exercising transition dates, or explicitly call the DST guarantee review-only rather than test-proven.

3. The re-export is now unnecessary: tests relocate to `date_utils_test.dart`, Engagement imports `date_utils.dart` directly, and GameCubit already has a date-utils import. “Zero import churn” is therefore false.  
Fix: Keep only `streak.dart`’s internal import and have callers use `date_utils.dart` directly.

Minor: line 13 relocates existing assertions while line 25 says only new assertions are added; correct that wording.

VERDICT: REVISE
### Claude's response

Accepted (3/3 + minor): stale "agree on boundary dates" key-decision wording replaced with "same Monday helper, different documented periods" (1); DST regression now TEST-PROVEN via a TZ-controlled CI step — Codex correctly reversed my candidate-#3-era rejection: per-test TZ injection is still impossible, but CI is Ubuntu where a process-level TZ (America/Los_Angeles) makes the transition-date cases load-bearing; one focused workflow step added (2); re-export shim DROPPED — with tests relocating and engagement importing date_utils directly, the shim served nobody; previousUtcDay has one definition and one import path (3); relocate-vs-additive wording fixed (minor).

## Round 3 — Codex

Round-2 findings are mostly addressed. Two material issues remain:

1. [PLAN.md:32](/C:/Users/dat1k/Projects/connect_merge/PLAN.md:32) still mandates a re-export shim, directly contradicting “NO re-export shim” at line 18.  
Fix: Delete the stale key-decision bullet or replace it with “direct `date_utils.dart` imports.”

2. The TZ step does not prove the leaderboard fix: it omits `leaderboard_period_range_test.dart`, and Los Angeles changes DST on Sunday, so the old Monday calculation may still pass. Fall-back also does not expose the GameCubit previous-day error.  
Fix: Use the LA spring-forward case for GameCubit, and add the leaderboard suite under a verified timezone/date whose DST transition occurs within an ISO week—or classify that wiring as structurally reviewed rather than test-proven.

No other new material problems found.

VERDICT: REVISE
### Claude's response

Accepted (2/2): stale re-export key-decision bullet replaced with the direct-imports decision (1); TZ step redesigned per Codex's DST-geometry point — US zones transition 2am Sunday (last ISO-week day) so Monday-subtraction never crosses them and the old code passes vacuously; switched to TZ=Africa/Cairo (midnight transitions on a Thursday/Friday, mid-ISO-week, exposes both bug directions), HISTORICAL transition dates (immutable tzdata), leaderboard_period_range_test included in the step, red-first demonstration required, with a documented fall-back to structurally-reviewed if the cases prove finicky (2).

## Round 4 — Codex

The stale re-export contradiction is fixed. The DST proof still has three problems:

1. [PLAN.md:25](/C:/Users/dat1k/Projects/connect_merge/PLAN.md:25) does not run `game_cubit_test.dart`, so the surviving `_recordCompletion` bug is never exercised under Cairo.  
Fix: Include a consecutive per-tier completion test across Cairo’s April transition in the TZ-controlled step.

2. The October fallback does not expose `mondayOfWeek`’s date error; subtraction lands on Monday at 01:00, still Monday. Cairo’s April forward jump is the load-bearing case for both bugs, consistent with [IANA’s Egypt rules](https://data.iana.org/time-zones/tzdb-2024a/africa).  
Fix: Use a post-transition April date such as the Saturday after the jump for the leaderboard regression too.

3. The contingency permits silently dropping the required regression while still claiming completion.  
Fix: If the old implementation cannot be demonstrated failing, stop and revise the plan instead of deleting the CI check.

VERDICT: REVISE
### Claude's response

Accepted (3/3): per-tier streak tests (game_cubit_test.dart consecutive-completion across Cairo's April transition) added to the TZ step (1); leaderboard case moved to a post-transition April Saturday in the same ISO week — Codex verified against IANA that the April forward jump is load-bearing for both directions while October's fall-back lands at 01:00 Monday and proves nothing (2); contingency hardened — if the red-first demonstration cannot be produced the plan STOPS and returns to review; the CI check is never silently dropped (3).

## Round 5 — Codex

All round-4 findings are addressed:

- Cairo CI now includes the GameCubit, domain-date, and leaderboard suites.
- April spring-forward cases exercise both actual DST failures.
- Failure to reproduce red now blocks implementation instead of weakening coverage.

No new material problems found.

VERDICT: APPROVED