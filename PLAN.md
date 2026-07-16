# Plan: Deepen GameEngine — absorb the refill loop and the chain-step rule

_Locked via grill — by Claude + kiddulu916. Revised after Codex round 1._

## Goal

Make the tier-step rule and the refill loop single-sourced per language, with behavior preserved and **proven** by the golden-vector fixture plus targeted branch-parity tests. `GameEngine.canFollow` becomes the one tier-step predicate behind `isValidChain`, `canMerge`, `pairMergeable`, and the widget's drag handler in Dart; its TS mirror lives in `constants.ts` so `engine.ts` **and** `seeder.ts` share it (the seeder's inlined copy is the one that actually drifted in production — 69420db). The refill loop moves from `GameCubit.playChain` into `GameEngine.refill()`; its two TS copies collapse into one exported `refillBoard()`. Plus `grantAdReward()` gains the guard the TS verifier already enforces, and an in-flight guard against double-grant.

## Approach

Work is two phases in one PR: **Phase A** is the pure refactor (fixture must come out byte-identical); **Phase B** is the generator-policy cleanup Phase A unlocks (fixture legitimately changes under the force flag). Per the repo's planning workflow, the dated spec + failing-test→implementation→passing-test→commit task plan under `docs/superpowers/` is written **first**, before any production task.

### Phase A — refactor, behavior frozen

1. **`GameEngine.canFollow` (Dart)** — `static bool canFollow(int prevTier, int nextTier) => nextTier >= prevTier && nextTier <= prevTier + 1;` with a doc comment stating the step rule and TS lockstep.
   Route every Dart tier-step check through it:
   - `isValidChain`: inline delta check → `canFollow(prev.tier, t.tier)`.
   - `canMerge`: `delta >= 0 && delta <= 1 && to.tier < kMaxTier` → `canFollow(from.tier, to.tier) && to.tier < kMaxTier`.
   - `pairMergeable` (inside `hasMergeAvailable`): → `canFollow(lower, higher) && higher < kMaxTier` (symmetric use: lower/higher = min/max of the two tiers).
   - `board_widget._canExtend` line 62 → `GameEngine.canFollow(lastTier, t.tier)`.

2. **`canFollow` + `pairMergeable` (TS) move to `constants.ts`** — rule functions already live there (`comboMultiplier`, `ascendBonus`); placing these two there breaks the seeder↔engine import cycle that forced `seeder.ts` to inline its own copy. **Tier-number signatures, no Tile types**, so `constants.ts` stays dependency-free: `canFollow(prevTier: number, nextTier: number)`, `pairMergeable(aTier: number, bTier: number)`. Dart's private pair check takes tiers the same way for shape parity.
   - `engine.ts`: deletes its private `pairMergeable`, imports both (callers pass `.tier`); `isValidChain` uses `canFollow`.
   - `seeder.ts`: `hasAdjacentMergeablePair`'s inline tier math → shared `pairMergeable`. The predicate that drifted once can no longer drift alone.

3. **`GameEngine.refill` (Dart)** — loop moves verbatim from `game_cubit.dart:360-371`:
   ```dart
   static BoardState refill(
     BoardState board, {
     required int targetFill,
     required int Function(int dropIndex) tierAt,
     required Prng landing,
     Set<int> goldenDrops = const {},
   })
   ```
   Each iteration reads the *current* board's `dropIndex` for both `tierAt` and the golden check — exact read-point preservation. `playChain` calls it with `tierAt: (i) => _seeder.dropTierAt(_dropTier, i)`, keeping `GameEngine` seeder-free.

4. **`refillBoard` (TS, exported)** — `export function refillBoard(board, targetFill, tierAt, landing)` in `engine.ts`; `verifyRun` + `verifyRunChallenge` call it; the two inline copies die. Exported so it's directly unit-testable (Codex round 1); doc comment names the Dart mirror and the deliberately Dart-only golden flag.

5. **`grantAdReward()` guards** — early `if (!canOfferAd) return;` plus an in-flight flag (`_grantingAd`, set in `try`/cleared in `finally`) so two overlapping reward callbacks can't both grant before the first snapshot write lands.

