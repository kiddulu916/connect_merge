# Golden Vectors for the Dual-Engine Seam — Design

Date: 2026-07-14
Status: Approved (locked after adversarial review)

## Summary

Connect Merge has two hand-maintained implementations of its deterministic
game rules: the Dart client engine and the TypeScript replay verifier used by
`submit-score`. A legitimate client run is rejected if those implementations
drift. This design makes the source-level parity invariant executable by
committing one deterministic JSON fixture of real `GameCubit` runs and
asserting it in both test suites and CI.

Deployed-bundle drift is a separate operational concern and remains out of
scope.

## Fixture contract

The single fixture lives at
`supabase/functions/_shared/golden_vectors.json`. It contains:

- `_readme`: the regeneration policy;
- `season`: the current `kLeaderboardSeason`;
- `baseDate`: the fixed UTC date used by the generator;
- `vectors`: honest runs with date, difficulty, optional challenge rule,
  serialized `MoveEvent`s, and expected validity, score, highest tier, and
  Dart status;
- `rejections`: deliberately invalid runs with expected validity `false`.

There is no generation timestamp. JSON keys, array order, indentation, and the
trailing newline are stable, so regenerating unchanged rules is byte-for-byte
reproducible.

Both suites hardcode the complete honest and rejection scenario-name sets and
assert exact set equality. Coverage therefore cannot be reduced by editing the
fixture alone. Both also compare the fixture season with their own
`kLeaderboardSeason` constant.

## Dart assertion and generator

`test/domain/engine/golden_vectors_test.dart` is both the normal assertion
test and the guarded generator.

Normal execution loads every honest vector and replays it through
`GameCubit`, backed by `InMemoryStorageService`. It checks challenge-rule
derivation before replay and checks final score, highest tier, and status.
Golden-tile economy effects cannot affect the asserted score.

With `UPDATE_GOLDENS=1`, the test drives deterministic scripted runs and writes
the fixture. The play policy scans cells in index order and takes the first
legal chain. Standard rules use two-tile chains; `longChainsOnly` and
`comboRush` use the first legal three-tile chain so their vectors distinguish
the rules. Search is bounded, and a playing board with no qualifying chain
produces a valid prefix run.

The generator searches challenge dates in `[baseDate, baseDate + 60 days)` and
fails with the missing scenario names if it cannot produce the complete
matrix. Ad continues are granted only after `canOfferAd`, matching the UI.

Before writing, the generator compares the complete semantic `vectors` and
`rejections` payload with the committed fixture. A changed payload with an
unchanged season is rejected. `UPDATE_GOLDENS_FORCE=1` is the explicit escape
hatch for policy-only regeneration; rule changes still require bumping
`kLeaderboardSeason` in both languages.

## Honest-vector coverage

The exact coverage matrix contains:

- Easy, Medium, Hard, and Legendary on `baseDate`;
- all six challenge rules within the 60-day window;
- a `comboRush` run containing a chain of at least three tiles;
- a non-empty `longChainsOnly` run containing an accepted three-chain;
- a standard run that spends the base budget and all three ad continues;
- a standard run that ends `outOfMoves` after the base budget with no continue.

Deadlock is deliberately excluded because the refill guarantee makes it
unlikely under this bounded policy and existing unit tests already cover it.

## Rejection coverage

Rejection sentinels cover only gaps not already pinned by
`engine.test.ts`. Each is built from replayed Dart board state, with every
precondition except the targeted server guard asserted:

- a fourth continue after the full three-continue run;
- a legal chain after the standard move budget is exhausted;
- the same post-budget chain for `budgetCut`;
- the same post-budget chain for a non-budget challenge rule;
- an otherwise-legal two-chain under `longChainsOnly`;
- a legacy `{ "type": "merge" }` event on a playing board with legal endpoints.

The Flutter suite checks rejection coverage and fixture shape. The TypeScript
suite performs the rejection replays because `GameCubit` ignores illegal
inputs rather than returning verifier-style failures.

## TypeScript assertion

`supabase/functions/_shared/golden_vectors.test.ts` imports the JSON fixture
directly, requiring no read permission. It checks the season and hardcoded
coverage sets, derives each challenge rule independently, replays honest runs
through `verifyRun` or `verifyRunChallenge`, and compares validity, score, and
highest tier. It then asserts every rejection returns `valid: false`.

`engine.test.ts` remains unchanged and continues to pin lower-level PRNG,
seeder, geometry, scoring, and hand-written rejection behavior.

## Continuous integration

`.github/workflows/test.yml` runs on pushes and pull requests to `main` with
`contents: read` permissions only. The Flutter job runs `flutter analyze` and
`flutter test`; the Deno job runs
`deno test --frozen supabase/functions/`. Tool versions and action revisions
are pinned, caches are enabled, and no secrets or deployment steps are used.

A repository administrator must mark both jobs as required status checks on
`main`; that GitHub setting is intentionally outside repository files.

## Key decisions and tradeoffs

- Reuse `GameCubit` instead of introducing a third Dart verifier.
- Keep one JSON fixture under `_shared` so Deno can import it without
  `--allow-read` and the client/server suites cannot drift onto twin fixtures.
- Assert final outcomes rather than every intermediate board; existing engine
  tests retain the detailed state vectors.
- Use a deterministic first-legal-chain policy instead of exponential
  longest-path search.
- Make coverage names code-owned in both languages rather than fixture-owned.
- Keep all changes outside production code.

## Risks

- `longChainsOnly` may stop early when no three-chain exists; date search and
  the non-empty distinguishing requirement prevent an empty vector.
- A challenge rule might not appear or qualify in the 60-day window; generation
  fails loudly with the missing scenario name.
- Flutter setup adds several minutes to CI.

## Out of scope

- Removing `merge()` or `MergeEvent`.
- Adding a cap guard inside `grantAdReward()`.
- Extending `VerifyResult`.
- Deploy-drift checks or deployment steps.
- Moving the refill loop into `GameEngine`.
- Any rule, scoring, or `kLeaderboardSeason` change.
