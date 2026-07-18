# Remove Legacy Single-Pair Merge Path — Design

Date: 2026-07-18
Status: Approved (frozen by root `PLAN.md` after three adversarial reviews)

## Summary

The client emits only `ChainEvent` moves. The unreachable `GameCubit.merge()`
producer, its `GameEngine.merge()` transform, and the orphaned pair-only
`GameEngine.goldenBonusFor` helper are removed. `MergeEvent`, its JSON parser
case, and `GameEngine.canMerge` remain as typed legacy-log compatibility and as
the generator for the `reject-legacy-merge-event` golden-vector sentinel.

Accepted gameplay does not change. Tests that pin live undo, replay, economy,
analytics, snapshot, completion, and scoring invariants move to `playChain` or
`collapseChain`; tests that only describe the deleted pair API are removed.

## Migration infrastructure

The undo replay helper first supports both formats. Its `ChainEvent` branch
performs the live lifecycle in order: require a playing board, validate with
`GameEngine.isValidChain`, collapse with `GameEngine.collapseChain`, refill with
`GameEngine.refill`, then call `GameEngine.evaluateStatus`. Existing
`ContinueEvent` handling remains unchanged. The temporary `MergeEvent` branch
is removed only after its final test consumer migrates.

All three seeded-board finders use an oriented two-cell path. They inspect only
orthogonally adjacent cells, try both directions to support ascend-by-one
chains, and assert the returned path passes `GameEngine.isValidChain`.

## Test disposition

Every deleted test is superseded by live chain coverage:

- Delete `undo rewinds board, dropIndex, and moveLog together` after moving its
  full `BoardState.toJson` equality assertion into `undo after a chain restores
  board, score, and drop streams`.
- Delete `a legal merge updates score, spends a move, triggers a drop, and logs
  a MergeEvent`; `playChain collapses a valid 2-path, scores, and tops the board
  back up` covers the live producer.
- Delete `merge: destination becomes tier+1, source empties, scores 2^newTier,
  spends a move`; `collapse: endpoint climbs +1 keeping its id; others empty;
  scores combo` covers the live transform.
- Delete `collapse: a 2-path matches the legacy merge result`; `collapse:
  endpoint climbs +1 keeping its id; others empty; scores combo` and `collapse:
  a flat (same-tier) chain has zero ascend bonus` cover the retained chain
  mechanics and two-path score.
- Delete `goldenBonusFor pays per golden tile consumed`; `playing golden tiles
  fires onCoinsEarned without changing score` and `playing non-golden tiles
  credits nothing` cover live chain economy behavior.

All other affected tests migrate in place. The undo suite retains landing-PRNG
rewind, replay consistency, multiple undo, free/rewarded undo caps, bounded
stack depth, locked-run gating, and golden refund/replay coverage. The cubit
suite retains analytics across a continue, golden and doubled-coin flows, the
mixed `ChainEvent`/`ContinueEvent` snapshot round-trip, and `_completeTier`
completion, streak, analytics, and error-hook coverage. Expected scores and
events are derived from the chosen chain, not copied from the pair API.

The golden/control authoritative-score test is rewritten around
`GameEngine.collapseChain([0, 1])`: golden flags remain cosmetic, score and move
log match the plain control, and the consumed endpoint is not golden.

## Production and documentation changes

Only `GameCubit.merge`, `GameEngine.merge`, and
`GameEngine.goldenBonusFor` are deleted. Live comments describe chain moves,
chain undo frames, and `playChain` completion. `canMerge` documents its sole
remaining consumer, the golden-vector rejection-sentinel generator. The
`MergeEvent` class is labeled legacy and server-rejected while documenting why
its format remains supported.

## Proof

The proof is a clean `flutter analyze`, a green full `flutter test`, a green
focused Flutter golden-vector suite, a green frozen Deno Edge Function suite,
and searches showing no remaining references to the three deleted methods.
The committed fixture and all of `supabase/**` remain unchanged.

## Out of scope

- Changes to `playChain`, undo mechanics, scoring, seeded generation, replay
  rules, or any live gameplay rule.
- Changes to `MergeEvent`, its `merge` parse case, `GameEngine.canMerge`, the
  golden-vector generator or fixture, TypeScript, Supabase, deployment, or the
  leaderboard season.
- Unrelated `merge()` methods on cubits, blocs, or Dart collections.
