# GameEngine Refill and Tier-Step Single-Sourcing — Design

Date: 2026-07-16
Status: Approved (frozen after five rounds of adversarial review)

## Summary

Connect Merge currently expresses the ascending chain-step rule and post-merge
refill policy in several places in each language. This design gives each rule
one implementation per language while preserving every board, PRNG read point,
score, move log, and verifier outcome. It also makes rewarded continues enforce
the same eligibility predicates as the TypeScript verifier and prevents two
overlapping callbacks from granting twice.

Work is split into two proof-separated phases. Phase A is a pure refactor and
must regenerate the committed golden-vector fixture byte-for-byte. Only after
that gate passes may Phase B remove the stale generator workaround and
force-regenerate the fixture to restore the historical ascend-only board shape.

## Tier-step rule

Dart adds `GameEngine.canFollow(int prevTier, int nextTier)`, returning true
only for an equal-tier or ascend-by-one step. `isValidChain`, `canMerge`, the
private tier-number `_pairMergeable`, and `BoardWidget._canExtend` all route
through it.

TypeScript adds dependency-free tier-number predicates to `constants.ts`:
`canFollow(prevTier, nextTier)` and `pairMergeable(aTier, bTier)`. The latter
orders its arguments into lower/higher tiers, calls `canFollow`, and enforces
the maximum-tier cap. `engine.ts` and `seeder.ts` import these predicates and
delete their private copies. Lockstep comments in Dart and TypeScript name the
mirrored surface explicitly.

This is a structural refactor only. Equal steps, ascending steps, descending
steps, skipped tiers, and the cap retain their existing results.

## Refill rule

Dart adds this pure engine entry point:

```dart
static BoardState refill(
  BoardState board, {
  required int targetFill,
  required int Function(int dropIndex) tierAt,
  required Prng landing,
  Set<int> goldenDrops = const {},
})
```

The loop body moves verbatim from `GameCubit.playChain`. Every iteration reads
the current board's `dropIndex` independently for `tierAt` and the golden-drop
membership check before applying the drop. `GameCubit` supplies the existing
seeder callback and remains responsible for orchestration and persistence.

TypeScript exports `refillBoard(board, targetFill, tierAt, landing)` from
`engine.ts`. Both `verifyRun` and `verifyRunChallenge` call it and delete their
inline loops. Its documentation names `GameEngine.refill` and the deliberate
Dart-only golden flag, which is cosmetic/economy state excluded from replay.

## Rewarded-continue safety

`GameCubit.grantAdReward` first returns unless `canOfferAd` is true. A private
`_grantingAd` flag closes the asynchronous window between checking eligibility
and saving the snapshot: it is checked before work, set immediately before the
`try`, and cleared in `finally`. The successful state transition and move-log
entry remain unchanged.

The guard covers each existing predicate independently: result-screen state,
`outOfMoves`, remaining continue allowance, and a live merge. A concurrent
double call records exactly one continue.

## Proof strategy

Each production task follows red-green TDD. Dart tests cover `canFollow`, every
refill branch and read-order/golden behavior, each ad predicate, and concurrent
callbacks. TypeScript tests cover both shared predicates and refill branches.

Phase A then runs `flutter analyze`, the full Flutter suite, and the full frozen
Deno suite against the untouched fixture. A normal `UPDATE_GOLDENS=1` run must
leave `golden_vectors.json` byte-identical, proven by `git diff --exit-code`.
Any difference is a behavior regression and blocks Phase B.

Phase B removes `_hasAdjacentSameTier` and its challenge-date filter, adds a
generator assertion that at least one initial board has an ascend pair and no
same-tier pair, and force-regenerates. Both full suites then prove the new
policy fixture is accepted by both engines.

## Documentation and release boundary

`CLAUDE.md` and `AGENTS.md` name `canFollow`, Dart `refill`, and TypeScript
`refillBoard` as dual-engine lockstep surfaces. `GameCubit.playChain` documents
that refill policy belongs to the engine.

Deployment, runtime smoke tests, season changes, and CI changes are outside
this implementation. The reviewer owns deployment after sign-off.

## Out of scope

- Removing `GameCubit.merge`, `GameEngine.merge`, `canMerge`, or `MergeEvent`.
- Extending `VerifyResult`.
- Changing scoring, seeded generation rules, or `kLeaderboardSeason`.
- Adding dependencies, abstractions, deployment code, or CI workflows.

