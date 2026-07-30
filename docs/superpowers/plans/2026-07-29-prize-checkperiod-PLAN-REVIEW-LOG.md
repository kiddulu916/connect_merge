# Plan Review Log: Extract `_checkPeriod`
Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.
PLAN_FILE=docs/superpowers/plans/2026-07-29-prize-checkperiod-PLAN.md
Reviewer model: gpt-5.6-sol (`-m`/`-c` override; config's gpt-5.3-codex 400s on ChatGPT-account auth) — codex-cli 0.144.4.

Thread 019faf3e-5c50-7bd2-8e18-9e9099e6f22d.

## Round 1 — Codex
- **High — emit unification changes behavior.** Plan always supplies `weeklyPrizes`, while current daily/monthly/challenge update only coins. Persisted profile and Cubit state aren't guaranteed synchronized; can cause an extra emit, silently resync stale crowns, or replace an equal list with a new Hive-deserialized instance. Fix: add `syncWeeklyPrizes` (true only for weekly), retain coins-only emit for the other three.
- **Medium — weekly/monthly catch a broader exception set.** Proposed closures wrap `_nonChallengeRanks(...)` inside `try`, whereas current code catches only `fetchRanks` and filters afterward; filtering failures would change from propagated to reported-and-swallowed breaks. Fix: assign the fetched map inside try/catch, call `_nonChallengeRanks` after the catch.
- **Medium — claimed absent-date coverage does not exist.** Existing daily/challenge tests provide a date with a non-qualifying rank; none returns an outer map with the date entirely absent, despite the plan claiming those tests pin it. Fix: add daily+challenge tests where `fetchRanks` returns `{}`, assert zero-coin guard stamp + advancement.

Confirmed sound: non-null empty-map path, batch-vs-per-period fetch placement, all guard comparisons (null/==/>/post-commit <). The five-parameter module earns its keep (deleting it recreates the serialized guard/award/save/advance transaction four times).

VERDICT: REVISE

### Claude's response — all 3 accepted
- **#1 (High) ACCEPTED** — added `required bool syncWeeklyPrizes`; `_checkPeriod` now branches the emit so weekly keeps `copyWith(coins, weeklyPrizes)` under the coins-or-crowns check and the other three keep the exact coins-only emit. Reverted the (unsafe) emit unification.
- **#2 (Medium) ACCEPTED** — weekly/monthly `ranksFor` now assign the fetched map inside `try/catch` and call `_nonChallengeRanks` AFTER the catch, so a filter-time throw propagates as today.
- **#3 (Medium) ACCEPTED** — added Approach step 8: absent-date tests in daily_prize_test/challenge_payout_test (`fetchRanks` returns `{}` → assert zero-coin guard stamp + advance), written against the pre-refactor code first so they pin existing behavior.

## Round 2 — Codex
All three findings addressed correctly. Emit behavior, exception boundaries, absent-date stamping, fetch-failure semantics, and guard comparisons now match current behavior. The six-parameter private module still earns its keep by centralizing the serialized commit skeleton. No new material problem found.

VERDICT: APPROVED

### Resolution
Converged after 2 rounds (Act 1 grill + Act 2 cross-model review). Plan locked and approved. No code written during either act.

## Act 3 — Build (Codex builds, Claude verifies)
Builder model: gpt-5.6-sol (`-c model` override). Thread 019faf47-7598-7852-99bf-c8d8a9019e5d. Codex self-committed as cf77feb (contract deviation; Claude finalizes at the gate).

### Claude's verdict — VERIFIED
- Read the full diff (prize_checking_mixin.dart +177/-117, 2 test files). Faithful to spec: `_checkPeriod` with the `syncWeeklyPrizes` emit branch (weekly => coins-or-crowns + copyWith(coins, weeklyPrizes); others => coins-only), the three helpers lifted verbatim, weekly/monthly `ranksFor` with `try` wrapping ONLY `fetchRanks` and `_nonChallengeRanks` after the catch, daily/challenge `ranksFor` never-null. All four public signatures unchanged (main.dart callers untouched).
- Ran proof myself: `flutter analyze` on the 3 touched files → No issues; the 5 proof suites → 54/54 pass.
- **Behavior-preservation proven:** reverted the mixin to pre-refactor and ran the two new absent-date tests against the OLD code → pass (12/12 daily+challenge). The new tests pin existing behavior on both old and new code.
- Broad regression: `test/application/ test/infrastructure/` → 396/396 pass (all callers of the change). Full `flutter test` locally exceeds 10 min purely due to the unrelated board_vectors GameCubit-drive (candidate #1's flagged perf ceiling); CI runs it in ~2 min.
