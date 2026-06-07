# Merge Loop — Design Spec

**Date:** 2026-06-06
**Status:** Approved (brainstorming complete; ready for implementation planning)
**Platform:** Flutter (Dart 3.x, strict null-safety, `flutter_lints`), iOS App Store + Google Play, single codebase, zero backend.

---

## 1. Concept

Merge Loop is a deterministic daily puzzle. Every player worldwide gets the **same board and the same drop sequence** on a given calendar date. You have a scarce **30-move budget** to climb tiles as high as possible by merging, then you share a Wordle-style emoji result. No accounts, no server — all logic and persistence are local.

---

## 2. Core rules (the domain)

### 2.1 Board & tiles
- Fixed **5×5** grid (25 cells).
- **Tier 0 = empty.** Tiers **1–11** are live tiles, displayed as `2^tier` → **2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048**. Tier 11 (2048) is the cap.
- Each live tile carries a **stable `id`** (independent of tier) so the UI can track it across moves for animation.

### 2.2 The move loop
A "move" is a **successful merge**. On each move:
1. Player drags a tile onto **any identical-tier tile anywhere on the board** (no adjacency requirement). The two fuse into one tile of **Tier + 1** at the destination cell; the source cell becomes empty.
2. **Score += `2^(new tier)`**.
3. `movesRemaining -= 1`; `HapticFeedback.mediumImpact()` fires.
4. **Exactly one new tile drops** into an empty cell from the day's deterministic queue.

Dragging onto an **empty or non-matching** cell is a **no-op** — no move is consumed, no drop occurs. Repositioning without merging is not allowed. "30 moves" therefore means "30 merges."

### 2.3 Board population invariant
Each merge frees one cell (2 tiles → 1) and each drop fills one cell, so **board population is constant** for the whole day, equal to the **starting fill**.

- **Starting fill = 8 tiles** (constant occupancy). Exposed as a single named constant `kStartingFill` for post-playtest tuning.
- Because population (8) is well below the 17 empty cells, a drop **always** has a landing cell available.

### 2.4 End-of-day conditions
The board freezes and the day ends when **either**:
- **`movesRemaining == 0`**, or
- **Deadlock:** no legal merge exists — i.e. every occupied tile has a unique tier (no duplicate tiers anywhere on the board).

Deadlock is genuinely reachable: there are only 11 live tiers, and with 8 tiles the board can become all-unique. As the day progresses and the drop band widens (§2.5), distinct high singletons accumulate, raising deadlock risk — a real, skill-avoidable failure state.

> Math note: with anywhere-reach merges, a board is dead **only** when all occupied tiles are distinct tiers. That requires `occupied ≤ 11`. A starting fill > 11 would make deadlock impossible (pigeonhole). 8 keeps deadlock a balanced threat.

