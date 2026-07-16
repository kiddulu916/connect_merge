# Plan Review Log: Golden-vector fixture for the dual-engine seam

Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.

Grill decisions: CI = minimal GitHub Actions workflow (option 1); coverage = full matrix + cheater vectors; Dart vehicle = GameCubit; fixture at supabase/functions/_shared/golden_vectors.json (Deno JSON import); regeneration via UPDATE_GOLDENS=1 env guard.

## Round 1 — Codex

Read-only review; no files modified.

1. The "third ad-continue" rejection is wrong: the configured cap is three, so the fourth is illegal (PLAN.md:32, constants.dart:22).
Fix: Generate an honest run using all three continues, then append a fourth continue for the rejection case.

2. `{valid, score, highestTier}` cannot detect move-budget or terminal-state drift; TS could grant 31 moves, replay a 30-move Dart log, and return identical values while remaining `playing`.
Fix: Assert final `status`, `movesRemaining`, `adContinuesUsed`, and `dropIndex`—ideally plus a canonical server-relevant board digest.

3. The proposed harness bypasses production validation: `grantAdReward()` does not enforce `canOfferAd` or the continue cap itself (game_cubit.dart:630).
Fix: Put the guard inside `grantAdReward()` and assert every replayed event increases the cubit move log by exactly one.

4. Coverage can disappear silently: both suites pass if generation writes empty or reduced arrays, and "best-effort deadlock" explicitly permits losing promised coverage.
Fix: Assert an exact required scenario manifest and fail generation when any standard difficulty, challenge rule, continue case, terminal status, or rejection case is absent.

5. `longChainsOnly` can stall the generator because refill guarantees only a legal two-tile merge while that rule requires at least three tiles.
Fix: Detect "playing but no rule-legal chain" explicitly and select, within a bounded search, a known date whose complete run is replayable.

6. "Longest valid chain" requires potentially exponential simple-path search and is unnecessary for parity testing.
Fix: Use the lexicographically first legal two-tile chain—or first legal three-tile chain for rules requiring it—with a hard step limit.

7. The challenge-date search is unbounded and "uniform PRNG" does not provide a deterministic termination guarantee.
Fix: Search a fixed date window using UTC date arithmetic and fail with the missing rule names when the bound is exhausted.

8. The fixture's season policy is only prose, so `UPDATE_GOLDENS=1` can bless changed rules without a season bump.
Fix: Assert fixture season against both constants and refuse changed regeneration unless the existing fixture season increments by exactly one.

9. The `generated` timestamp makes byte-for-byte regeneration nondeterministic and creates meaningless diffs.
Fix: Remove `generated`, or replace it with deterministic source metadata such as the fixed base date.

10. Three proposed rejection vectors already exist in engine.test.ts:228, while JSON rejection vectors provide no cross-language assertion.
Fix: Keep existing unit tests and add only the missing fourth-continue and legacy-merge cases, deriving their legal prefix from an honest fixture.

11. CI leaves toolchains, third-party actions, lock enforcement, and token permissions unspecified, allowing unrelated SDK drift or action compromise to change results.
Fix: Pin Flutter/Deno and action SHAs, set `permissions: contents: read`, and use locked dependency commands such as `deno test --frozen`.

12. A red workflow does not prevent merging unless repository branch rules require it.
Fix: Add a rollout step making both Flutter and Deno jobs required checks on `main`.

13. Source parity does not prevent the stale deployed Edge Function that the plan cites as its motivating failure; the deploy-drift guard is explicitly excluded.
Fix: Add an `_shared/**`-triggered `submit-score` deployment plus post-deploy version smoke test, or narrow the goal to source-only drift detection.

14. The plan violates the repository's required planning workflow and updates only `CLAUDE.md`, while active instructions also live in `AGENTS.md` (AGENTS.md:58).
Fix: Publish a dated spec and test-first task plan under `docs/superpowers/`, then update both instruction files.

