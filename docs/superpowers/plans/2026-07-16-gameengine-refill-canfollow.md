# GameEngine Refill and Tier-Step Single-Sourcing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Single-source the chain-step and refill rules in each language,
harden rewarded continues, prove the refactor byte-identical, then restore the
golden generator's ascend-only coverage.

**Architecture:** Dart rule ownership moves into `GameEngine`; TypeScript
dependency-free tier predicates live in `constants.ts` and replay refill lives
in one exported `engine.ts` helper. Phase A preserves the fixture exactly;
Phase B alone changes generator policy and regenerates under the force flag.

**Tech stack:** Dart/Flutter, TypeScript/Deno, bloc, deterministic PRNG, JSON
golden vectors.

## Global constraints

- Follow root `PLAN.md` exactly and in order: docs first, all Phase A proof
  before any Phase B edit.
- Do not perform Git mutations. Replace commit checkpoints with read-only
  `git diff` and `git status` review checkpoints.
- Production edits are limited to the six files named in root `PLAN.md`.
- Keep Dart and TypeScript rule behavior and documentation in lockstep.
- Do not change scoring, `kLeaderboardSeason`, `VerifyResult`, CI, deployment,
  or the legacy merge APIs.
- In Phase A, never alter `supabase/functions/_shared/golden_vectors.json`.
- Use PowerShell environment-variable syntax for generator runs.

---

### Task 1: Record the approved design and executable plan

**Files:**

- Create: `docs/superpowers/specs/2026-07-16-gameengine-refill-canfollow-design.md`
- Create: `docs/superpowers/plans/2026-07-16-gameengine-refill-canfollow.md`

**Interfaces:**

- Consumes: frozen root `PLAN.md`.
- Produces: the exact task order and proof gates used below.

- [ ] Write both documents before changing any production or test file.
- [ ] Check them for placeholders, contradictions, signature drift, and missing
      Phase A/Phase B gates.
- [ ] Review with `git diff --check` and a read-only scoped diff.

### Task 2: Single-source the tier-step predicates

**Files:**

- Modify: `test/domain/engine/game_engine_test.dart`
- Modify: `supabase/functions/_shared/engine.test.ts`
- Modify: `lib/domain/engine/game_engine.dart`
- Modify: `lib/presentation/widgets/board_widget.dart`
- Modify: `supabase/functions/_shared/constants.ts`
- Modify: `supabase/functions/_shared/engine.ts`
- Modify: `supabase/functions/_shared/seeder.ts`

**Interfaces:**

- Produces: Dart `static bool canFollow(int prevTier, int nextTier)`.
- Produces: TS `canFollow(prevTier: number, nextTier: number): boolean`.
- Produces: TS `pairMergeable(aTier: number, bTier: number): boolean`.

- [ ] Add Dart tests for equal, ascend, descend, and skipped-tier results plus
      cap-edge routing through `canMerge`/deadlock behavior.
- [ ] Run `flutter test test/domain/engine/game_engine_test.dart --plain-name "canFollow"`
      and require failure because `GameEngine.canFollow` does not exist.
- [ ] Add TS tests importing `canFollow` and `pairMergeable` from
      `constants.ts`, covering equal, ascend, descend/skip symmetry, and the cap.
- [ ] Run `deno test supabase/functions/_shared/engine.test.ts` and require
      failure because those exports do not exist.
- [ ] Implement the exact Dart expression and route `isValidChain`, `canMerge`,
      tier-number `_pairMergeable`, and `BoardWidget._canExtend` through it.
- [ ] Implement the exact TS tier-number predicates in `constants.ts`; import
      them in `engine.ts` and `seeder.ts`; delete both private copies.
- [ ] Run the two targeted test files and require both to pass.

### Task 3: Move Dart refill into GameEngine

**Files:**

- Modify: `test/domain/engine/game_engine_test.dart`
- Modify: `lib/domain/engine/game_engine.dart`
- Modify: `lib/application/game_cubit.dart`

**Interfaces:**

- Produces: `GameEngine.refill(BoardState board, {required int targetFill,
  required int Function(int dropIndex) tierAt, required Prng landing,
  Set<int> goldenDrops = const {}})`.

- [ ] Add tests for fill-only, merge-required top-up, full-board stop,
      per-iteration `dropIndex` read order, and golden membership.
- [ ] Run `flutter test test/domain/engine/game_engine_test.dart --plain-name "refill"`
      and require failure because `GameEngine.refill` does not exist.