### 2.5 Determinism model
A single seeded PRNG drives the entire day. **`Random()` is never used** (Dart's seeded `Random` is not guaranteed reproducible across platforms/SDK versions).

- **Seed:** `SHA-256(YYYY-MM-DD)` (via `crypto`), folded into a 32-bit integer.
- **PRNG:** **Mulberry32** — tiny, fast, fully reproducible. Ships in-repo (`prng.dart`).
- **Derived in fixed order from the stream:**
  1. **Initial board** — 8 tiles, each with a tier and a cell, placed deterministically.
  2. **Drop queue** — an ordered list of **tile tiers** `drop[0], drop[1], …`. The drop tier is drawn from a band `[1 .. cap(n)]` where **`cap(n)` widens by drop index `n`** (steps up every few drops, clamped). Keying scaling to `n` — **not** to board state — is mandatory: it keeps the item sequence byte-identical for all players regardless of how they played. (Keying to a player's highest tile would desync players.)
  3. **Landing cell** — when `drop[n]` is placed, the cell is chosen by the next PRNG draw mapped onto **that player's current empty cells**. The *item tier* is global; *where it lands* adapts to the local board. This is the only board-dependent piece and is what "same upcoming drops" honestly allows.

### 2.6 Goal
Maximize **score** and **highest tier reached** within the move budget, then share. No explicit win target — it's a daily high-score chase.

---

## 3. Architecture (DDD, four layers)

Dependencies point inward: presentation → application → domain. Infrastructure plugs in at the edges. The **domain layer has zero Flutter/IO imports** and is fully unit-testable.

```
lib/
├── domain/                      # pure Dart
│   ├── models/
│   │   ├── tile.dart            # Tile{ id, tier }
│   │   ├── board_state.dart     # grid (List/Matrix of Tile?), moves, score, status, highestTier
│   │   └── game_status.dart     # enum: playing | outOfMoves | deadlocked
│   └── engine/
│       ├── prng.dart            # Mulberry32 deterministic stream
│       ├── daily_seeder.dart    # date → seed → initial board + drop generator
│       └── game_engine.dart     # pure functions: merge, applyDrop, isDeadlocked, scoring
├── application/
│   ├── game_state.dart          # GameInitial | GamePlaying | GameOverShowScore | GameAdRewardGranted
│   └── game_cubit.dart          # orchestrates engine + storage + ad rewards
├── infrastructure/
│   ├── storage_service.dart     # Hive: completion flag, saved board, lifetime stats
│   └── ad_service.dart          # google_mobile_ads: init, banner, rewarded lifecycle
├── presentation/
│   ├── screens/
│   │   ├── game_screen.dart
│   │   └── score_share_screen.dart
│   └── widgets/
│       ├── board_widget.dart
│       ├── grid_cell_widget.dart
│       ├── moves_counter.dart
│       ├── rewarded_dialog.dart
│       └── banner_slot.dart
└── main.dart
```

### 3.1 Engine design
Pure functions return **new** `BoardState`s (no mutation). Example surface:
- `BoardState merge(BoardState s, {required Tile from, required Tile to})`
- `BoardState applyDrop(BoardState s, int dropTier, Prng prng)` — picks landing cell among empties.
- `bool isDeadlocked(BoardState s)` — true if no two tiles share a tier.
- Scoring folded into `merge` (`+= 1 << newTier`).
- `daily_seeder` exposes `BoardState initialBoard(String date)` and a drop generator yielding `cap(n)`-bounded tiers.

### 3.2 Application (Cubit) flow
- `init()` → check Hive for today's completion. If complete → emit `GameOverShowScore` with stored result. Else restore a saved in-progress board or seed a fresh one → `GamePlaying`.
- `merge(from, to)` → run engine, persist board, re-evaluate end conditions; emit `GamePlaying` or `GameOverShowScore` (and mark completion in Hive).
- `requestAdContinue()` / `grantAdReward()` → on reward callback, `movesRemaining += 3`, decrement the daily ad-continue allowance, resume `GamePlaying` (emit a transient `GameAdRewardGranted` for UI feedback).

---

## 4. Presentation & feel

- **Board rendering:** a `Stack` of **`AnimatedPositioned`** tiles **keyed by `id`**, floating above a static `CustomPainter` 5×5 backing grid. Chosen over `GridView.count` because it is the only approach that animates merge-slide and drop-fall smoothly (Flutter can only tween a tile's position if it can identify it across rebuilds via its key).
- **Input:** `Draggable` + `DragTarget` per cell. Matching-tier drop → merge; otherwise spring back.
- **Feedback:** `AnimatedScale` pop on the merged tile; `AnimatedPositioned` slide for the source tile and the new drop; `HapticFeedback.mediumImpact()` per merge. Target 60fps, implicit animations only, no Flame.
- **Screens:**
  - `GameScreen`: moves counter, live score, board, persistent bottom **banner slot**.
  - `ScoreShareScreen`: final board snapshot, score, highest tile, **Share** button, countdown to next calendar day. Reached directly on relaunch if today is already complete.

---

## 5. Monetization & sharing

### 5.1 Rewarded video
- Trigger: `movesRemaining == 0` **and** a legal merge still exists.
- Offer: **+3 moves** for one rewarded video, via `rewarded_dialog`, with clean `google_mobile_ads` callbacks isolated in `ad_service`.
- Policy: up to **3 ad-continues per day** (`kMaxAdContinuesPerDay = 3`, tunable). Deadlock is **not** ad-revivable (no pairs to merge), so the offer never appears on the deadlock path.

### 5.2 Banner
- Persistent bottom slot, **structurally reserved** so layout never reflows when the ad loads.

### 5.3 AdMob configuration
- Ship with Google's **official test unit IDs** behind a single `AdConfig`; real IDs are clearly-marked constants swapped before release. No live AdMob account required to build or run.

### 5.4 Emoji share engine
- `ShareGridBuilder` builds a Wordle-style block and copies it via `Clipboard.setData`.
- Format:
  ```
  Merge Loop YYYY-MM-DD
  Score <n> · Best 🟪<value> · <used>/30 moves
  <5×5 emoji grid>
  ```
- Tier → color band mapping (final board): ⬛ empty → 🟦 low → 🟩🟨 mid → 🟧🟥 high → 🟪 max. Exact band thresholds defined as a constant table.

---

## 6. Dependencies (`pubspec.yaml`)

`flutter_bloc`, `hive`, `hive_flutter`, `google_mobile_ads`, `path_provider`, `crypto`. Dev: `flutter_lints`, `hive_generator`/`build_runner` only if typed adapters are used (otherwise primitive maps).

**Storage:** **Hive** (chosen over Isar) — simplest key-value fit, smallest footprint, matches the spec's `hive_flutter`. Stores: today's completion flag + result, in-progress board snapshot, lifetime stats (streak, best score).

---

## 7. Tunable constants (single source of truth)

| Constant | Value | Purpose |
|---|---|---|
| `kGridSize` | 5 | board dimension |
| `kMaxTier` | 11 | cap (2048) |
| `kMovesPerDay` | 30 | daily move budget |
| `kStartingFill` | 8 | constant board population / deadlock pressure |
| `kAdMoveReward` | 3 | moves granted per rewarded video |
| `kMaxAdContinuesPerDay` | 3 | ad-continue allowance |
| drop `cap(n)` schedule | steps up every few drops, clamped | scaling drop difficulty |

---

## 8. Acceptance criteria

1. Same `YYYY-MM-DD` → identical initial board and identical drop-tier sequence across runs/devices (unit-tested by feeding fixed dates).
2. A merge produces Tier+1, adds `2^(new tier)`, spends one move, and triggers exactly one drop into an empty cell.
3. Board population stays constant at 8 throughout a day.
4. Day ends at 0 moves or on a duplicate-free board; completion persists; same-day relaunch routes straight to the score screen.
5. Rewarded video grants +3 moves, capped at 3 continues/day, never offered on a deadlocked board.
6. Banner slot is reserved and never causes layout shift.
7. Share output copies the date, score, best tile, moves used, and a 5×5 emoji grid to the clipboard.
8. Domain layer compiles and tests with no Flutter import; smooth (60fps-target) merge/drop animations in the running app.
9. Passes `flutter analyze` clean under `flutter_lints`.

---

## 9. Out of scope (YAGNI)

No backend/leaderboards/accounts, no cloud sync, no Flame engine, no in-app purchases beyond ad units, no localization pass, no tablet-specific layout in v1.