6. **Tests (TDD order per task)** —
   - Dart: `canFollow` (equal/ascend/descend/skip); `refill` (fill-only, merge-top-up, full-board stop, dropIndex read-order, golden flag); `grantAdReward` no-op for each predicate independently — wrong state, not outOfMoves, cap exhausted, **no merge available** — and a concurrent-double-call test proving one continue recorded.
   - TS: `canFollow` + `pairMergeable` cases (the shared predicates ARE the seeder-parity guarantee now — `hasAdjacentMergeablePair` stays private; end-to-end seeder acceptance is pinned by Phase B's required ascend-only vector instead of an unimplementable constructed-board comparison); `refillBoard` unit tests mirroring the Dart refill vectors (fill-only, merge-top-up, full-board, drop-order).
   - All existing suites pass unchanged.

7. **Phase A proof** — `flutter test` + `deno test --frozen supabase/functions/` green with the committed fixture untouched; then `UPDATE_GOLDENS=1` regeneration followed by `git diff --exit-code supabase/functions/_shared/golden_vectors.json`. The fixture is **regression evidence over the recorded runs** (not a proof over all runs — the unit branch-parity tests above cover what the vectors don't); together they justify no season bump. If regeneration diffs in Phase A, the refactor is wrong — fix code, never the fixture.

### Phase B — generator-policy cleanup (separate commit)

8. **Remove the stale `_hasAdjacentSameTier` workaround** from `golden_vectors_test.dart` (lines ~161-164): it filtered challenge dates for the seeder drift fixed in 69420db and now silently narrows coverage. Regenerate with `UPDATE_GOLDENS=1 UPDATE_GOLDENS_FORCE=1` (policy-only change — exactly what the force flag exists for). **Required, not optional**: the generator asserts at least one vector's initial board contains an ascend pair and NO same-tier pair (the historical-regression shape), failing generation loudly otherwise — 2026-07-17 challenge is known to be such a board, so `wallMaze` returning to it satisfies this. Both suites must pass on the regenerated fixture.

### Docs & release

9. **Docs**: dated spec + task plan under `docs/superpowers/` (2026-07-16, written first); update the `game_cubit.dart` refill comment and the CLAUDE.md/AGENTS.md dual-engine sections to name `canFollow`/`refill`/`refillBoard` as the mirrored surface.

10. **Release checklist** (engine.ts + seeder.ts + constants.ts change → the deployed bundle must follow; this drift has shipped twice):
    - Pre-deploy: `deno test --frozen supabase/functions/` green on the merge commit.
    - Deploy: `supabase functions deploy submit-score --project-ref nnoqqchqprfikhabrrjt` (explicit ref — never rely on the locally-linked project). Owner: Claude, immediately after the commit lands on main.
    - Verify bundle: `mcp__supabase__get_edge_function({project_id: "nnoqqchqprfikhabrrjt", function_slug: "submit-score"})` — confirm the returned `engine.ts` contains `refillBoard`, `constants.ts` contains `canFollow`, and the version incremented.
    - Runtime smoke (self-contained, no stored secrets — the project key is `sb_publishable_…`, not a JWT, so a real user token is minted on the spot): (a) `POST /auth/v1/signup` with the publishable `apikey` and a random throwaway email/password — signup is enabled with confirmations off, so this returns an `access_token` immediately; (b) `POST /functions/v1/submit-score` with `Authorization: Bearer <access_token>` + publishable `apikey` and a malformed body — require the **function-generated 422** `{"valid":false,"reason":"invalid_run"}` (proves the new bundle imports, serves, and executes past auth); (c) clean up by calling the repo's own `delete-account` function with the same JWT, then **verify the user is actually gone** (a repeat sign-in with the same credentials must fail — `delete-account` swallows deletion errors, so cleanup is only done when proven). A surviving throwaway user is a release-check failure. If prod signup settings ever diverge from config.toml, the smoke fails loudly at (a) — adapt then, don't skip.
    - Rollback: `git checkout <prev> -- supabase/functions && supabase functions deploy submit-score --project-ref nnoqqchqprfikhabrrjt`.

## Key decisions & tradeoffs

- **TS `canFollow`/`pairMergeable` live in `constants.ts`, not `engine.ts`** — the only placement that lets `seeder.ts` share them without an import cycle; `constants.ts` already holds rule functions. Cost: "constants" hosting predicates is a slight name stretch; benefit: the predicate that actually drifted in prod becomes physically shared.
- **`refillBoard` exported** (reversing the grill's "private" lean) — direct unit tests beat interface purity here; the mirrored surface grows by one deliberate name.
- **`tierAt` callback instead of passing `DailySeeder`** — keeps `GameEngine` seeder-free; same helper shape both languages. Cost: one closure per chain play.
- **Golden flag Dart-only, absent from TS mirror** — cosmetic economy is walled off from replay by design; doc comments name the asymmetry as intent.
- **Two-phase structure** — Phase A's byte-identical fixture proves the refactor; only then does Phase B change vectors under the force flag. Collapsing them would destroy the proof.
- **`merge()` removal deferred** (grill decision): test-migration job, 26 references, and `MergeEvent`/`canMerge` must survive for the golden sentinel anyway.
- **In-flight guard added to `grantAdReward` only** — the one method an external SDK callback drives; no speculative reentrancy guards elsewhere.

## Risks / open questions

- `canMerge`/`pairMergeable` routing must be expression-identical under all inputs (bounds: tier 1..kMaxTier); the unit tests enumerate the edge tiers.
- Phase B's regenerated vectors change fixture dates; if any regenerated vector fails the Deno suite, that's a new cross-language finding to investigate, not to paper over.
- `grantAdReward` guard could surface tests granting from illegal states; fix as test bugs unless one encodes real product behavior — then stop and surface.

## Out of scope

- Removing `GameCubit.merge()` / `GameEngine.merge` / `canMerge` / `MergeEvent` — own PR (grill decision).
- Extending `VerifyResult`, deploy-drift CI guard, scoring/rule/`kLeaderboardSeason` changes.
- Reshaping the fixture beyond Phase B's regeneration.
- Candidates #3–#6 from the architecture review.