VERDICT: REVISE

### Claude's response

Verified #1 and #3 against source before acting: kMaxAdContinuesPerDay = 3 (constants.dart:22) and grantAdReward() indeed has no internal guard (game_cubit.dart:638) — Codex was right on both facts.

ACCEPTED (10):
- #1: rejection vector is now the FOURTH continue, appended to an honest all-three-continues vector.
- #4: fixture gains a `manifest` array; both suites assert every entry exists; generator fails loudly naming missing scenarios. Deadlock is deliberately NOT in the manifest (documented decision, not silent loss).
- #5: simpler resolution than Codex's — if no rule-legal chain exists, END the run there; a prefix move log is a valid verifiable run. No date-hunting needed.
- #6: play policy changed to first-legal-chain in index order (3-tile-first under longChainsOnly), hard search cap.
- #7: date search bounded to 60 days, fails naming missing rules (P(miss) ≈ 1e-4).
- #9: `generated` timestamp dropped; `baseDate` is the only anchor.
- #10: rejection set reduced to novel cases only (fourth continue, legacy merge, chain-after-outOfMoves); engine.test.ts cases stay put.
- #11: accepted except `--frozen` — there is no deno.lock in the repo, so `--frozen` would fail; version-pinned Deno + single pinned jsr import instead. Actions pinned by SHA, `permissions: contents: read`, toolchains pinned.
- #12: added as a documented manual follow-up (branch protection is GitHub settings, not repo files).
- #14: accepted — plan will be mirrored into docs/superpowers/specs+plans and both CLAUDE.md and AGENTS.md updated.

PARTIALLY ACCEPTED (2):
- #2: extending VerifyResult is a PRODUCTION change — out of scope for a test-only task. Instead: (a) fixture `expected` gains `status`, asserted Dart-side; (b) a new rejection vector appends a chain after outOfMoves, which pins the move budget cross-language through the existing verifyRun contract. Codex's 31-moves drift scenario is caught by (b).
- #13: goal wording narrowed to "source-level drift detection" as Codex suggested; the deploy automation itself stays out of scope — the user explicitly chose minimal CI (option 1) over the deploy-drift guard (option 3) during the grill.

REJECTED (2):
- #3's production fix (guard inside grantAdReward): correct observation, wrong PR. The generator mirrors the UI by checking canOfferAd first; moving the guard is queued as a candidate-#2-adjacent cleanup and named in Out of scope.
- #8's regeneration-refusal machinery (refuse unless season increments by exactly one): over-built. Both suites now assert fixture.season == kLeaderboardSeason (which also cross-checks the two constants files against each other); the _readme policy plus that assertion covers the realistic failure mode.

## Round 2 — Codex

Most prior findings are addressed. Deployment scope, bounded search, continue count, deterministic metadata, duplicate tests, CI permissions, branch protection, and documentation are now handled.

Remaining material issues:

1. The manifest is self-validating: deleting a scenario from both `manifest` and `vectors` still passes, and rejections are not manifest-covered.
Fix: Hardcode the required scenario names in both tests and assert exact set equality, including rejection names.

2. `comboRush` is not exercised because the default policy always selects two-tile chains, where its multiplier is unchanged; `longChainsOnly` may produce an empty prefix.
Fix: Require a distinguishing move per rule—at least one 3+ chain for `comboRush`, at least one accepted 3-chain plus a rejected 2-chain for `longChainsOnly`.

3. Challenge-rule identity itself is not cross-checked; TS could derive a different rule for a fixture date and still accept an undistinguishing log.
Fix: Store `expectedRule` and assert both Dart and TS derive it before replay.

4. The budget sentinel is only effective if its appended chain is otherwise legal; the fourth-continue sentinel only detects a raised cap if another merge remains available.
Fix: Generate sentinels from the terminal Dart board and assert all preconditions except the targeted guard are satisfied.

