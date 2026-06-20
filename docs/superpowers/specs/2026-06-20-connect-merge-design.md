# Connect-Merge — Daily Mechanic Redesign

**Status:** Approved design — ready for implementation planning
**Date:** 2026-06-20
**Author:** Design session (brainstorming)
**Replaces:** The current free-drag pairwise merge daily.

---

## 1. Problem & goal

The current daily is a deterministic 5×5 merge puzzle where a "move" is dragging
one tile onto any other tile of the same tier (`GameEngine.canMerge` checks only
`from.tier == to.tier` — there is **no geometry**). Because any matching pair can
merge from anywhere, position barely matters and the optimal play is almost always
"merge the pairs you have." The result is easy and predictable.

**Goal:** make each turn a genuine spatial-optimization decision that rewards
forward planning and combo-building, increasing the skill ceiling for the
high-score chase — **without breaking the deterministic, replay-verified
competitive daily** that the whole architecture depends on.

The redesign **replaces** the daily mechanic for all players (not a side mode).

## 2. The binding constraint: determinism & fair competition

This is non-negotiable and shapes every decision below.

- Each day's board, drop sequence, and modifiers are derived deterministically from
  the date seed (`DailySeeder`), so every player faces the identical puzzle.
- The `moveLog` is the authoritative input for **server-side replay verification**
  (Phase 2). Any new player choice must be expressible in the move log and
  reproducible on replay, or leaderboards become forgeable.
