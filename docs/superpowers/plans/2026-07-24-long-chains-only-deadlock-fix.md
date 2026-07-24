# Long Chains Only — Deadlock Fix — Implementation Plan

Date: 2026-07-24
Design doc: `docs/superpowers/specs/2026-07-24-long-chains-only-deadlock-fix-design.md`
Grill + adversarial-review trail: `PLAN.md` / `PLAN-REVIEW-LOG.md` at the time
of this change (grill-me-codex skill artifacts, since overwritten by later
uses of that skill — see git history for this commit's versions).

Each task below was implemented with a failing-then-passing test; this
document records what shipped, for future sessions checking prior plans
before touching the same invariant set (per `CLAUDE.md`).

## Task 1 — Single-source `ChallengeRule.minChainLength`

- Add `ChallengeRuleMinChainLength` extension:
  `lib/domain/models/challenge_rule.dart` (default 2, `longChainsOnly` → 3).
- Add `minChainLengthFor(rule)`: `supabase/functions/_shared/constants.ts`.
- Correction from review round 1: default must be **2**, not 1 — a
  length-1 "chain" is a single tile, never a legal move; defaulting to 1
  would make every rule-aware search vacuously false for any board with a
  tile at all.

## Task 2 — Rule-aware chain-existence search

- Dart: `GameEngine.hasChainOfLength(board, minLength)` +
  private `_searchChain` DFS — `lib/domain/engine/game_engine.dart`.
- TS: `hasChainOfLength(cells, gridSize, minLength)` +
  `hasAnyMergeablePair`/`searchChain` helpers — `supabase/functions/_shared/constants.ts`
  (deliberately **not** `engine.ts`; see design doc for the import-cycle
  reasoning, confirmed via `grep '^import'` on both files before writing).
- `minLength <= 2` delegates to the pre-existing `hasMergeAvailable` /
  `hasAnyMergeablePair` path — byte-identical behavior for every rule/
  difficulty besides `longChainsOnly`.
- Tests: `test/domain/engine/game_engine_test.dart` (`hasChainOfLength`
  group — byte-identical-at-2, straight/L-shape 3-chains, tier-cap rejection,
  non-adjacent-path rejection) and mirrored `Deno.test`s in
  `supabase/functions/_shared/engine.test.ts`.

## Task 3 — Thread `minChainLength` through refill, evaluateStatus, seeder re-roll

- `GameEngine.refill` / TS `refillBoard`: internal guarantee condition swaps
  from `!hasMergeAvailable` to `!hasChainOfLength(..., minChainLength)`.
  This — not the deadlock check alone — is what gives players more chances,
  since it's what decides how much material the board gets per move.
- `GameEngine.evaluateStatus` / TS `evaluateStatus`: same swap; `deadlocked`
  only fires once no chain of the required length remains.
- `DailySeeder.generate` / TS `DailySeeder.generate`: re-roll loop condition
  swaps from `hasMergeAvailable` to `hasChainOfLength(..., minChainLength)`,
  new `minChainLength` parameter (default 2) alongside the existing
  `startingFillOverride`/`wallCountOverride`/`movesOverride`.
- Tests: `refill (rule-aware minChainLength)` group in
  `game_engine_test.dart` (keeps dropping past a 2-chain-satisfied state;
  stops at a full board rather than looping forever) + TS mirrors; new
  `evaluateStatus` test; new seeder sweep test (`daily_seeder_test.dart` and
  `engine.test.ts`) asserting no born-short board across 28 sample dates
  under `minChainLength: 3` + `kChallengeDenseFill`.

## Task 4 — Wire `GameCubit`: reject-guard, seeder call, refill/evaluateStatus calls, dense fill

- `lib/application/game_cubit.dart`:
  - `playChain`'s reject-guard reads `_activeRule?.minChainLength ?? 2`
    instead of the bare `ChallengeRule.longChainsOnly && path.length < 3`
    literal.
  - `init`'s `_seeder.generate(...)` call passes `minChainLength: rule.minChainLength`.
  - `init`'s per-rule fill switch adds a `longChainsOnly => kChallengeDenseFill`
    branch (reusing the existing constant).
  - `playChain`'s `GameEngine.refill`/`GameEngine.evaluateStatus` calls both
    pass `minChainLength: _activeRule?.minChainLength ?? 2`.
- `verifyRunChallenge` (`engine.ts`): mirrors all four — `minChainLength`
  computed once via `minChainLengthFor(rule)`, threaded into the seeder
  `generate` call, the reject-guard, `refillBoard`, and `evaluateStatus`; the
  `longChainsOnly` fill override branch added alongside `denseStart`/
  `sparseStart`.
- Test: existing `longChainsOnly rule rejects 2-tile chains` in
  `game_cubit_challenge_test.dart` continues to pass unchanged (confirms the
  refactor from a hardcoded literal to `rule.minChainLength` preserves
  behavior).

## Task 5 — Fix the adjacent Challenge ad-continue bug

Found during review (round 1): `canOfferAd` ignored difficulty, so it could
offer a continue for any Challenge run out of moves with a bare 2-chain
remaining — but `verifyRunChallenge` rejects every `ContinueEvent` for
Challenge unconditionally, so this silently doomed submission. Round 2 caught
that fixing only this (making `canOfferAd` hard-false) without also fixing
`_finishRun`'s terminal check would strand a Challenge run that ends
out-of-moves with a legal chain still present — none of the three original
OR-clauses would fire.

- `GameCubit.canOfferAd`: added `s.difficulty != Difficulty.challenge` gate.
- `GameCubit._finishRun`: `terminal` is now `_difficulty == Difficulty.challenge
  || <original three clauses, rule-aware>`.
- Tests (new, `game_cubit_challenge_test.dart`):
  - `canOfferAd is false for Challenge even when out of moves with a legal
    chain remaining` — forces an out-of-moves snapshot with a confirmed
    mergeable pair, resumes, asserts `canOfferAd` is false.
  - `a Challenge run out of moves submits immediately even with a legal chain
    left` — forces `movesRemaining: 1`, plays the last legal move via
    `onSubmitRun` hook, asserts submission fires on the same tick the run
    ends (not deferred).

## Task 6 — Season + snapshot version bumps

- `kLeaderboardSeason`: 1 → 2 in both `lib/domain/constants.dart` and
  `supabase/functions/_shared/constants.ts`.
- `kSnapshotVersion`: 3 → 4 in `lib/domain/constants.dart` (see design doc for
  the corrected reasoning — a `_targetFill`/persisted-board consistency issue,
  not a server-replay issue).
- Golden vectors regenerated: `UPDATE_GOLDENS=1 flutter test
  test/domain/engine/golden_vectors_test.dart` (no `_FORCE` needed — the
  season bump already changed `committed['season'] != kLeaderboardSeason`, so
  the diff-guard didn't trip). Diff reviewed: only the `season` field and the
  two `longChainsOnly`-related vectors (`challenge-longChainsOnly`,
  `reject-longChainsOnly-two-chain`) changed — every other vector
  byte-identical. The `challenge-longChainsOnly` vector's run now plays many
  more real 3-chains before reaching a genuine `deadlocked` status (previously
  it stopped early at `playing` — the soft-lock itself, captured in the old
  fixture).

## Task 7 — Multi-date full-board-deadlock sweep

Added per review round 2 finding #4 ("the full-board risk has no planned
measurement"). New file: `test/domain/engine/long_chains_only_sweep_test.dart`
— a naive greedy bot (always takes the first legal 3-chain found) plays out
`longChainsOnly`-style boards across a full year of dates (336 samples) and
asserts:
1. `deadlockedWithRoom == 0` always — a structural guarantee of `refill`
   (it only stops dropping once the board is full or a legal chain exists),
   verified empirically rather than assumed.
2. `outOfMoves > deadlockedFull` — most runs reach the full move budget
   rather than deadlocking early, confirming the fix's actual effect (not
   just its correctness). Empirical result at time of writing: 246
   out-of-moves vs. 90 full-board-deadlocks across the 336 sampled dates.

## Documented, not implemented (rejected during review, with reasoning)

See the design doc's "Versioning" and "Out of scope" sections, and
`PLAN-REVIEW-LOG.md` for the full argument: a new ruleset/ContentVersion
system for replay verification, reworking `goldenDropIndices()`'s precompute
bound, and structured rejection telemetry for `submit-score` were all raised
during review and rejected as disproportionate scope for this fix (or, for
telemetry, a genuinely separate follow-up).

## Verification

- `flutter test` — 683 passed, 0 failed.
- `flutter analyze` — no issues.
- `deno test --frozen supabase/functions/` — 55 passed, 0 failed.
