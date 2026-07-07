# Ascending Chain Merge — Design

Date: 2026-07-07
Status: Approved (pending spec self-review)

## Summary

Today, Connect-Merge chains (the drag-to-connect mechanic) only collapse when
every tile in the dragged path shares the exact same tier. This spec relaxes
that rule: a chain may also **ascend** — step from one tier to the next
(never skip, never descend) as the drag continues, collecting runs of
same-tier tiles at each level before stepping up. Same-tier-only chains
remain fully valid (a "flat" chain is just a zero-ascend case of the new
rule).

Example valid path: `tier1, tier1, tier1, tier2, tier2, tier3` (three runs,
two ascend points). Example invalid paths: `tier2, tier1` (descend),
`tier1, tier3` (skips tier2).

## Core rule change

`GameEngine.isValidChain` (lib/domain/engine/game_engine.dart:136-152)
changes from "all tiles share one tier" to a per-step check walked in drag
order: for consecutive path entries `prev -> cur`, `cur.tier - prev.tier`
must be `0` or `1`. Any other delta (negative, or `>= 2`) invalidates the
whole chain. Orthogonal-adjacency and no-repeat-cell checks are unchanged.

Because the path is now non-decreasing by construction, `path.last` is
always the chain's peak tier. The existing collapse rule — "the endpoint
becomes tier+1" (`collapseChain`, game_engine.dart:168-189) — is unchanged in
meaning: it was already "one tier above the tile that anchors the collapse,"
and that tile is now always the peak.

The `kMaxTier` cap check moves from "the first tile's tier" (valid today only
because the chain is uniform) to "the last tile's tier" (now the chain's
highest, and the only tile whose `+1` result matters for the cap).

## Scoring — ascend bonus

The base chain score formula is unchanged:

```
comboScore(mergedTier, chainLength) = (1 << (mergedTier + 1)) * comboMultiplier(chainLength)
```

where `mergedTier = path.last`'s tier, exactly as today.

A new **additive** bonus is layered on top, firing once per ascend
transition in the path (each index `i > 0` where
`tier(path[i]) == tier(path[i-1]) + 1`):

```
ascendBonus(intoTier) = 1 << intoTier
```

Total chain score:

```
score += comboScore(mergedTier, path.length)
       + sum(ascendBonus(intoTier) for each ascend transition in path)
```

Example: chain `[t1, t1, t2, t2, t3]` (5 tiles, ascends into tier 2 and into
tier 3) scores `comboScore(3, 5) + ascendBonus(2) + ascendBonus(3)` =
`comboScore(3, 5) + 4 + 8`.

`ascendBonus` is a small pure function living alongside `comboMultiplier` in
`lib/domain/constants.dart` (and mirrored in
`supabase/functions/_shared/constants.ts`). `collapseChain` computes the
ascend total by walking the path once (same pass used to validate/derive
tiers) and adds it to `score` alongside the existing combo term.

## Supporting systems (required consequences, not new choices)

1. **Legacy pairwise API** — `GameEngine.canMerge`/`merge`
   (game_engine.dart:13-19) gets the same delta rule: legal when
   `to.tier - from.tier` is `0` or `1` and `to.tier < kMaxTier`. `merge()`'s
   body is unchanged (it already only reads `to.tier`, the destination/higher
   tile). Not reachable from the shipped UI today, but kept consistent with
   the chain rule since it's exercised directly by unit tests.

2. **Deadlock detection** — `hasMergeAvailable`
   (game_engine.dart:93-110) currently flags a legal move only when two
   orthogonal neighbors share a tier. It must also flag a neighbor pair
   whose tiers differ by exactly 1, provided the higher of the two is below
   `kMaxTier` — otherwise a board with only ascend-moves available would be
   wrongly reported as deadlocked. Implemented as a small `_pairMergeable(a,
   b)` helper: `delta = |a.tier - b.tier|; delta <= 1 && max(a.tier,
   b.tier) < kMaxTier`.

3. **Drag UI** — `_canExtend` (lib/presentation/widgets/board_widget.dart:55-64)
   currently compares each candidate cell's tier against the *first* tile in
   `_path` (`headTier`). It must instead compare against `_path.last`'s tier
   and accept delta `0` or `1`, mirroring `isValidChain` exactly so the UI
   never allows a drag the engine would then reject. The existing
   `t.tier >= kMaxTier` guard on the candidate cell itself is unchanged (a
   max-tier tile can never validly appear in any chain, flat or ascending,
   since the chain is non-decreasing).

4. **Ascend visual cue** — the current path-highlight
   (board_widget.dart:152-163) applies one fixed white `BoxShadow` to every
   tile in `_path`. Tiles that represent an ascend point (tier one higher
   than the previous entry in `_path`) get an amber-toned glow instead of
   white; same-tier segments (including the chain's first tile) keep the
   existing white glow.

## Server-side mirror + leaderboard season

The Dart engine (`game_engine.dart`) and the Supabase Edge Function's
hand-maintained TypeScript port (`supabase/functions/_shared/engine.ts`) are
two independent implementations of the same rules, kept in sync by hand
today. This change must land in both in the same release:

- `isValidChain` (engine.ts:81-99) gets the identical per-step delta check.
- `comboScore`/`collapseChain` (engine.ts:102-132) get the identical
  ascend-bonus addition, with `ascendBonus` added to
  `supabase/functions/_shared/constants.ts` alongside the Dart mirror.
- `kLeaderboardSeason` bumps from `2` to `3` in both
  `lib/domain/constants.dart:138` and
  `supabase/functions/_shared/constants.ts:109`. This cleanly segments
  pre-change and post-change scores on the same leaderboard, consistent with
  how the season mechanism was used for the original Connect-Merge relaunch.
  No new migration is needed — the `scores` table and all three leaderboard
  RPCs (`leaderboard`, `friends_leaderboard`, `leaderboard_period`) already
  take `season` as a parameter (added in `0006_connect_merge_season.sql`), so
  this is a pure constant bump.

## Testing

- Update existing Dart tests that assert same-tier-only behavior for
  `isValidChain`/`canMerge`.
- Add new Dart test cases: ascend-by-1 valid; descend invalid; skip-tier
  (delta >= 2) invalid; mixed run-then-ascend chains (e.g. `[t1,t1,t2,t2,t3]`);
  cap behavior when the peak tile is at `kMaxTier`; ascend-bonus score math
  for single- and multi-ascend chains; `hasMergeAvailable` correctly finds an
  ascend-only move; `_canExtend`-equivalent logic in widget tests if any
  exist.
- Mirror the same new cases in `supabase/functions/_shared/engine.test.ts`.

## Out of scope

- No cap on the total "span" of a single ascend chain (e.g. `tier1` through
  `tier8` in one drag is allowed if board geometry permits it). No such limit
  was requested; the 5x5 grid already bounds practical chain length.
- `ChallengeRule.longChainsOnly` and `comboRush` require no changes — both
  operate purely on `path.length`, independent of tier composition.
- Golden-tile bonus, XP/almanac (`highestTier`), and daily objective progress
  are all read off post-collapse board state and are unaffected by this
  change.
- No further UI polish beyond the amber ascend glow (e.g. connector icons,
  animations) — deferred to a future pass if desired.
