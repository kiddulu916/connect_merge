# Phase 2 Server Prerequisites — Connect-Merge Replay Engine

**Status: Phase 2 prerequisite — not a live bug.**

Production currently does NOT call `onSubmitRun` (the `TierSelectScreen` wires
it to `null`), so no live run ever reaches the server today. The items below
MUST be completed before `onSubmitRun` is wired and online daily-score
submission is enabled.

---

## Context

The server-side replay engine lives at:

```
supabase/functions/_shared/engine.ts
```

It is still at the **pre-redesign (pairwise-merge) state** and does not
understand the Connect-Merge move model. Wiring `onSubmitRun` before porting
the engine would allow any client to submit an unverifiable score.

---

## Required Server Changes

### 1. Parse `ChainEvent` (ordered cell-index path)

The client move log now emits `ChainEvent` (an ordered list of cell indices)
instead of the legacy `{from, to}` pair. The server must parse this new event
shape in addition to (or replacing) the legacy `merge`/`continue` events.

### 2. Validate Path Geometry

For each `ChainEvent` path the server must verify:

- All consecutive cell pairs are **orthogonally adjacent** (no diagonals, no
  row wrap-around).
- All cells in the path hold a live tile of the **same tier** that is **below
  `kMaxTier`**.
- The path is **simple** (no repeated cell indices).
- No path cell is a **wall** cell for that date+difficulty.

### 3. Replace Bounded `dropTiers` List with On-Demand Stream

The legacy engine consumed a pre-generated `dropTiers[n]` list of length
`kMaxDrops`. The redesigned client uses an **unbounded on-demand stream**
(`dropTierPrng` / `dropTierAt`) keyed as `"$date:$difficulty:drops"`. The
server must replicate this stream to verify refill tiers rather than indexing a
fixed list.

### 4. Multi-Drop Top-Up Refill (not single drop)

After each `ChainEvent` the client refills the board back up to `startingFill`
occupied cells, applying **one drop per freed cell** (a chain of length L frees
L−1 cells, then the endpoint upgrades, net −(L−1) cells that must each be
refilled). The server must replicate this multi-drop refill logic rather than
applying a single drop per move.

### 5. Spatial `hasMergeAvailable`

The deadlock check is now **spatial**: two orthogonally-adjacent tiles of the
same tier below cap constitute a valid move. Non-adjacent equal-tier tiles do
NOT count. The server must use the spatial check to correctly detect and record
deadlock outcomes.

### 6. `collapseChain` + `comboScore`

The server must implement `collapseChain` (clears all path cells, upgrades the
endpoint) and `comboScore` (`(1 << (tier+1)) * comboMultiplier(len)`) to
reproduce the client's score increments and detect any score-inflation cheat.

### 7. Born-Dead Re-Roll (match client I-1 fix)

`DailySeeder.generate()` now re-rolls the initial placement (consuming further
draws from stream A) until the resulting board has at least one adjacent
same-tier pair (`hasMergeAvailable`). The server seeder **must replicate this
re-roll loop** with the same cap (`maxAttempts = 5000`) and the same
`StateError` on cap-exceeded. Any divergence here will cause the server to
reconstruct a different initial board than the client, failing replay
verification for every affected date.

### 8. Supabase `season` Column Migration + RPC/Edge-Function Filter

Task 17 added `kLeaderboardSeason = 2` (the hard reset constant) and requires
the Supabase `scores` table to carry a `season` integer column. The leaderboard
RPC and Edge Functions must filter by `season = kLeaderboardSeason` so
pre-relaunch scores never appear. This migration and filter must be applied
before the leaderboard goes live, and the `season` value must be submitted with
every score.

---

## Current Production Safety

| Gate | State |
|------|-------|
| `onSubmitRun` is `null` in `TierSelectScreen` | No run reaches the server |
| Server engine is pre-redesign | Would reject / misverify any Connect-Merge run |
| `season` column not migrated | Pre-relaunch scores could leak into leaderboard |

All three gates must be lifted together in Phase 2.

---

## Reference Files

- Client seeder: `lib/domain/engine/daily_seeder.dart`
- Client engine: `lib/domain/engine/game_engine.dart`
- Server engine: `supabase/functions/_shared/engine.ts`
- Constants: `lib/domain/constants.dart` (`kLeaderboardSeason`, `kMaxTier`,
  `kMovesPerDay`, `kMaxDrops`, `comboMultiplier`, `dropCap`)
- Move model: `lib/domain/models/move.dart` (`ChainEvent`)