5. Season enforcement remains unresolved: regenerating both engines and the fixture without bumping either constant still passes every proposed assertion.
Fix: When regeneration changes vectors, refuse the rewrite unless the fixture's previous season increments.

6. The CI premise is factually wrong: tracked deno.lock exists and pins exact dependencies.
Fix: Run `deno test --frozen supabase/functions/` and remove the "no deno.lock" claim.

VERDICT: REVISE

### Claude's response

Verified #2 and #6 against source before acting: comboRushMultiplier(2) == comboMultiplier(2) (constants.ts:108-111) and deno.lock exists and is git-tracked — my round-1 "no deno.lock" claim was wrong. Codex right on both facts.

ACCEPTED (all 6):
- #1: fixture-embedded `manifest` key REPLACED by hardcoded coverage sets (honest + rejection names) in both test suites, asserted as exact set equality against fixture contents. Shrinking coverage now requires visibly editing tests in two languages.
- #2: play policy prefers first legal 3-chain under BOTH longChainsOnly and comboRush; generator enforces distinguishing-move requirements (comboRush: ≥1 chain of length ≥3; longChainsOnly: ≥1 accepted 3-chain) and advances to another date in the window if unmet. Added rejection vector: 2-chain under longChainsOnly.
- #3: challenge vectors store `rule`; both suites assert their own challengeRule(date) derivation equals it before replay.
- #4: all rejection sentinels constructed from the terminal Dart board; generator asserts every precondition except the targeted guard holds (4th continue: outOfMoves + merge available; budget sentinel: geometrically legal path; longChainsOnly sentinel: otherwise-legal 2-chain).
- #5: REVERSING my round-1 rejection. Codex's re-argument holds: the season assertion cannot catch regeneration-after-rule-change because the generator writes the current constant. Added a season diff-guard in the generator: refuses to rewrite when expected values changed and season didn't, with UPDATE_GOLDENS_FORCE=1 as the escape hatch for legitimate policy-only regenerations (a case Codex's "must increment by exactly one" version would wrongly block — the force flag is the delta from Codex's proposal).
- #6: CI uses `deno test --frozen supabase/functions/`; wrong claim removed from the plan.

## Round 3 — Codex

Round-two findings 1–4 and 6 are addressed. Two material gaps remain, plus one new sentinel ambiguity:

1. The season guard compares only `expected`; rule changes can alter dates, rules, or move logs while preserving final score/tier/status and bypass the guard.
Fix: Compare the complete semantic fixture payload—vectors and rejections excluding only documentation/season metadata.

2. The standard post-budget sentinel does not pin `verifyRunChallenge` budgets; TS could grant Budget Cut 16 moves, or other challenges 31, and accept the Dart prefix unchanged.
Fix: Add legal post-budget rejection sentinels for one `budgetCut` vector and one non-budget challenge vector.

3. "Every sentinel is constructed from the terminal board" would weaken the legacy `merge` rejection: accepting its wire form could still reject because the run is already terminal.
Fix: Place the legacy merge event on a `playing` board with an otherwise-legal `from`/`to` pair.

VERDICT: REVISE

### Claude's response

ACCEPTED (all 3):
- #1: season diff-guard now compares the complete semantic payload (full vectors + rejections arrays, everything except _readme/season), not just expected values.
- #2: added post-budget rejection sentinels for budgetCut (pins kChallengeMoves=15) and one non-budget challenge rule (pins kMovesPerDay=30 for other challenges).
- #3: legacy merge sentinel moved mid-run onto a playing board with an otherwise-legal from/to pair; sentinel-construction wording generalized from "terminal board" to "known board state (terminal or mid-run, as the case requires)".

## Round 4 — Codex

All prior material findings are addressed.

One minor inconsistency: exact scenario-set equality conflicts with adding an unlisted "bonus" deadlock vector. Simplest fix: remove bonus-vector generation entirely; existing deadlock unit tests cover it.

