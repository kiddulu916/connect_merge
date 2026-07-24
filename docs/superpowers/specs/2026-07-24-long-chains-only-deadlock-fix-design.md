# Long Chains Only — Deadlock Fix — Design

Date: 2026-07-24
Status: Implemented

## Summary

The daily Challenge rule `ChallengeRule.longChainsOnly` rejects any chain
shorter than 3 tiles (`game_cubit.dart`'s `playChain` guard), but nothing else
in the engine knew that minimum existed. `GameEngine.hasMergeAvailable` /
`evaluateStatus` only checked whether *any* 2-tile mergeable pair existed, and
`GameEngine.refill` only guaranteed a 2-chain before it stopped topping up the
board. Once the board's only remaining mergeable adjacencies were 2-chains,
the rule rejected every move the player tried, but the engine still reported
`GameStatus.playing` forever — a soft-lock, not a real ending. The TS replay
verifier (`engine.ts`) carried the identical gap, so this was a shared spec
hole, not client/server drift.

This spec makes the engine aware of each rule's minimum legal chain length
everywhere that decides "is this board/run playable" — initial board
generation, post-move refill, and end-of-run status — so a run only ever
truly deadlocks once no chain of the required length exists anywhere on the
board. `longChainsOnly` also gets a denser starting board so there's more
material to work with before that can happen.

Full grill + adversarial-review trail (two rounds of Codex review, findings
accepted/rejected with reasoning) lives in `PLAN.md` / `PLAN-REVIEW-LOG.md` at
the repo root as of this change (the `grill-me-codex` skill's working
artifacts — since overwritten by later uses of that skill, see git history
for this commit if they've since been replaced).

## Core rule change

Added `ChallengeRule.minChainLength` (`lib/domain/models/challenge_rule.dart`,
mirrored as `minChainLengthFor` in `constants.ts`): every rule defaults to
`2` (the pre-existing baseline — a no-op change for every rule except the one
below), and `longChainsOnly` overrides to `3`.

Added a rule-aware chain-existence search:
- Dart: `GameEngine.hasChainOfLength(board, minLength)`
  (`lib/domain/engine/game_engine.dart`).
- TS: `hasChainOfLength(cells, gridSize, minLength)` in `constants.ts` (a
  zero-import leaf module, **not** `engine.ts` — `engine.ts` already imports
  `seeder.ts`, so putting the search there and having the seeder's re-roll
  call it back would create an import cycle).

For `minLength <= 2` this is exactly the old `hasMergeAvailable` (byte-for-byte
unchanged behavior for every non-`longChainsOnly` case). For a stricter
minimum, it DFS-searches from every tile along `canFollow`-adjacent, unvisited
neighbours, checking only for a chain of *exactly* `minLength` tiles: since
chain tiers are non-decreasing, any legal chain of length >= `minLength` has a
legal length-exactly-`minLength` prefix (the prefix's peak tier is <= the full
chain's peak tier, so the tier-cap check that passed for the longer chain
passes for the prefix too), so searching for the longer chain is unnecessary.

This search is threaded through five call sites:
1. `GameEngine.refill` / `refillBoard` — the "keep dropping" guarantee now
   targets `minChainLength` instead of a bare 2-chain. This — not the
   deadlock check — is what actually gives players more chances to keep
   playing rather than just ending the game sooner.
2. `GameEngine.evaluateStatus` / `evaluateStatus` — `deadlocked` is only set
   once no chain of the required length remains.
3. `DailySeeder.generate` / `DailySeeder.generate` (TS) re-roll loop — a
   `longChainsOnly` board re-rolls until it already satisfies the rule's
   minimum, not just any 2-chain, so no player starts on a board that can't
   even satisfy its own rule.
4. `GameCubit._finishRun`'s terminal-submission check — the third OR-clause
   (`!hasMergeAvailable`, meant to detect "no ad-continue is actually
   possible, submit now") was the same stale predicate. Also: `terminal` is
   now unconditionally `true` whenever `difficulty == Difficulty.challenge`
   (see below).
5. `GameCubit.canOfferAd` — gated to `false` for all Challenge runs (see
   below).

## Adjacent bug found and fixed: Challenge ad-continues

`canOfferAd` ignored difficulty entirely, so it could return `true` for a
Challenge run (any rule) that ran out of moves with a bare 2-chain still on
the board. But `verifyRunChallenge` (`engine.ts`) rejects **any**
`ContinueEvent` for Challenge mode unconditionally — the server has never
supported Challenge ad-continues. So tapping "continue" on a Challenge board
never extended play; it silently doomed that run's server submission
(`invalid_run`), which surfaces nowhere client-side. This is a **pre-existing
bug affecting every Challenge rule**, not introduced by this change — but
leaving it unfixed while making `_finishRun`'s terminal check rule-aware would
have left an inconsistency: an out-of-moves Challenge board with a legal
chain still present would satisfy none of `_finishRun`'s three original
OR-clauses (not deadlocked, `adContinuesUsed` never grows since no continue
is ever granted, and a legal chain existing makes the rule-aware predicate
false), stranding the run without ever calling `_submit`.

Fix: `canOfferAd` is hard-`false` whenever `difficulty == Difficulty.challenge`
(matching the server exactly), and `_finishRun`'s `terminal` is
unconditionally `true` for Challenge (since it has no continue path at all,
any non-`playing` status is terminal by construction).

## Starting density

`longChainsOnly`'s starting fill switch in `GameCubit.init` (and the
equivalent in `verifyRunChallenge`) now uses `kChallengeDenseFill` (14,
reusing the existing `denseStart` constant) instead of falling through to the
default 8 — more raw material for the stricter chain-length requirement,
matching the existing per-rule override pattern.

## Versioning

- `kLeaderboardSeason` bumped 1 → 2 (both `constants.dart` and `constants.ts`)
  per the repo's standing rule for gameplay/deadlock/seeded-generation
  changes — old and new Challenge scores never mix on a leaderboard.
- `kSnapshotVersion` bumped 3 → 4. Not for the reason first raised in review
  ("so the server can replay it" — the server never reads this client-local
  constant) but because `GameCubit.init` recomputes `_targetFill` from the
  rule-fill switch on *every* load, even when a persisted snapshot's board is
  reused as-is. An in-flight same-day `longChainsOnly` snapshot saved before
  this shipped would otherwise resume on an 8-fill board while `refill`
  silently targets 14 — an internally-inconsistent play history. Bumping the
  version forces a clean restart, matching the constant's own documented
  purpose.
- Deploy-ordering risk (client vs. `submit-score` Edge Function seeing
  different `DailySeeder`/`seeder.ts` logic for the same date) is an accepted,
  pre-existing risk category for this repo's whole dual-engine architecture —
  mitigated by deploying the edge function together with the app release, not
  eliminated by any code change. Async app-store rollout means this can never
  be fully eliminated without new client-version-gating infrastructure, which
  this change does not add (disproportionate scope for a one-rule bug fix;
  every prior gameplay-rule change in this repo carried the same hazard).

## Out of scope

- Making Challenge boards vary per player/account — the daily deterministic
  board (identical puzzle for every player, replay-verified server-side) is
  the core fairness model and was explicitly confirmed as working-as-intended
  during the design discussion.
- Board size or move budget changes, or any other `ChallengeRule`'s behavior.
- `goldenDropIndices()`'s `kMaxDrops`-bounded precompute: a `longChainsOnly`
  run that needs many extra drops chasing a 3-chain could reach a drop index
  beyond the precomputed golden-eligible set, so very late drops simply never
  flash golden. Confirmed cosmetic-only (golden never affects score/replay on
  either side); documented as an accepted, known ceiling
  (`lib/domain/engine/daily_seeder.dart`, `goldenDropIndices` doc comment)
  rather than reworked.
- Structured rejection telemetry for replay-verification failures — a real,
  separate observability gap, not required for this fix's correctness.
