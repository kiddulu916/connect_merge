# Golden Vectors for the Dual-Engine Seam Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Commit deterministic runs produced by the real Dart client path,
assert them in both languages, and run both suites in hardened minimal CI.

**Architecture:** One JSON fixture is generated and replayed by a Flutter test
through `GameCubit`, then imported by a Deno test and replayed through the
production TypeScript verifier. No production code changes.

## Global constraints

- Nothing under `lib/` changes.
- Under `supabase/functions/`, add only the fixture and new test.
- Keep all existing engine, seeder, constants, PRNG, tests, and Edge Function
  entry points byte-identical.
- Generate the fixture by running the Flutter generator; never hand-write it.
- Keep both hardcoded coverage-name sets identical and exact.
- Use stable JSON ordering and formatting with no timestamps.
- Do not change rules, scoring, or `kLeaderboardSeason`.

### Task 1: Add the Flutter assertion/generator seam

**Files:**

- Create: `test/domain/engine/golden_vectors_test.dart`

- [ ] Add the normal fixture-loading assertion with the complete hardcoded
      honest and rejection name sets.
- [ ] Assert the fixture season equals Dart `kLeaderboardSeason`.
- [ ] Replay every honest vector through `GameCubit` using
      `InMemoryStorageService` and compare score, highest tier, and status.
- [ ] For challenge vectors, derive and compare `challengeRule(date)` before
      replay.
- [ ] Add `UPDATE_GOLDENS=1` generation, deterministic first-legal-chain play,
      bounded chain/date searches, and `canOfferAd`-guarded continues.
- [ ] Add the full semantic-payload season diff guard and
      `UPDATE_GOLDENS_FORCE=1` policy-only override.

Run: `flutter test test/domain/engine/golden_vectors_test.dart`

Expected: FAIL because `golden_vectors.json` does not exist yet.

### Task 2: Generate the committed fixture and rejection sentinels

**Files:**

- Create: `supabase/functions/_shared/golden_vectors.json` via Task 1

- [ ] Generate the four standard difficulty vectors on the fixed base date.
- [ ] Search the 60-day window for all six challenge rules.
- [ ] Require distinguishing three-chains for `comboRush` and
      `longChainsOnly`.
- [ ] Generate the no-continue and all-three-continues standard runs.
- [ ] Construct the fourth-continue, three post-budget, long-chain length-gate,
      and legacy merge-wire rejections from replayed Dart board states.
- [ ] Assert every non-target precondition before serializing a rejection.
- [ ] Verify exact coverage and deterministic output.

Run (PowerShell):

```powershell
$env:UPDATE_GOLDENS='1'; flutter test test/domain/engine/golden_vectors_test.dart
```

Expected: PASS and a newly generated fixture with 12 honest vectors and 6
rejections.

Run: `flutter test test/domain/engine/golden_vectors_test.dart`

Expected: PASS in normal assertion mode.

### Task 3: Add the TypeScript assertion

**Files:**

- Create: `supabase/functions/_shared/golden_vectors.test.ts`

- [ ] JSON-import the fixture without filesystem permissions.
- [ ] Assert the TypeScript season and the same exact coverage-name sets.
- [ ] Derive challenge rules independently.
- [ ] Replay honest vectors through `verifyRun` or `verifyRunChallenge` and
      compare validity, score, and highest tier.
- [ ] Replay every rejection and assert `valid: false`.
- [ ] Leave `engine.test.ts` untouched.

Run:
`deno test --frozen supabase/functions/_shared/golden_vectors.test.ts`

Expected: PASS.

### Task 4: Add minimal hardened CI

**Files:**

- Create: `.github/workflows/test.yml`

- [ ] Trigger pushes and pull requests to `main`.
- [ ] Set `permissions: contents: read`.
- [ ] Pin third-party actions by full commit SHA.
- [ ] Pin Flutter to the locally reported version and enable its cache.
- [ ] Pin a current Deno 2.x and enable its cache.
- [ ] Run `flutter analyze` plus `flutter test` in one job.
- [ ] Run `deno test --frozen supabase/functions/` in the other.
- [ ] Add no secrets, deployment, or deploy-drift checks.

Manual follow-up: mark both jobs as required checks for `main` in GitHub
branch protection.

### Task 5: Document the fixture and commands

**Files:**

- Create: `docs/superpowers/specs/2026-07-14-golden-vectors-design.md`
- Create: `docs/superpowers/plans/2026-07-14-golden-vectors.md`
- Modify: `CLAUDE.md`
- Modify: `AGENTS.md`

- [ ] Record the approved design and task plan in existing repository style.
- [ ] Add normal assertion, regeneration, and force-regeneration commands to
      both agent guides.
- [ ] Point both dual-engine-invariant sections at the committed fixture.

### Task 6: Verify and protect the production boundary

- [ ] Run `flutter analyze`.
- [ ] Run `flutter test test/domain/engine/golden_vectors_test.dart`.
- [ ] Run `deno test --frozen supabase/functions/`.
- [ ] Run the production-file diff guard from the frozen plan and require empty
      output.
- [ ] Review the complete diff against the approved design and constraints.

Expected: every proof command exits zero and the production diff guard prints
nothing.

## Out of scope

- Removing `merge()` / `MergeEvent`.
- Hardening `grantAdReward()` in production.
- Extending `VerifyResult`.
- Deploy-drift checks or deploy steps.
- Moving refill into `GameEngine`.
- Any game-rule, scoring, or season change.
