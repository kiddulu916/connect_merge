# Remove Legacy Single-Pair Merge Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:test-driven-development` while implementing this plan task by
> task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the unreachable client pair-merge producer and its two orphaned
engine APIs while preserving every live invariant and the permanent legacy-log
rejection proof.

**Architecture:** `playChain`/`collapseChain` remain the only live move path.
Legacy `MergeEvent` parsing and `GameEngine.canMerge` remain format/sentinel
support only. No accepted replay semantics or seeded fixture changes.

**Tech stack:** Dart/Flutter, flutter_bloc, Flutter test, Deno Edge Functions.

## Global constraints

- Follow frozen root `PLAN.md` exactly; this document records rather than
  redesigns it.
- Do not run Git-mutating commands. The reviewer owns all Git state changes.
- Keep the focused suite green after each atomic migration step.
- Do not add dependencies, bump the season, regenerate golden vectors, or
  modify `supabase/**`, `test/domain/engine/golden_vectors_test.dart`, or
  `supabase/functions/_shared/golden_vectors.json`.
- Keep `MergeEvent`, the `merge` JSON parse case, and `GameEngine.canMerge`.
- Do not change `playChain`, undo mechanics, scoring, seeded generation, or any
  live rule.

---

### Task 1: Add chain replay infrastructure without removing legacy support

**Files:**

- Modify: `test/application/game_cubit_undo_test.dart`

- [ ] Add a `ChainEvent` replay branch beside the temporary `MergeEvent`
  branch: playing guard, `isValidChain`, `collapseChain`, `refill`, then
  `evaluateStatus`.
- [ ] Preserve `ContinueEvent` handling.
- [ ] Add oriented orthogonally-adjacent chain finders that try both directions
  and assert every returned path passes `GameEngine.isValidChain`.
- [ ] Use the new finder in the existing chain undo test while legacy consumers
  still use the temporary pair helpers.
- [ ] Run `flutter test test/application/game_cubit_undo_test.dart` and require
  green before migrating consumers.

### Task 2: Migrate all undo-suite pair references and remove temporary support

**Files:**

- Modify: `test/application/game_cubit_undo_test.dart`

- [ ] Move the full `BoardState.toJson` equality assertion from `undo rewinds
  board, dropIndex, and moveLog together` into `undo after a chain restores
  board, score, and drop streams`, then delete the former test.
- [ ] Migrate `merge → undo → re-merge-differently: final moveLog replays to the
  final board (no PRNG desync)` to oriented chain paths and `ChainEvent`.
- [ ] Migrate `multiple merges then multiple undos all stay replay-consistent`
  to repeated chains.
- [ ] Migrate `golden merge credits N, undo refunds N (wallet net 0), re-merge
  credits once` to play `[0, 1]` as a chain and re-derive the golden credit from
  the consumed path.
- [ ] Migrate `free undo cap: exactly kFreeUndosPerDay free undos, then no-op`,
  `rewarded undo grants exactly one extra past the free cap`, `undo stack is
  bounded at kUndoStackDepth`, and `undo only valid in GamePlaying (not after
  the run is locked)` to oriented chains.
- [ ] Remove the temporary pair finders and delete the replay helper's
  `MergeEvent` branch atomically with its last consumer.
- [ ] Run `flutter test test/application/game_cubit_undo_test.dart` and require
  green.

Deleted-test mapping:

- `undo rewinds board, dropIndex, and moveLog together` → `undo after a chain
  restores board, score, and drop streams`.

### Task 3: Migrate the cubit suite with chain-derived expectations

**Files:**

- Modify: `test/application/game_cubit_test.dart`

- [ ] Replace `_findMergePair` with one oriented, orthogonally-adjacent chain
  finder whose result is asserted with `GameEngine.isValidChain`.
- [ ] Migrate `onAnalyticsEvent fires run_completed exactly once across an ad
  continue, using the SECOND (truly final) board's stats, not the pre-continue
  board's` to `playChain` in both phases.
- [ ] Delete only `a legal merge updates score, spends a move, triggers a drop,
  and logs a MergeEvent`.