- Two PRNG streams are preserved: **stream A** (global: board placement, drop tiers,
  modifiers — identical for everyone) and **stream B** (local: landing-cell
  selection among each player's own empty cells).

## 3. Core mechanic — Connect-Merge

A move is **drawing a path through a connected run of same-tier tiles**, which
collapses into one higher tile.

- **Adjacency is orthogonal** (up/down/left/right; no diagonals). Tiles that match
  but are not connected cannot merge until maneuvered together.
- The path is a **simple connected line** (no revisiting a cell); **every tile in
  the path is the same tier**; **minimum length 2** (a 2-chain == today's merge, so
  the game is never less playable than it is now).
- **The result lands on the release cell** (the path endpoint) — the player chooses
  where the new tile sits. The other path cells empty out, then the drop queue
  refills (Section 5).
- **Tier gain is always +1**, regardless of chain length. A 2-chain and an 8-chain
  both yield one tile, one tier up. Chain length pays off in **score**, not tiers.
  This keeps the board readable and creates the central tradeoff: climb steadily
  with short merges, or burn the board for a monster combo score.

Engine impact: `GameEngine.canMerge`/`merge` generalize to a path
(validate: all cells non-null, same tier, tier < `kMaxTier`, orthogonally adjacent
in sequence, no repeats). `hasMergeAvailable` is redefined — see Section 6.

## 4. Scoring & combo model

```
points = 2^(T+1) × comboMultiplier(N)
```

where `T` = merged tier, `N` = chain length. `comboMultiplier` grows
**superlinearly** so length dominates count.

| Chain (tier-2 `4`s) | Result | Multiplier | Points |
|---|---|---|---|
| 2 | `8` | ×1 | 8 |
| 3 | `8` | ×2 | 16 |
| 4 | `8` | ×4 | 32 |
| 5 | `8` | ×7 | 56 |
| 6 | `8` | ×11 | 88 |

- **The 2-chain scores exactly `2^(T+1)` — identical to today's
  `score + (1 << newTier)`.** This is a strict extension, not a rebalance: the
  minimal move is unchanged; everything longer is upside that only skilled play
  unlocks.
- Sample curve `comboMultiplier(N) = 1 + (N-2)(N-1)/2` (integer, deterministic).
  **Exact curve is a playtest tuning knob** in `constants.dart`.
- **v1 combos are within a single move only** (chain length). A cross-move "combo
  streak" multiplier is explicitly deferred to keep v1 balanceable.

**Strategic tension:** a 5-chain scores 56 but only yields one tier-3 tile and
consumes 4 cells of inventory; five separate 2-chains score 40 but climb further.
Every turn weighs score vs. tier progress vs. board space vs. move budget.

## 5. Drops, queue & forward planning

- **Visible drop queue:** the next **3 drop tiers** are shown openly as a permanent
  rail beside the board. This is the planning centerpiece — you build runs because
  you can read what is arriving.
- **Refill tops the board back up to `Difficulty.startingFill` after every move.** A
  collapse of `N` tiles frees `N−1` cells (endpoint keeps the result), so `N−1`
  drops fall in to restore occupancy. Exact generalization of today's "each merge
  frees a cell, each drop fills one."
  - This preserves the entire difficulty system with no rebalancing: Legendary
    (fill 4) stays brutally sparse; Easy (fill 10) gives room for big combos.
- **On-demand deterministic drop stream:** the fixed `kMaxDrops = 39` pre-baked
  list is replaced by an on-demand stream — the tier for `dropIndex` is drawn from a
  dedicated seed-keyed PRNG. Big chains can now consume drops faster than 39
  without an artificial cap; replay still reproduces every drop.
- **Landing positions** stay seed-driven (stream B) and animate in as tiles fall. A
  per-player deterministic landing **preview** is possible but deferred from v1 to
  avoid screen overload.
- **Repurposed ad-hint:** the next tier is now free in the queue, so the
  rewarded-ad hint reveals **further ahead** (drops 4–6) — still a meaningful
  rewarded boost for planners.
- **Pacing payoff:** big combos drain the queue and reshape the board faster, so
  players pace chains against incoming drops rather than spamming max chains.

## 6. End conditions, budget & deadlock

- **Move budget stays:** 30 collapses/day; one move == one collapse of any length.
  The ad-continue economy (`kAdMoveReward`, `kMaxAdContinuesPerDay`) is untouched.
  Exact count is a tuning knob (each move now does more; 30 is a safe start).
- **Out-of-moves** ends the day (unchanged).
- **Deadlock redefined:** `hasMergeAvailable` becomes "do any two *orthogonally
  adjacent* tiles share a tier (below the cap)?" Because the board tops up each
  move, real deadlock means the player genuinely stranded their tiles — a fair,
  skill-based failure (same board for everyone). Deadlock remains non-ad-revivable.

## 7. Daily variety (the constraints dynamic)

All modifiers are seed-derived static geometry (never dependent on player choice),
so they are identical for every player and replay-safe.

**v1:**
- **Wall cells** — a few seed-placed blocked cells that hold no tile and **break
  paths**. Starting-fill tiles place among non-wall cells. Walls can split the
  board into pockets, so careless play can strand same-tier tiles with no
  orthogonal route between them — interacting with the redefined deadlock to
  produce most of the "less predictable" feeling.
- **Daily objective** — a seed-chosen bonus goal (e.g. "land a 5-chain," "reach
  tier 8," "collapse a chain through the center") granting bonus score/coins when
  met. Gives each day a headline challenge and leaderboard talking point.

**v1.1 fast-follow:**
- **Bonus-multiplier cells** — seed-marked cells that multiply a collapse routed
  through them (routing temptation). Lowest-risk addition.

**v1.2 fast-follow (highest balancing risk — ships only after the live economy is
proven):**
- **Locked / decaying tiles** — tiles that must be chained N times to free, or
  decay over turns.

**Deferred:** cross-move combo streak; per-player landing-cell preview;
diagonal-adjacency days.

## 8. Determinism, replay & migration

- **Move log:** `MergeEvent {from, to}` → **`ChainEvent {path: [cell indices]}`**
  (ordered, length ≥ 2). The old merge is a 2-element path — a strict
  generalization. `ContinueEvent` is unchanged.
- **Replay reconstruction** stays fully deterministic. From
  `seed + ordered ChainEvents + ad-continues`:
  1. Seed derives all static content: initial board, walls, bonus/locked cells,
     daily objective, golden set, the on-demand drop-tier stream, landing stream B.
  2. Each `ChainEvent` re-applies identically: validate path → collapse to endpoint
     at +1 tier → score with combo multiplier → draw `N−1` top-up drops (tiers from
     the drop stream, cells from stream B).
- **Stronger anti-cheat:** a `ChainEvent` path encodes geometry, so the server
  re-checks every step is orthogonally adjacent, same-tier, simple, and clear of
  walls. A forged path that does not physically exist on the seeded board is
  rejected. The richer move *is* the verification.
- **Undo survives unchanged in shape:** `_rebuildLandingTo(dropIndex)` still works
  — `dropIndex` now jumps by `N−1` per move instead of 1, but the
  rebuild-by-replay technique is identical. Undo pops the whole chain (board +
  landing + moveLog) atomically.
- **Migration (gentle — it's a daily):**
  - Bump a **game/seed version**. On load, an in-progress snapshot in the old
    format is discarded and the day starts fresh under new rules.
  - **Meta-progression is preserved** — coins, cosmetics, XP, almanac, streaks,
    achievements do not depend on the mechanic and carry over untouched.
  - `BoardState`/`Tile` gain **additive** fields (walls, locked/decay state)
    following the existing migration-free `golden`-flag pattern.

## 9. Leaderboards

- **Hard reset.** Active leaderboards are wiped and start empty under the new
  mechanic, since Connect-Merge produces a different score distribution that is not
  comparable to old scores.
- Optional (not required for v1): archive old top scores as a static "Hall of Fame"
  for posterity.

## 10. UI / UX

Portrait layout:

```
┌──────────────────────────────────┐
│  ◷ 30        SCORE 1,240          │  HUD: moves left, score
│  🎯 Land a 5-chain     ▓▓▓░░ 3/5  │  daily objective + progress
├──────────────────────────────────┤
│     ┌────┬────┬────┬────┬────┐    │
│     │ 4● │ 4● │ ▩  │  2 │  8 │    │  ▩ = wall cell
│     ├────┼────┼────┼────┼────┤    │
│     │ 4● │ 4◎ │  . │  2 │  . │    │  ● = in current path
│     ├────┼────┼────┼────┼────┤    │  ◎ = release cell (result lands here)
│     │  2 │  . │  8 │  . │ 16 │    │
│     └────┴────┴────┴────┴────┘    │
│                                    │
│   NEXT ▸   [4]  [2]  [8]           │  visible drop queue (next 3 tiers)
└──────────────────────────────────┘
              ⌁ ×4   +32              live chain badge, follows finger
```

**Gesture** (replaces drag-one-onto-another):
- Press a tile to start a path; drag across orthogonally-adjacent same-tier tiles to
  extend it. Each valid cell glows; a connecting line threads through them. Drag back
  over the previous cell to un-pick it (reroute without lifting).
- A **live badge tracks the finger**: `⌁ ×N  +points` — current length and projected
  score, so the combo is visible before committing.
- **Release** collapses onto the last cell. Length-1 cancels (no accidental moves).
- **Escalating haptics:** a tick per link, a thunk on collapse, a flourish for 5+
  chains (today already calls `HapticFeedback.mediumImpact()` on merge).

**Implementation note:** a contained swap in `board_widget.dart` — the
`Draggable`/`DragTarget` layer is replaced by a single `GestureDetector`
(`onPanStart`/`onPanUpdate`/`onPanEnd`) that hit-tests the finger to the cell grid
using the existing `offsetFor(index)` / `cell` / `gap` math. The `AnimatedPositioned`
tiles keyed by `tile.id` are unchanged, so collapse-to-endpoint animation comes
nearly for free. Walls are non-interactive `GridCellWidget`s with a distinct style.

**Accessibility:** existing `colorblindMode` per-tier patterns carry over; the path
also reads as shape/line, not just color.

## 11. Touched code (orientation, not exhaustive)

- `lib/domain/constants.dart` — combo curve, drop-stream config, wall/objective
  tunables, game-version constant.
- `lib/domain/engine/game_engine.dart` — path validation, chain collapse, combo
  scoring, multi-drop refill, redefined `hasMergeAvailable`.
- `lib/domain/engine/daily_seeder.dart` — on-demand drop stream, wall placement,
  daily-objective selection, placement among non-wall cells.
- `lib/domain/models/board_state.dart`, `tile.dart`, `move.dart` — `ChainEvent`,
  additive wall/modifier fields, versioned snapshot.
- `lib/application/game_cubit.dart` — chain move handling, generalized undo,
  objective tracking, completion hooks.
- `lib/presentation/widgets/board_widget.dart` — path gesture, highlighting, live
  badge, wall rendering.
- New/updated UI for the drop-queue rail and objective banner.
- Leaderboard service / schema — versioning + hard reset.

## 12. Tuning knobs (open, for playtest)

- `comboMultiplier(N)` curve.
- Move budget (keep 30 or reduce).
- Wall count per difficulty; objective set and rewards.
- Drop-tier band shape under the new refill cadence (`dropCap`).

## 13. Testing strategy

- **Engine unit tests:** path validation (adjacency, same-tier, simple-path, wall
  rejection, length bounds); collapse correctness (endpoint placement, +1 tier,
  freed cells); combo scoring at each N; redefined deadlock detection; multi-drop
  refill counts and determinism.
- **Determinism/replay tests:** a recorded `ChainEvent` log replays to the identical
  board and score from seed; forged/illegal paths are rejected.
- **Cubit tests:** chain move flow, generalized undo (board + landing + log atomic),
  objective completion, out-of-moves/deadlock transitions, snapshot
  version/migration (old snapshot discarded, meta preserved).
- **Widget tests:** path gesture builds/un-picks correctly; release collapses;
  length-1 cancels; walls non-interactive; colorblind patterns render.

## 14. Non-goals (v1)

- Cross-move combo streak multiplier.
- Per-player landing-cell preview.
- Diagonal adjacency.
- Locked/decaying tiles (v1.2) and bonus-multiplier cells (v1.1).
- Leaderboard archive/Hall of Fame (optional, later).
