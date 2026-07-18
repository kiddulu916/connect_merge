# Plan Review Log: remove the legacy single-pair merge path

Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.

(Prior candidates' logs live in git history: #1 b06017f, #2 28a539e, #3 e70490e, #5 63c3682, #4 a16a131, #6 e256739.)

Grill decision (scope confirmed by user): remove GameCubit.merge(), GameEngine.merge(), GameEngine.goldenBonusFor; KEEP MergeEvent + canMerge for the reject-legacy-merge-event golden sentinel; migrate merge-based tests pinning unique invariants to playChain, delete API-only duplicates. Established from code: no UI reaches GameCubit.merge (BoardWidget emits chains only); TS parseEvent accepts only chain/continue so merge logs are already server-rejected (sentinel-pinned); undo suite already has playChain variants; goldenBonusFor's only production caller is the removed method; .merge( test refs = undo 11 + cubit 9 + engine 4. No TS change, no deploy, no season bump.

## Round 1 — Codex

## Findings

1. **The plan defers the actual migration plan.** [PLAN.md](/C:/Users/dat1k/Projects/connect_merge/PLAN.md:11) promises a later per-reference disposition, while mischaracterizing the nine cubit calls: they drive analytics across continues, golden/double-coin behavior, snapshot round-tripping, and `_completeTier` completion/streak/error tests—not “before init/after completion” guards ([game_cubit_test.dart](/C:/Users/dat1k/Projects/connect_merge/test/application/game_cubit_test.dart:133), [helper](/C:/Users/dat1k/Projects/connect_merge/test/application/game_cubit_test.dart:706)).

   Fix: Enumerate all 24 references in PLAN.md now; migrate every cubit call except the API-specific “legal merge” test.

2. **The undo migration cannot work by replacing calls.** Its replay helper handles only `MergeEvent` and one drop, whereas `playChain` requires `collapseChain → refill`—potentially multiple drops—and logs `ChainEvent`; its pair finder also returns non-adjacent pairs that `playChain` rejects ([game_cubit_undo_test.dart](/C:/Users/dat1k/Projects/connect_merge/test/application/game_cubit_undo_test.dart:21)).

   Fix: First replace the replay helper with chain/refill replay and replace both pair finders with an oriented, orthogonally-adjacent legal-chain finder.

3. **Deleting snapshot persistence coverage would leave a hole.** The current test is the only snapshot round-trip covering move ordering with a continue ([game_cubit_test.dart](/C:/Users/dat1k/Projects/connect_merge/test/application/game_cubit_test.dart:272)); golden vectors do not round-trip snapshots, Hive tests use empty logs, and the model’s mixed-log test uses legacy merges.

   Fix: Migrate this test to `ChainEvent` plus `ContinueEvent` and retain its ordering and `GameSnapshot.fromJson` assertions.

4. **The planned engine-test deletion loses a live golden-tile invariant.** The golden/control test verifies equal authoritative score and consumption of the cosmetic `golden` flag ([game_engine_test.dart](/C:/Users/dat1k/Projects/connect_merge/test/domain/engine/game_engine_test.dart:270)); those requirements still apply to `collapseChain`.

   Fix: Rewrite that test using `GameEngine.collapseChain([0, 1])`; delete only the `goldenBonusFor`-specific assertions.

5. **`canMerge` is not a chain-validator building block, and the sentinel does not exercise it in normal CI.** `isValidChain` calls `canFollow` directly ([game_engine.dart](/C:/Users/dat1k/Projects/connect_merge/lib/domain/engine/game_engine.dart:193)); `canMerge` runs only during fixture regeneration, while the normal Dart golden test merely checks rejection names and `expected.valid == false` ([golden_vectors_test.dart](/C:/Users/dat1k/Projects/connect_merge/test/domain/engine/golden_vectors_test.dart:56)).

   Fix: Simplest is delete `canMerge` and validate the sentinel path with `isValidChain`; otherwise document it as sentinel-only and assert committed-sentinel legality during ordinary CI.

6. **The final `MergeEvent` grep expectation is false and dangerous.** Legitimate references remain in model compatibility tests, leaderboard serialization tests, session-factory tests, and snapshot deserialization—not just the fixture ([move_test.dart](/C:/Users/dat1k/Projects/connect_merge/test/domain/models/move_test.dart:5), [leaderboard_service_test.dart](/C:/Users/dat1k/Projects/connect_merge/test/infrastructure/leaderboard_service_test.dart:24), [game_session_factory_test.dart](/C:/Users/dat1k/Projects/connect_merge/test/application/game_session_factory_test.dart:112)).

   Fix: Require zero references only for the three removed methods; explicitly allowlist and preserve legacy-event serialization, snapshot-compatibility, and rejection-sentinel consumers.

7. **More production Dartdoc references break than the plan names.** Removing `merge` leaves stale `[merge]` links in `playChain` and `_finishRun`, not only the undo comment ([game_cubit.dart](/C:/Users/dat1k/Projects/connect_merge/lib/application/game_cubit.dart:328), [game_cubit.dart](/C:/Users/dat1k/Projects/connect_merge/lib/application/game_cubit.dart:430)).

   Fix: Sweep all production comments for pair-path claims and label `MergeEvent` as legacy/rejected rather than an accepted live move.

No TS engine or season bump is needed; that part is sound.

VERDICT: REVISE
### Claude's response

Accepted (6/7): full 24-reference disposition enumerated in the plan with the cubit tests correctly characterized as cross-cutting behavior (analytics-across-continues, coin flows, snapshot round-trip, completion hooks) that ALL migrate except the one API-specific test (1); migration infrastructure lands first — chain/refill-aware replay helper + oriented adjacent legal-chain finder replacing the MergeEvent-shaped helper and non-adjacent pair finders (2); the mixed-log snapshot round-trip migrates to ChainEvent+ContinueEvent keeping ordering + fromJson assertions (3); the golden/control equal-score test is REWRITTEN via collapseChain([0,1]) — live invariant, not deleted (4); grep proof criterion fixed to zero-refs-for-removed-methods-only with an explicit MergeEvent allowlist (move_test, leaderboard_service_test, game_session_factory_test, snapshot tests) — legacy-log FORMAT compat is kept, only the producer goes (6); full Dartdoc sweep incl. playChain:328 and _finishRun:430, MergeEvent relabeled legacy/server-rejected (7).

Modified (1/7): finding 5 — canMerge is NOT deleted (the user explicitly locked keeping it at the grill); instead its false "chain-validator building block" rationale is dropped and its doc names the sentinel generator as sole consumer. The suggested extra CI legality assertion is declined: the TS suite already replays the committed sentinel and asserts rejection every run — rejection, not pair-legality, is the sentinel's proof.

## Round 2 — Codex

Most prior findings are addressed: snapshot coverage, golden-tile invariants, legacy-reference allowlisting, and Dartdoc cleanup are now explicit. Three material gaps remain.

1. **Replay lifecycle remains incomplete in the plan.** [PLAN.md](/C:/Users/dat1k/Projects/connect_merge/PLAN.md:12) specifies `collapseChain → refill` but omits validation and `evaluateStatus`, both required to mirror `playChain` and server replay.

   Fix: Specify `playing guard → isValidChain → collapseChain → refill → evaluateStatus`, while preserving `ContinueEvent` handling.

2. **“Infrastructure first while green” is internally inconsistent.** Existing tests still feed `MergeEvent` into the replay helper ([game_cubit_undo_test.dart](/C:/Users/dat1k/Projects/connect_merge/test/application/game_cubit_undo_test.dart:33)); replacing it with chain-only handling before migrating tests makes them fail.

   Fix: Add `ChainEvent` support alongside the temporary merge branch, then delete the merge branch atomically with the final migrated consumer.

3. **A third finder remains unaddressed.** `_findMergePair` in [game_cubit_test.dart](/C:/Users/dat1k/Projects/connect_merge/test/application/game_cubit_test.dart:748) finds only equal-tier pairs, but migrated repeated-chain tests may encounter an ascend-only board even when `hasMergeAvailable` is true.

   Fix: Replace this helper too with an oriented adjacent path finder whose result passes `GameEngine.isValidChain`.

4. **The undo disposition still is not actually enumerated.** [PLAN.md](/C:/Users/dat1k/Projects/connect_merge/PLAN.md:14) leaves “chain-based duplicates” unnamed; the legacy basic-undo test asserts full `BoardState.toJson` equality, stronger than the existing chain test’s score/moves/drop assertions.

   Fix: Name each deleted test and explicitly migrate the full-state equality assertion before deleting any weaker duplicate.

VERDICT: REVISE
### Claude's response

Accepted (4/4): replay helper lifecycle fully specified (playing guard -> isValidChain -> collapseChain -> refill -> evaluateStatus, ContinueEvent preserved) (1); two-phase helper — ChainEvent branch added ALONGSIDE the temporary merge branch, merge branch deleted atomically with its last migrated consumer, so the suite is green at every step (2); the third finder (_findMergePair, game_cubit_test.dart:748, equal-tier-only) replaced too, all finders' outputs asserted to pass isValidChain (3); the legacy basic-undo test's full BoardState.toJson equality migrates to the chain test BEFORE any weaker duplicate is deleted, and the step-0 docs plan names every deleted test with its superseding chain test (4).

## Round 3 — Codex

All four round-2 findings are addressed: full replay lifecycle, additive two-phase migration, all three relevant finders, and preservation of full-state undo coverage.

One minor omission: add [game_engine.dart](/C:/Users/dat1k/Projects/connect_merge/lib/domain/engine/game_engine.dart:215) to the doc sweep; its `Mirrors [merge]` link becomes stale after removal. The existing sweep/analyze requirement should catch it, so this is non-blocking.

VERDICT: APPROVED