- [ ] Migrate `move log records merges then a continue, in order, and survives
  snapshot json` to a mixed ordered `ChainEvent` + `ContinueEvent` log, retaining
  the unconditional ordering and `GameSnapshot.fromJson` assertions.
- [ ] Migrate `merging golden tiles fires onCoinsEarned without changing score`,
  `merging non-golden tiles credits nothing`, `tracks coins earned this run and
  doubles them once`, and `doubleRunCoins is idempotent (no triple credit)`;
  rename pair-specific prose and derive score/bonus expectations from the path.
- [ ] Migrate `_completeTier` to its oriented chain finder so completion,
  per-tier streak, analytics, and error-hook tests retain their coverage.
- [ ] Run `flutter test test/application/game_cubit_test.dart` and require
  green.

Deleted-test mapping:

- `a legal merge updates score, spends a move, triggers a drop, and logs a
  MergeEvent` → `playChain collapses a valid 2-path, scores, and tops the board
  back up`.

### Task 4: Remove engine tests for deleted APIs and retain live invariants

**Files:**

- Modify: `test/domain/engine/game_engine_test.dart`

- [ ] Delete `merge: destination becomes tier+1, source empties, scores
  2^newTier, spends a move`.
- [ ] Delete `goldenBonusFor pays per golden tile consumed`, including its
  zero/one/two-golden assertions.
- [ ] Rewrite `merging golden tiles yields the SAME score as a non-golden
  control` with `GameEngine.collapseChain(..., [0, 1])`, retaining equal score,
  equal move-log, and consumed-golden assertions.
- [ ] Delete `collapse: a 2-path matches the legacy merge result`.
- [ ] Keep all `canMerge` tests and all other chain tests.
- [ ] Run `flutter test test/domain/engine/game_engine_test.dart` and require
  green.

Deleted-test mapping:

- `merge: destination becomes tier+1, source empties, scores 2^newTier, spends
  a move` → `collapse: endpoint climbs +1 keeping its id; others empty; scores
  combo`.
- `collapse: a 2-path matches the legacy merge result` → `collapse: endpoint
  climbs +1 keeping its id; others empty; scores combo` plus `collapse: a flat
  (same-tier) chain has zero ascend bonus`.
- `goldenBonusFor pays per golden tile consumed` → `playing golden tiles fires
  onCoinsEarned without changing score` plus `playing non-golden tiles credits
  nothing` in `game_cubit_test.dart`.

### Task 5: Delete production methods and correct documentation

**Files:**

- Modify: `lib/application/game_cubit.dart`
- Modify: `lib/domain/engine/game_engine.dart`
- Modify: `lib/domain/models/move.dart`

- [ ] Delete `GameCubit.merge`, `GameEngine.merge`, and
  `GameEngine.goldenBonusFor` only after their final test consumer is gone.
- [ ] Update `playChain`, `_finishRun`, undo, undo-frame, callback, and run-coin
  comments so no live documentation describes the removed producer.
- [ ] Replace `collapseChain`'s stale “Mirrors [merge]” comment with its direct
  no-refill/no-log contract.
- [ ] Document `canMerge` as retained only for the golden-vector
  rejection-sentinel generator, not as a chain-validation building block.
- [ ] Relabel `MergeEvent` “legacy, server-rejected — retained for log-format
  compatibility and the rejection sentinel” without changing code.
- [ ] Run the three focused migrated suites together and require green.

### Task 6: Format, audit, and prove the frozen plan

- [ ] Format only changed Dart files.
- [ ] Search for zero references to `GameEngine.merge(`,
  `GameEngine.goldenBonusFor`, and the removed `GameCubit.merge` declaration or
  calls; inspect remaining allowlisted `MergeEvent` references.
- [ ] Confirm no file under `supabase/**`, the Flutter golden-vector generator,
  or the committed fixture was modified.
- [ ] Run `flutter analyze` and capture its full tail.
- [ ] Run full `flutter test` and capture its full tail.
- [ ] Run `flutter test test/domain/engine/golden_vectors_test.dart` and capture
  its full tail.
- [ ] Run `deno test --frozen supabase/functions/` and capture its full tail.
- [ ] Re-read root `PLAN.md` line by line and report every actual per-test
  migration/deletion and any deviation.