- [ ] Move the `playChain` loop body verbatim into `GameEngine.refill`, reading
      the current board's `dropIndex` separately at both required points.
- [ ] Replace the cubit loop with one call using
      `tierAt: (i) => _seeder.dropTierAt(_dropTier, i)` and `_goldenDrops`.
- [ ] Update the cubit refill comment to name engine ownership.
- [ ] Run the targeted engine and cubit refill tests and require passing output.

### Task 4: Collapse TypeScript verifier refill copies

**Files:**

- Modify: `supabase/functions/_shared/engine.test.ts`
- Modify: `supabase/functions/_shared/engine.ts`

**Interfaces:**

- Produces: exported `refillBoard(board: BoardState, targetFill: number,
  tierAt: (dropIndex: number) => number, landing: Prng): BoardState`.

- [ ] Add unit tests for fill-only, merge-required top-up, full-board stop, and
      per-iteration drop-index order.
- [ ] Run `deno test supabase/functions/_shared/engine.test.ts` and require
      failure because `refillBoard` is not exported.
- [ ] Move one existing loop verbatim into `refillBoard`, document the Dart
      mirror and Dart-only golden flag, route both verifiers through it, and
      delete both inline loops.
- [ ] Run the targeted Deno test file and require passing output.

### Task 5: Guard rewarded continues

**Files:**

- Modify: `test/application/game_cubit_test.dart`
- Modify: `lib/application/game_cubit.dart`

**Interfaces:**

- Consumes: existing `GameCubit.canOfferAd`.
- Produces: private `_grantingAd` asynchronous in-flight guard.

- [ ] Add independent no-op tests for wrong state, result board not
      `outOfMoves`, cap exhausted, and no merge available.
- [ ] Add a concurrent-double-call test whose storage save is held in flight
      and assert exactly one continue event/use is recorded.
- [ ] Run the focused tests and require at least the eligibility/concurrency
      cases to fail against the unguarded method.
- [ ] Add `if (!canOfferAd || _grantingAd) return;`, set `_grantingAd = true`
      immediately before `try`, preserve the existing grant body inside it,
      and clear the flag in `finally`.
- [ ] Run `flutter test test/application/game_cubit_test.dart` and require pass.

### Task 6: Document and prove Phase A before touching Phase B

**Files:**

- Modify: `CLAUDE.md`
- Modify: `AGENTS.md`

- [ ] Update both dual-engine sections to name `canFollow`, Dart `refill`, and
      TypeScript `refillBoard` as mirrored surfaces.
- [ ] Run `flutter analyze` and require clean output.
- [ ] Run `flutter test` and require all tests green.
- [ ] Run `deno test --frozen supabase/functions/` and require all tests green.
- [ ] Run
      `$env:UPDATE_GOLDENS='1'; flutter test test/domain/engine/golden_vectors_test.dart`
      and require pass.
- [ ] Run
      `git diff --exit-code supabase/functions/_shared/golden_vectors.json ; echo EXIT=$LASTEXITCODE`
      and require `EXIT=0`.
- [ ] If the fixture differs, stop Phase B, find and fix the behavioral drift,
      and repeat the complete Phase A gate without editing the fixture.

### Task 7: Restore ascend-only generator coverage (Phase B)

**Files:**

- Modify: `test/domain/engine/golden_vectors_test.dart`
- Modify: `supabase/functions/_shared/golden_vectors.json` via generator only

- [ ] Delete the challenge-date `_hasAdjacentSameTier` filter and helper.
- [ ] Add an assertion over initial boards requiring at least one named vector
      with an adjacent ascend-by-one pair and no adjacent same-tier pair; include
      the missing scenario name in the failure.
- [ ] Run the focused generator test without regeneration and require failure
      because the committed fixture/policy does not yet encode the new coverage.
- [ ] Run
      `$env:UPDATE_GOLDENS='1'; $env:UPDATE_GOLDENS_FORCE='1'; flutter test test/domain/engine/golden_vectors_test.dart`
      and require pass with a regenerated fixture.
- [ ] Run `flutter analyze`, `flutter test`, and
      `deno test --frozen supabase/functions/`; require all green.
- [ ] Run `git diff --check`, inspect `git diff --stat`, and inspect
      `git status -sb`; require that only the approved create/edit paths changed.

## Out of scope

- Any Git commit, branch, checkout, stash, reset, or other state mutation.
- Removing legacy merge methods/events.
- Rule, scoring, season, verifier-result, deployment, or CI changes.