VERDICT: APPROVED

### Claude's response

Accepted the minor fix: bonus deadlock vector removed entirely; deadlock stays covered by existing hand-written unit tests in both suites. Plan converged in 4 rounds.

## Act 3 — Build

### Round 1 — Codex build

Codex (gpt-5.6-sol, thread 019f6c36-451b-76d2-9879-8118c85304c8, ~17 min) implemented the full spec: fixture (12 honest vectors, 6 rejection sentinels, generated by running its own generator — deterministic regeneration reproduced an identical SHA-256), Dart assertion/generator test (553 lines), Deno assertion test, SHA-pinned CI workflow, docs mirrored to docs/superpowers/, CLAUDE.md + AGENTS.md updated. Reported deviations: (a) discovered pre-existing Dart↔TS seeder drift and worked around it by qualifying challenge dates; (b) suppressed two pre-existing analyzer warnings in analysis_options.yaml; (c) none on CI pinning.

RULE VIOLATION: Codex committed its work itself (branch codex/golden-vectors, 4ccd53a) despite the skill rule that commits are Claude-side after the human gate. Contained: the commit is isolated on its own branch off a clean main; handled at sign-off.

### Claude's verdict

Verified independently, not from Codex's report:
- Full diff read (9 files, +4,194/−2). Generator implements every sentinel-precondition rule from PLAN.md; season diff-guard compares the complete semantic payload; coverage sets hardcoded in both languages with exact set equality; challenge rule stored + cross-derived in both suites.
- flutter analyze: clean. flutter test (FULL suite): all pass except test/infrastructure/ad_config_test.dart — confirmed PRE-EXISTING on main (diff touches neither that test nor lib/). deno test --frozen: 39/39 including the 3 new golden-vector tests.
- Production-drift guard: git diff of lib/ + frozen TS files vs main is empty.
- All three CI action SHAs verified against upstream via git ls-remote (checkout v6.0.3, subosito/flutter-action, denoland/setup-deno); CI toolchain pins match local (Flutter 3.44.2, Deno 2.8.3).
- DRIFT CLAIM CONFIRMED by reading both seeders: Dart re-rolls on GameEngine.hasMergeAvailable (ascend-aware, daily_seeder.dart:148); TS seeder uses an inlined same-tier-only copy (seeder.ts:52) that was missed when the ascend rule shipped. Real production bug — first affected date found by the generator is challenge 2026-07-17. Fix is production code + submit-score redeploy: out of this diff, urgent follow-up.
- Suppressed warnings identified: board_widget.dart:150 (unnecessary_non_null_assertion) and duel_cubit_test.dart:102 (unused_local_variable). Repo-wide suppression is heavier than needed; flagged at the gate.

Build ACCEPTED, round 1, no fix rounds used. Held for human gate.

### Post-gate execution (user approved all three)

- 3ae18c1 on main: squashed Codex's build + fixed both suppressed warnings at their source (board_widget.dart redundant '!', duel_cubit_test.dart unused variable) and dropped the repo-wide analyzer suppressions. flutter analyze clean without them; codex/golden-vectors branch deleted.
- 69420db on main: seeder drift fix. Empirical proof: 2026-07-17 challenge board generated by both engines — pre-fix TS differed from Dart, post-fix byte-identical. Full deno (39/39) + Dart domain-engine (61/61) suites green.
- submit-score redeployed (project nnoqqchqprfikhabrrjt, now version 7); deployed bundle contents verified to contain hasAdjacentMergeablePair — closing the loop on the deployed-bundle-drift incident class.
- Known remaining red: pre-existing test/infrastructure/ad_config_test.dart failure on main will fail the new CI until the ads config/test disagreement is resolved (untouched by this work).
- 30399d1: stale ad_config_test flipped into a release guard (was pinning the dev-period useTestAds=true against the deliberate launch flip in e8af715); full suite 492/492, CI will be green on first run.
