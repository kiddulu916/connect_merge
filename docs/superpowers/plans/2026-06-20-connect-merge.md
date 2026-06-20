# Connect-Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the free-drag pairwise merge daily with a path-drawing "Connect-Merge" mechanic — draw a path through orthogonally-adjacent same-tier tiles to collapse them into one tile (+1 tier) with superlinear combo scoring — while preserving the deterministic, replay-verified competitive daily.

**Architecture:** The change is layered bottom-up: constants → move-log event → board model → engine (pure rules) → seeder (deterministic content) → cubit (orchestration) → presentation (gesture + HUD) → leaderboard versioning. The pure engine and seeder stay side-effect-free and fully unit-tested; the cubit composes them; the widget swaps `Draggable`/`DragTarget` for a single pan-gesture path tracker. Determinism is preserved by mirroring the existing landing-PRNG rebuild technique for the new on-demand drop-tier stream.

**Tech Stack:** Dart / Flutter, `flutter_bloc` (Cubit), `flutter_test`, Mulberry32 `Prng`, Hive (storage, via the `StorageService` abstraction). Package name is `merge_count`.

## Global Constraints

- **Determinism is non-negotiable.** Every player on the same `(date, difficulty)` must get the identical board, drop sequence, walls, and objective. All randomness flows through `Prng` (Mulberry32) seeded from `DailySeeder` keys — never `dart:math Random`.
- **The `moveLog` is the authoritative replay input.** Any state-changing player choice must be recorded as a `MoveEvent` and reproducible on replay. Coins/XP/cosmetics NEVER touch `BoardState.score` or `moveLog`.
- **Two PRNG streams stay decoupled:** stream A (global: board placement, drop tiers, walls, objective), stream B (local: landing cells among each player's empties). New streams use new sub-keys (`'$key:drops'`, `'$key:walls'`, `'$key:obj'`), never reusing an existing stream.
- **Migration-free model fields.** New persisted fields on `Tile`/`BoardState`/`PlayerProfile` default to empty/0 and only serialize when set, following the existing `golden`-flag pattern, so old JSON still decodes.
- **Package import prefix:** `package:merge_count/...`. Tests use `flutter_test` with top-level `test()`/`group()`.
- **Tier rule unchanged:** tiers are `1..kMaxTier` (11); a tile's value is `2^tier`; a collapse always yields exactly `+1` tier regardless of chain length.
- **Run every test with:** `flutter test <path>` from the repo root (`C:\Users\dat1k\Projects\merge_loop`).

---

## File Structure

**Modify:**
- `lib/domain/constants.dart` — combo curve, snapshot/leaderboard versions, wall counts, objective + drop-stream tunables.
- `lib/domain/models/move.dart` — add `ChainEvent`.
- `lib/domain/models/board_state.dart` — add `walls`, `objectiveProgress`; `emptyIndices` excludes walls; json/copyWith.
- `lib/domain/engine/game_engine.dart` — adjacency, `isValidChain`, `comboScore`, `collapseChain`, redefined `hasMergeAvailable`.
- `lib/domain/engine/daily_seeder.dart` — wall placement, place tiles among non-walls, on-demand drop-tier PRNG, daily objective.
- `lib/infrastructure/storage_service.dart` — `GameSnapshot.version` + migration discard.
- `lib/application/game_cubit.dart` — `playChain`, multi-drop refill, drop-tier PRNG, queue peek, objective tracking, generalized undo, version-aware resume.
- `lib/presentation/widgets/board_widget.dart` — path gesture, highlighting, live badge, wall rendering.
- `lib/presentation/screens/game_screen.dart` — wire new cubit API, add queue rail + objective banner.
- `lib/infrastructure/leaderboard_service.dart` — season/version tag (hard reset).

**Create:**
- `lib/domain/models/daily_objective.dart` — `DailyObjective` value type.
- `lib/presentation/widgets/drop_queue_rail.dart` — visible next-3-tiers rail.
- `lib/presentation/widgets/objective_banner.dart` — objective + progress display.
- Matching test files under `test/...`.

---

### Task 1: Constants & versions

**Files:**
- Modify: `lib/domain/constants.dart`
- Test: `test/domain/constants_test.dart` (append)

**Interfaces:**
- Produces: `comboMultiplier(int n) -> int`, `comboScore` base via `kComboBaseShift`; `kSnapshotVersion`, `kLeaderboardSeason`, `kDropQueueVisible`, `kAdHintLookahead`; `wallCountFor(Difficulty) -> int`; `kObjectiveRewardCoins`.

- [ ] **Step 1: Write the failing test**

Append to `test/domain/constants_test.dart`:

```dart
import 'package:merge_count/domain/models/difficulty.dart';

// ... inside main():
group('Connect-Merge constants', () {
  test('comboMultiplier is 1 at length 2 and grows superlinearly', () {
    expect(comboMultiplier(2), 1);
    expect(comboMultiplier(3), 2);
    expect(comboMultiplier(4), 4);
    expect(comboMultiplier(5), 7);
    expect(comboMultiplier(6), 11);
    // strictly increasing
    for (var n = 3; n <= 12; n++) {
      expect(comboMultiplier(n) > comboMultiplier(n - 1), isTrue);
    }
  });

  test('wall count increases as the board gets harder', () {
    expect(wallCountFor(Difficulty.easy), 0);
    expect(wallCountFor(Difficulty.legendary) >= wallCountFor(Difficulty.easy),
        isTrue);
  });

  test('queue + version knobs have sane values', () {
    expect(kDropQueueVisible, 3);
    expect(kSnapshotVersion >= 2, isTrue);
    expect(kLeaderboardSeason >= 2, isTrue);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/domain/constants_test.dart`
Expected: FAIL — `comboMultiplier`/`wallCountFor`/`kDropQueueVisible` undefined.

- [ ] **Step 3: Add the constants**

In `lib/domain/constants.dart`, add an import at the top and append:

```dart
import 'models/difficulty.dart';

/// Connect-Merge — superlinear combo multiplier for a chain of [n] tiles.
/// `n == 2` returns 1 so the minimal collapse scores exactly `2^(tier+1)`,
/// identical to the legacy pairwise merge. Formula: 1 + (n-2)(n-1)/2.
/// Pure tuning knob — adjust the curve here only.
int comboMultiplier(int n) {
  if (n < 2) return 0;
  return 1 + ((n - 2) * (n - 1)) ~/ 2;
}

/// Number of the next drop tiers shown openly in the planning queue.
const int kDropQueueVisible = 3;

/// How many drops ahead the rewarded ad-hint reveals (beyond the free queue).
const int kAdHintLookahead = 3;

/// Flat coin reward for completing the daily objective (client-side wallet
/// only — never touches score). Tuning knob.
const int kObjectiveRewardCoins = 25;

/// Bumped when the persisted snapshot schema changes. An in-progress snapshot
/// whose version != this is discarded on load (a daily resets anyway).
const int kSnapshotVersion = 2;

/// Bumped at the Connect-Merge relaunch. Submitted with every score and used to
/// filter leaderboard reads, so pre-relaunch scores never appear (hard reset).
const int kLeaderboardSeason = 2;

/// Seed-placed wall cells per difficulty (block tiles, break paths). Easy has
/// none; tighter boards get more. Tuning knob.
int wallCountFor(Difficulty d) => switch (d) {
      Difficulty.easy => 0,
      Difficulty.medium => 2,
      Difficulty.hard => 3,
      Difficulty.legendary => 4,
    };
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/domain/constants_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/domain/constants.dart test/domain/constants_test.dart
git commit -m "feat: add Connect-Merge tuning constants and versions"
```

---

### Task 2: `ChainEvent` move-log event

**Files:**
- Modify: `lib/domain/models/move.dart`
- Test: `test/domain/models/move_test.dart` (append)

**Interfaces:**
- Produces: `class ChainEvent extends MoveEvent { final List<int> path; const ChainEvent({required this.path}); }` with `type == 'chain'`, json round-trip, value equality on `path`.
- Consumes: existing `MoveEvent.fromJson` switch.

- [ ] **Step 1: Write the failing test**

Append inside `main()` of `test/domain/models/move_test.dart`:

```dart
test('ChainEvent round-trips through json and preserves order', () {
  const e = ChainEvent(path: [0, 1, 6, 11]);
  final decoded = MoveEvent.fromJson(e.toJson());
  expect(decoded, isA<ChainEvent>());
  expect(decoded, e);
  expect((decoded as ChainEvent).path, [0, 1, 6, 11]);
});

test('ChainEvent equality is order-sensitive', () {
  expect(const ChainEvent(path: [0, 1, 2]) == const ChainEvent(path: [0, 1, 2]),
      isTrue);
  expect(const ChainEvent(path: [0, 1, 2]) == const ChainEvent(path: [2, 1, 0]),
      isFalse);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/domain/models/move_test.dart`
Expected: FAIL — `ChainEvent` undefined.

- [ ] **Step 3: Add `ChainEvent`**

In `lib/domain/models/move.dart`, add the case to the `fromJson` switch (above `default`):

```dart
      case ChainEvent.type:
        return ChainEvent(
          path: (j['path'] as List).map((e) => e as int).toList(),
        );
```

And append the class after `MergeEvent`:

```dart
/// An accepted Connect-Merge collapse: an ordered run of orthogonally-adjacent
/// same-tier cells, collapsed onto the LAST cell (the release endpoint). A
/// 2-element path is exactly the legacy pairwise merge. This is the authoritative
/// replay input; the server re-validates the path geometry against the seeded
/// board, so a forged path is rejected.
class ChainEvent extends MoveEvent {
  static const type = 'chain';

  final List<int> path;

  const ChainEvent({required this.path});

  @override
  Map<String, dynamic> toJson() => {'type': type, 'path': path};

  @override
  bool operator ==(Object other) =>
      other is ChainEvent &&
      other.path.length == path.length &&
      _eq(other.path, path);

  static bool _eq(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(path);

  @override
  String toString() => 'ChainEvent(path: $path)';
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/domain/models/move_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/domain/models/move.dart test/domain/models/move_test.dart
git commit -m "feat: add ChainEvent move-log event for Connect-Merge"
```

---

### Task 3: `BoardState` — walls & objective progress

**Files:**
- Modify: `lib/domain/models/board_state.dart`
- Test: `test/domain/models/board_state_test.dart` (append)

**Interfaces:**
- Produces: `BoardState.walls` (`Set<int>`, default `{}`), `BoardState.objectiveProgress` (`int`, default 0), `emptyIndices` excludes walls, `copyWith`/`toJson`/`fromJson` carry both.
- Consumes: existing `BoardState` constructor (all current fields stay required).

- [ ] **Step 1: Write the failing test**

Append inside `main()` of `test/domain/models/board_state_test.dart`:

```dart
test('emptyIndices excludes wall cells', () {
  final cells = List<Tile?>.filled(kCellCount, null);
  cells[0] = const Tile(id: 1, tier: 1);
  final b = BoardState(
    cells: cells,
    movesRemaining: 30,
    score: 0,
    nextTileId: 2,
    dropIndex: 0,
    adContinuesUsed: 0,
    movesMade: 0,
    status: GameStatus.playing,
    walls: const {1, 2},
  );
  expect(b.emptyIndices.contains(0), isFalse); // filled
  expect(b.emptyIndices.contains(1), isFalse); // wall
  expect(b.emptyIndices.contains(2), isFalse); // wall
  expect(b.emptyIndices.contains(3), isTrue); // genuinely empty
});

test('walls and objectiveProgress round-trip through json', () {
  final cells = List<Tile?>.filled(kCellCount, null);
  final b = BoardState(
    cells: cells,
    movesRemaining: 30,
    score: 0,
    nextTileId: 0,
    dropIndex: 0,
    adContinuesUsed: 0,
    movesMade: 0,
    status: GameStatus.playing,
    walls: const {5, 9},
    objectiveProgress: 4,
  );
  final r = BoardState.fromJson(b.toJson());
  expect(r.walls, {5, 9});
  expect(r.objectiveProgress, 4);
});

test('legacy json without walls decodes to empty walls (migration-free)', () {
  final cells = List<Tile?>.filled(kCellCount, null);
  final legacy = BoardState(
    cells: cells,
    movesRemaining: 30,
    score: 0,
    nextTileId: 0,
    dropIndex: 0,
    adContinuesUsed: 0,
    movesMade: 0,
    status: GameStatus.playing,
  ).toJson()
    ..remove('walls')
    ..remove('objectiveProgress');
  final r = BoardState.fromJson(legacy);
  expect(r.walls, isEmpty);
  expect(r.objectiveProgress, 0);
});
```

Ensure the test file imports `constants.dart`, `tile.dart`, `game_status.dart` (match existing imports at the top of the file).

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/domain/models/board_state_test.dart`
Expected: FAIL — named param `walls`/`objectiveProgress` not defined.

- [ ] **Step 3: Add the fields**

In `lib/domain/models/board_state.dart`:

Add fields after `moveLog`:

```dart
  /// Seed-derived blocked cells (Connect-Merge). Hold no tile and break paths.
  /// Static for the day; rides immutably through copyWith. Default empty.
  final Set<int> walls;

  /// Progress toward the day's objective (e.g. longest chain so far, or highest
  /// tier reached). Interpreted by the active [DailyObjective]. Default 0.
  final int objectiveProgress;
```

Add to the constructor parameter list (after `this.moveLog = const []`):

```dart
    this.walls = const {},
    this.objectiveProgress = 0,
```

Add to `copyWith` params and body:

```dart
    Set<int>? walls,
    int? objectiveProgress,
```
```dart
      walls: walls ?? this.walls,
      objectiveProgress: objectiveProgress ?? this.objectiveProgress,
```

Replace `emptyIndices` so it skips walls:

```dart
  List<int> get emptyIndices {
    final out = <int>[];
    for (var i = 0; i < cells.length; i++) {
      if (cells[i] == null && !walls.contains(i)) out.add(i);
    }
    return out;
  }
```

In `toJson`, add (only serialize when set, migration-free):

```dart
        if (walls.isNotEmpty) 'walls': walls.toList(),
        if (objectiveProgress != 0) 'objectiveProgress': objectiveProgress,
```

In `fromJson`, add to the constructor call:

```dart
      walls: ((j['walls'] as List?) ?? const [])
          .map((e) => e as int)
          .toSet(),
      objectiveProgress: (j['objectiveProgress'] as int?) ?? 0,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/domain/models/board_state_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/domain/models/board_state.dart test/domain/models/board_state_test.dart
git commit -m "feat: add walls and objectiveProgress to BoardState"
```

---

### Task 4: `DailyObjective` model + selection

**Files:**
- Create: `lib/domain/models/daily_objective.dart`
- Test: `test/domain/models/daily_objective_test.dart`

**Interfaces:**
- Produces:
  - `enum ObjectiveKind { chainLength, reachTier }`
  - `class DailyObjective { final ObjectiveKind kind; final int target; const DailyObjective(...); int progressAfter(int current, {required int chainLength, required int highestTier}); bool isMet(int progress); String get label; }`
- Consumes: nothing (pure value type).

- [ ] **Step 1: Write the failing test**

Create `test/domain/models/daily_objective_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_count/domain/models/daily_objective.dart';

void main() {
  test('chainLength objective tracks the max chain seen', () {
    const o = DailyObjective(kind: ObjectiveKind.chainLength, target: 5);
    var p = 0;
    p = o.progressAfter(p, chainLength: 3, highestTier: 4);
    expect(p, 3);
    p = o.progressAfter(p, chainLength: 2, highestTier: 6); // shorter chain
    expect(p, 3); // does not regress
    p = o.progressAfter(p, chainLength: 5, highestTier: 6);
    expect(p, 5);
    expect(o.isMet(p), isTrue);
    expect(o.isMet(4), isFalse);
  });

  test('reachTier objective tracks the highest tier seen', () {
    const o = DailyObjective(kind: ObjectiveKind.reachTier, target: 8);
    var p = 0;
    p = o.progressAfter(p, chainLength: 9, highestTier: 5);
    expect(p, 5);
    p = o.progressAfter(p, chainLength: 2, highestTier: 8);
    expect(p, 8);
    expect(o.isMet(p), isTrue);
  });

  test('label is human readable', () {
    expect(const DailyObjective(kind: ObjectiveKind.chainLength, target: 5).label,
        contains('5'));
    expect(const DailyObjective(kind: ObjectiveKind.reachTier, target: 8).label,
        contains('8'));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/domain/models/daily_objective_test.dart`
Expected: FAIL — file/class missing.

- [ ] **Step 3: Create the model**

Create `lib/domain/models/daily_objective.dart`:

```dart
/// The kind of daily bonus goal (Connect-Merge). Seed-chosen per day.
enum ObjectiveKind { chainLength, reachTier }

/// A seed-derived daily objective. Progress is monotonic non-decreasing and
/// recomputed from each collapse, so it is fully reproducible on replay.
/// Completing it credits coins (client-side) — it NEVER affects score.
class DailyObjective {
  final ObjectiveKind kind;
  final int target;

  const DailyObjective({required this.kind, required this.target});

  /// New progress after a collapse of [chainLength] tiles that left the board at
  /// [highestTier]. Never regresses below [current].
  int progressAfter(int current,
      {required int chainLength, required int highestTier}) {
    final candidate = switch (kind) {
      ObjectiveKind.chainLength => chainLength,
      ObjectiveKind.reachTier => highestTier,
    };
    return candidate > current ? candidate : current;
  }

  bool isMet(int progress) => progress >= target;

  String get label => switch (kind) {
        ObjectiveKind.chainLength => 'Land a $target-chain',
        ObjectiveKind.reachTier => 'Reach tier $target (${1 << target})',
      };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/domain/models/daily_objective_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/domain/models/daily_objective.dart test/domain/models/daily_objective_test.dart
git commit -m "feat: add DailyObjective value type"
```

---

### Task 5: Engine — adjacency & path validation

**Files:**
- Modify: `lib/domain/engine/game_engine.dart`
- Test: `test/domain/engine/game_engine_test.dart` (append)

**Interfaces:**
- Produces:
  - `GameEngine.areOrthogonallyAdjacent(int a, int b) -> bool`
  - `GameEngine.isValidChain(BoardState s, List<int> path) -> bool`
- Consumes: `kGridSize`, `kMaxTier`, `BoardState.cells`, `BoardState.walls`.

- [ ] **Step 1: Write the failing test**

Append inside `main()` of `test/domain/engine/game_engine_test.dart`:

```dart
group('Connect-Merge path validation', () {
  test('areOrthogonallyAdjacent: true for N/S/E/W, false for diagonal/wrap', () {
    expect(GameEngine.areOrthogonallyAdjacent(0, 1), isTrue); // E
    expect(GameEngine.areOrthogonallyAdjacent(0, kGridSize), isTrue); // S
    expect(GameEngine.areOrthogonallyAdjacent(0, kGridSize + 1), isFalse); // diag
    expect(GameEngine.areOrthogonallyAdjacent(4, 5), isFalse); // row wrap (col4->col0)
  });

  test('isValidChain: accepts a connected same-tier run', () {
    final b = boardWith({
      0: const Tile(id: 1, tier: 2),
      1: const Tile(id: 2, tier: 2),
      6: const Tile(id: 3, tier: 2), // index 6 = row1,col1, adjacent to 1
    });
    expect(GameEngine.isValidChain(b, [0, 1, 6]), isTrue);
  });

  test('isValidChain: rejects length<2, mixed tier, gaps, repeats, walls', () {
    final b = boardWith({
      0: const Tile(id: 1, tier: 2),
      1: const Tile(id: 2, tier: 2),
      2: const Tile(id: 3, tier: 3), // different tier
      6: const Tile(id: 4, tier: 2),
    });
    expect(GameEngine.isValidChain(b, [0]), isFalse); // too short
    expect(GameEngine.isValidChain(b, [0, 2]), isFalse); // tier mismatch
    expect(GameEngine.isValidChain(b, [0, 6]), isFalse); // not adjacent
    expect(GameEngine.isValidChain(b, [0, 1, 0]), isFalse); // repeat
    final empty = boardWith({0: const Tile(id: 1, tier: 2)});
    expect(GameEngine.isValidChain(empty, [0, 1]), isFalse); // cell 1 empty
  });

  test('isValidChain: rejects a path stepping onto a wall', () {
    final cells = List<Tile?>.filled(kCellCount, null);
    cells[0] = const Tile(id: 1, tier: 2);
    cells[1] = const Tile(id: 2, tier: 2);
    final b = BoardState(
      cells: cells,
      movesRemaining: 30,
      score: 0,
      nextTileId: 3,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 0,
      status: GameStatus.playing,
      walls: const {1},
    );
    expect(GameEngine.isValidChain(b, [0, 1]), isFalse);
  });

  test('isValidChain: rejects a chain at max tier', () {
    final b = boardWith({
      0: const Tile(id: 1, tier: kMaxTier),
      1: const Tile(id: 2, tier: kMaxTier),
    });
    expect(GameEngine.isValidChain(b, [0, 1]), isFalse);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/domain/engine/game_engine_test.dart`
Expected: FAIL — `areOrthogonallyAdjacent`/`isValidChain` undefined.

- [ ] **Step 3: Implement**

In `lib/domain/engine/game_engine.dart`, add inside the `GameEngine` class:

```dart
  /// True when cells [a] and [b] are orthogonal neighbours on the grid (no
  /// diagonals, no row wrap-around).
  static bool areOrthogonallyAdjacent(int a, int b) {
    final ra = a ~/ kGridSize, ca = a % kGridSize;
    final rb = b ~/ kGridSize, cb = b % kGridSize;
    final dr = (ra - rb).abs(), dc = (ca - cb).abs();
    return (dr + dc) == 1;
  }

  /// A legal Connect-Merge path: length >= 2, no repeated cells, each cell holds
  /// a live tile, all tiles share one tier below the cap, and consecutive cells
  /// are orthogonally adjacent. Walls hold no tile, so they are rejected by the
  /// null-cell check, but we never index a wall as a tile.
  static bool isValidChain(BoardState s, List<int> path) {
    if (path.length < 2) return false;
    final seen = <int>{};
    final first = s.cells[path.first];
    if (first == null || first.tier >= kMaxTier) return false;
    final tier = first.tier;
    for (var i = 0; i < path.length; i++) {
      final idx = path[i];
      if (idx < 0 || idx >= kCellCount) return false;
      if (!seen.add(idx)) return false; // repeat
      final t = s.cells[idx];
      if (t == null || t.tier != tier) return false;
      if (i > 0 && !areOrthogonallyAdjacent(path[i - 1], idx)) return false;
    }
    return true;
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/domain/engine/game_engine_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/domain/engine/game_engine.dart test/domain/engine/game_engine_test.dart
git commit -m "feat: add orthogonal adjacency and chain validation to engine"
```

---

### Task 6: Engine — combo scoring

**Files:**
- Modify: `lib/domain/engine/game_engine.dart`
- Test: `test/domain/engine/game_engine_test.dart` (append)

**Interfaces:**
- Produces: `GameEngine.comboScore(int mergedTier, int chainLength) -> int` == `(1 << (mergedTier + 1)) * comboMultiplier(chainLength)`.
- Consumes: `comboMultiplier` (Task 1).

- [ ] **Step 1: Write the failing test**

Append inside `main()`:

```dart
group('Connect-Merge scoring', () {
  test('comboScore: 2-chain equals the legacy single-merge score', () {
    // legacy merge of two tier-3 tiles scored 1 << 4 = 16
    expect(GameEngine.comboScore(3, 2), 1 << 4);
  });

  test('comboScore: longer chains apply the superlinear multiplier', () {
    // tier 2 -> result value 8; multipliers 1,2,4,7,11
    expect(GameEngine.comboScore(2, 2), 8);
    expect(GameEngine.comboScore(2, 3), 16);
    expect(GameEngine.comboScore(2, 4), 32);
    expect(GameEngine.comboScore(2, 5), 56);
    expect(GameEngine.comboScore(2, 6), 88);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/domain/engine/game_engine_test.dart`
Expected: FAIL — `comboScore` undefined.

- [ ] **Step 3: Implement**

Add the import at the top of `game_engine.dart` if not present (`constants.dart` already imported), then add to the class:

```dart
  /// Points for collapsing a chain of [chainLength] tiles of [mergedTier]. The
  /// base is the legacy `2^(mergedTier+1)` (so a 2-chain matches the old merge),
  /// scaled by the superlinear [comboMultiplier].
  static int comboScore(int mergedTier, int chainLength) =>
      (1 << (mergedTier + 1)) * comboMultiplier(chainLength);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/domain/engine/game_engine_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/domain/engine/game_engine.dart test/domain/engine/game_engine_test.dart
git commit -m "feat: add combo scoring to engine"
```

---

### Task 7: Engine — chain collapse

**Files:**
- Modify: `lib/domain/engine/game_engine.dart`
- Test: `test/domain/engine/game_engine_test.dart` (append)

**Interfaces:**
- Produces: `GameEngine.collapseChain(BoardState s, List<int> path) -> BoardState` — endpoint (`path.last`) becomes `tier+1` keeping its id; all other path cells empty; `score += comboScore`; `movesRemaining-1`; `movesMade+1`. Does NOT append to `moveLog` (the cubit does, mirroring how `merge` leaves logging to the cubit) and does NOT drop (the cubit refills).
- Consumes: `isValidChain` is the caller's guard (collapse assumes a valid path).

- [ ] **Step 1: Write the failing test**

Append inside `main()`:

```dart
group('Connect-Merge collapse', () {
  test('collapse: endpoint climbs +1 keeping its id; others empty; scores combo', () {
    final b = boardWith({
      0: const Tile(id: 10, tier: 2),
      1: const Tile(id: 11, tier: 2),
      6: const Tile(id: 12, tier: 2), // endpoint
    });
    final r = GameEngine.collapseChain(b, [0, 1, 6]);
    expect(r.cells[0], isNull);
    expect(r.cells[1], isNull);
    expect(r.cells[6]!.tier, 3);
    expect(r.cells[6]!.id, 12); // endpoint id preserved for animation
    expect(r.score, GameEngine.comboScore(2, 3)); // 16
    expect(r.movesRemaining, kMovesPerDay - 1);
    expect(r.movesMade, 1);
    expect(r.filledCount, 1); // only the endpoint remains
  });

  test('collapse: a 2-path matches the legacy merge result', () {
    final b = boardWith({
      0: const Tile(id: 1, tier: 3),
      1: const Tile(id: 2, tier: 3),
    });
    final chain = GameEngine.collapseChain(b, [0, 1]);
    final legacy = GameEngine.merge(b, fromIndex: 0, toIndex: 1);
    expect(chain.cells[1]!.tier, legacy.cells[1]!.tier);
    expect(chain.cells[1]!.id, legacy.cells[1]!.id);
    expect(chain.score, legacy.score);
    expect(chain.movesRemaining, legacy.movesRemaining);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/domain/engine/game_engine_test.dart`
Expected: FAIL — `collapseChain` undefined.

- [ ] **Step 3: Implement**

Add to the `GameEngine` class:

```dart
  /// Collapse a validated Connect-Merge [path] onto its endpoint (`path.last`):
  /// the endpoint becomes tier+1 (keeping its id for animation continuity), all
  /// other path cells empty, score gains the combo total, one move is spent.
  /// Caller must have checked [isValidChain]. Mirrors [merge]: no drop, no log
  /// (the cubit applies the refill and records the [ChainEvent]).
  static BoardState collapseChain(BoardState s, List<int> path) {
    final endIdx = path.last;
    final endTile = s.cells[endIdx]!;
    final mergedTier = endTile.tier;
    final newTier = mergedTier + 1;
    final cells = List<Tile?>.of(s.cells);
    for (final idx in path) {
      cells[idx] = null;
    }
    cells[endIdx] = Tile(id: endTile.id, tier: newTier);
    return s.copyWith(
      cells: cells,
      score: s.score + comboScore(mergedTier, path.length),
      movesRemaining: s.movesRemaining - 1,
      movesMade: s.movesMade + 1,
    );
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/domain/engine/game_engine_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/domain/engine/game_engine.dart test/domain/engine/game_engine_test.dart
git commit -m "feat: add chain collapse to engine"
```

---

### Task 8: Engine — spatial deadlock (`hasMergeAvailable`)

**Files:**
- Modify: `lib/domain/engine/game_engine.dart`
- Test: `test/domain/engine/game_engine_test.dart` (replace the old `hasMergeAvailable` test)

**Interfaces:**
- Produces: redefined `GameEngine.hasMergeAvailable(BoardState s) -> bool` — true iff some pair of orthogonally-adjacent cells holds equal-tier tiles below the cap.
- Consumes: `areOrthogonallyAdjacent` (Task 5).

- [ ] **Step 1: Update the failing test**

In `test/domain/engine/game_engine_test.dart`, REPLACE the existing test
`'hasMergeAvailable: false when all tiers unique => deadlock'` with:

```dart
test('hasMergeAvailable: needs ADJACENT equal tiers, not just any pair', () {
  // Two tier-1 tiles exist but are NOT orthogonally adjacent => deadlock.
  final apart = boardWith({
    0: const Tile(id: 1, tier: 1),
    2: const Tile(id: 2, tier: 1), // same row, gap at index 1
    8: const Tile(id: 3, tier: 3),
  });
  expect(GameEngine.hasMergeAvailable(apart), isFalse);
  expect(GameEngine.evaluateStatus(apart).status, GameStatus.deadlocked);

  // Make them adjacent => a merge is available again.
  final together = boardWith({
    0: const Tile(id: 1, tier: 1),
    1: const Tile(id: 2, tier: 1),
  });
  expect(GameEngine.hasMergeAvailable(together), isTrue);
  expect(GameEngine.evaluateStatus(together).status, GameStatus.playing);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/domain/engine/game_engine_test.dart`
Expected: FAIL — current `hasMergeAvailable` returns true for any equal-tier pair (the `apart` case), so the first expectation fails.

- [ ] **Step 3: Reimplement `hasMergeAvailable`**

In `lib/domain/engine/game_engine.dart`, REPLACE the body of `hasMergeAvailable`:

```dart
  /// True if any two orthogonally-adjacent live tiles share a tier below the cap
  /// (a legal Connect-Merge of length 2). Position now matters: equal tiles that
  /// are not adjacent do NOT count, so a player can strand tiles into a deadlock.
  static bool hasMergeAvailable(BoardState s) {
    for (var i = 0; i < kCellCount; i++) {
      final t = s.cells[i];
      if (t == null || t.tier >= kMaxTier) continue;
      final row = i ~/ kGridSize, col = i % kGridSize;
      // Check east and south neighbours only (covers every adjacency once).
      if (col + 1 < kGridSize) {
        final e = s.cells[i + 1];
        if (e != null && e.tier == t.tier) return true;
      }
      if (row + 1 < kGridSize) {
        final so = s.cells[i + kGridSize];
        if (so != null && so.tier == t.tier) return true;
      }
    }
    return false;
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/domain/engine/game_engine_test.dart`
Expected: PASS (and all other engine tests still pass).

- [ ] **Step 5: Commit**

```bash
git add lib/domain/engine/game_engine.dart test/domain/engine/game_engine_test.dart
git commit -m "feat: redefine deadlock as spatial (adjacent equal tiers)"
```

---

### Task 9: Seeder — walls & placement among non-walls

**Files:**
- Modify: `lib/domain/engine/daily_seeder.dart`
- Test: `test/domain/engine/daily_seeder_test.dart` (append)

**Interfaces:**
- Produces:
  - `DailySeeder.wallIndices() -> Set<int>` (size == `wallCountFor(difficulty)`, deterministic).
  - `generate()` now places `walls` on the board and never starts a tile on a wall cell.
- Consumes: `wallCountFor` (Task 1), `BoardState.walls` (Task 3).

- [ ] **Step 1: Write the failing test**

Append inside `main()` of `test/domain/engine/daily_seeder_test.dart` (match the file's existing imports; add `import 'package:merge_count/domain/models/difficulty.dart';` if absent):

```dart
group('Connect-Merge seeding', () {
  test('wallIndices is deterministic and sized per difficulty', () {
    final s = DailySeeder('2026-06-20', Difficulty.hard);
    expect(s.wallIndices().length, wallCountFor(Difficulty.hard));
    expect(s.wallIndices(), DailySeeder('2026-06-20', Difficulty.hard).wallIndices());
  });

  test('easy has no walls', () {
    expect(DailySeeder('2026-06-20', Difficulty.easy).wallIndices(), isEmpty);
  });

  test('generated board carries walls and never places a tile on one', () {
    final s = DailySeeder('2026-06-20', Difficulty.legendary);
    final start = s.generate();
    expect(start.board.walls, s.wallIndices());
    for (final w in start.board.walls) {
      expect(start.board.cells[w], isNull);
    }
    expect(start.board.filledCount, Difficulty.legendary.startingFill);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/domain/engine/daily_seeder_test.dart`
Expected: FAIL — `wallIndices` undefined.

- [ ] **Step 3: Implement**

In `lib/domain/engine/daily_seeder.dart`:

Add `import '../constants.dart';` is already present. Add the method and update `generate()`:

```dart
  /// Deterministic wall cells for this date+tier, drawn from an independent
  /// `'$_key:walls'` stream so it never perturbs board/drop/landing streams.
  Set<int> wallIndices() {
    final count = wallCountFor(difficulty);
    if (count == 0) return const {};
    final w = Prng(seedForKey('$_key:walls'));
    final out = <int>{};
    while (out.length < count) {
      out.add(w.nextInt(kCellCount)); // rejection sampling; deterministic
    }
    return out;
  }
```

In `generate()`, compute walls first and exclude them from placement. Replace the placement block:

```dart
  DailyStart generate() {
    final a = Prng(_seedA);
    final walls = wallIndices();

    final cells = List<Tile?>.filled(kCellCount, null);
    var nextId = 0;
    var placed = 0;
    final startingFill = difficulty.startingFill;
    while (placed < startingFill) {
      final idx = a.nextInt(kCellCount);
      if (cells[idx] != null || walls.contains(idx)) continue; // skip walls
      cells[idx] = Tile(id: nextId++, tier: 1 + a.nextInt(2));
      placed++;
    }

    final tiers = <int>[];
    for (var n = 0; n < kMaxDrops; n++) {
      tiers.add(1 + a.nextInt(dropCap(n)));
    }

    final board = BoardState(
      cells: cells,
      movesRemaining: kMovesPerDay,
      score: 0,
      nextTileId: nextId,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 0,
      status: GameStatus.playing,
      walls: walls,
    );
    return DailyStart(board, tiers);
  }
```

> Note: `dropTiers` stays for now (Task 10 makes drops on-demand). Adding `walls` to the seed-A board after placement keeps stream A identical to today for the placement draws, so only wall geometry is new.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/domain/engine/daily_seeder_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/domain/engine/daily_seeder.dart test/domain/engine/daily_seeder_test.dart
git commit -m "feat: seed deterministic wall cells and place tiles around them"
```

---

### Task 10: Seeder — on-demand drop-tier stream + daily objective

**Files:**
- Modify: `lib/domain/engine/daily_seeder.dart`
- Test: `test/domain/engine/daily_seeder_test.dart` (append)

**Interfaces:**
- Produces:
  - `DailySeeder.dropTierPrng() -> Prng` (fresh stream keyed `'$_key:drops'`).
  - `DailySeeder.dropTierAt(Prng p, int n) -> int` == `1 + p.nextInt(dropCap(n))` (advances `p` once; caller draws in index order).
  - `DailySeeder.dailyObjective() -> DailyObjective` (deterministic).
- Consumes: `dropCap` (constants), `DailyObjective`/`ObjectiveKind` (Task 4).

> Rationale: the cubit will hold a `dropTierPrng` advanced in lock-step with `dropIndex` (exactly like the landing PRNG), so variable multi-drop refills are unbounded and deterministic, and resume/undo rebuild by replay.

- [ ] **Step 1: Write the failing test**

Append inside `main()`:

```dart
import 'package:merge_count/domain/models/daily_objective.dart';
// (add at top of file with the other imports)

group('Connect-Merge drops & objective', () {
  test('drop-tier stream is deterministic and band-capped by index', () {
    final s = DailySeeder('2026-06-20', Difficulty.medium);
    final p1 = s.dropTierPrng();
    final p2 = s.dropTierPrng();
    for (var n = 0; n < 50; n++) {
      final t1 = s.dropTierAt(p1, n);
      final t2 = s.dropTierAt(p2, n);
      expect(t1, t2); // same seed => same sequence
      expect(t1 >= 1 && t1 <= dropCap(n), isTrue);
    }
  });

  test('dailyObjective is deterministic and valid', () {
    final s = DailySeeder('2026-06-20', Difficulty.medium);
    final o = s.dailyObjective();
    expect(o.target > 0, isTrue);
    expect(s.dailyObjective().kind, o.kind);
    expect(s.dailyObjective().target, o.target);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/domain/engine/daily_seeder_test.dart`
Expected: FAIL — `dropTierPrng`/`dropTierAt`/`dailyObjective` undefined.

- [ ] **Step 3: Implement**

In `lib/domain/engine/daily_seeder.dart`, add `import '../models/daily_objective.dart';` and add:

```dart
  /// Fresh on-demand drop-tier stream (decoupled from board placement so refills
  /// can be unbounded). Advance it in drop-index order via [dropTierAt].
  Prng dropTierPrng() => Prng(seedForKey('$_key:drops'));

  /// Tier for drop number [n], drawn from [p] (which the caller advances in
  /// index order). Band widens by drop index, identical for all players.
  int dropTierAt(Prng p, int n) => 1 + p.nextInt(dropCap(n));

  /// Deterministic daily objective from an independent `'$_key:obj'` stream.
  DailyObjective dailyObjective() {
    final o = Prng(seedForKey('$_key:obj'));
    final kind = ObjectiveKind.values[o.nextInt(ObjectiveKind.values.length)];
    final target = switch (kind) {
      ObjectiveKind.chainLength => 4 + o.nextInt(3), // 4..6
      ObjectiveKind.reachTier => 6 + o.nextInt(3), // 6..8
    };
    return DailyObjective(kind: kind, target: target);
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/domain/engine/daily_seeder_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/domain/engine/daily_seeder.dart test/domain/engine/daily_seeder_test.dart
git commit -m "feat: add on-demand drop-tier stream and daily objective to seeder"
```

---

### Task 11: Snapshot versioning & migration discard

**Files:**
- Modify: `lib/infrastructure/storage_service.dart`
- Test: `test/infrastructure/in_memory_storage_test.dart` (append)

**Interfaces:**
- Produces: `GameSnapshot.version` (`int`, default `kSnapshotVersion`); `toJson` writes `'v'`; `fromJson` reads `'v'` (absent => `1`, legacy).
- Consumes: `kSnapshotVersion` (Task 1). The cubit's resume guard (Task 12) uses `version`.

- [ ] **Step 1: Write the failing test**

Append inside `main()` of `test/infrastructure/in_memory_storage_test.dart` (match existing imports; add `import 'package:merge_count/domain/constants.dart';` if absent):

```dart
test('GameSnapshot carries a version that round-trips; legacy json is v1', () {
  final cells = List<Tile?>.filled(kCellCount, null);
  final snap = GameSnapshot(
    date: '2026-06-20',
    difficulty: Difficulty.easy,
    board: BoardState(
      cells: cells,
      movesRemaining: 30,
      score: 0,
      nextTileId: 0,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 0,
      status: GameStatus.playing,
    ),
    completed: false,
  );
  expect(snap.version, kSnapshotVersion);
  expect(GameSnapshot.fromJson(snap.toJson()).version, kSnapshotVersion);

  final legacy = snap.toJson()..remove('v');
  expect(GameSnapshot.fromJson(legacy).version, 1);
});
```

Ensure the test imports `board_state.dart`, `tile.dart`, `game_status.dart`, `difficulty.dart`, and `storage_service.dart`.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/infrastructure/in_memory_storage_test.dart`
Expected: FAIL — `version` not defined on `GameSnapshot`.

- [ ] **Step 3: Implement**

In `lib/infrastructure/storage_service.dart`, add `import '../domain/constants.dart';` (already imported) and update `GameSnapshot`:

Add field + constructor param:

```dart
  /// Snapshot schema version. A snapshot whose version != [kSnapshotVersion] is
  /// discarded on load (the cubit starts the day fresh under current rules).
  final int version;
```
```dart
  const GameSnapshot({
    required this.date,
    required this.difficulty,
    required this.board,
    required this.completed,
    this.version = kSnapshotVersion,
  });
```

Update `toJson` to add `'v': version` and `fromJson`:

```dart
        'v': version,
```
```dart
        version: (j['v'] as int?) ?? 1,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/infrastructure/in_memory_storage_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/infrastructure/storage_service.dart test/infrastructure/in_memory_storage_test.dart
git commit -m "feat: version game snapshots for migration"
```

---

### Task 12: Cubit — Connect-Merge orchestration

**Files:**
- Modify: `lib/application/game_cubit.dart`
- Test: `test/application/game_cubit_test.dart` (append) and `test/application/game_cubit_undo_test.dart` (append)

**Interfaces:**
- Produces (new public cubit API):
  - `Future<void> playChain(List<int> path)` — validates via `GameEngine.isValidChain`, records `ChainEvent`, collapses, refills to `startingFill`, tracks objective, evaluates status, persists, emits.
  - `List<int> peekDropTiers([int count = kDropQueueVisible])` — the next tiers without consuming.
  - `DailyObjective get objective`.
- Consumes: Tasks 5–10 engine/seeder additions, `BoardState.objectiveProgress`, `kSnapshotVersion`.
- Internal changes: replace `late List<int> _dropTiers` with `late Prng _dropTier`; add `late DailyObjective _objective`; rebuild both `_landing` and `_dropTier` to `dropIndex` on resume/undo; resume guard checks snapshot version.

- [ ] **Step 1: Write the failing test**

Append inside `main()` of `test/application/game_cubit_test.dart` (reuse the file's existing setup; it already constructs a `GameCubit` with `InMemoryStorageService` and a fixed `todayProvider`). Add a helper that finds an adjacent same-tier pair on the live board, then plays it:

```dart
test('playChain collapses a valid 2-path, scores, and tops the board back up',
    () async {
  final storage = InMemoryStorageService();
  final cubit = GameCubit(storage: storage, todayProvider: () => '2026-06-20');
  await cubit.init(difficulty: Difficulty.easy);
  final before = (cubit.state as GamePlaying).board;

  // Find any orthogonally-adjacent equal-tier pair on the seeded board.
  int? from, to;
  for (var i = 0; i < kCellCount && from == null; i++) {
    final t = before.cells[i];
    if (t == null || t.tier >= kMaxTier) continue;
    for (final n in [i + 1, i + kGridSize]) {
      if (n >= kCellCount) continue;
      if (n == i + 1 && (i % kGridSize) == kGridSize - 1) continue; // row wrap
      final u = before.cells[n];
      if (u != null && u.tier == t.tier) {
        from = i;
        to = n;
        break;
      }
    }
  }
  expect(from, isNotNull, reason: 'seeded easy board should have a merge');

  await cubit.playChain([from!, to!]);
  final after = (cubit.state as GamePlaying).board;

  expect(after.score, greaterThan(before.score));
  expect(after.movesRemaining, before.movesRemaining - 1);
  // Board topped back up to the difficulty fill (a 2-chain frees 1, drops 1).
  expect(after.filledCount, Difficulty.easy.startingFill);
  expect(after.moveLog.last, isA<ChainEvent>());
});

test('playChain rejects an invalid path (no state change)', () async {
  final storage = InMemoryStorageService();
  final cubit = GameCubit(storage: storage, todayProvider: () => '2026-06-20');
  await cubit.init(difficulty: Difficulty.easy);
  final before = (cubit.state as GamePlaying).board;
  await cubit.playChain([0, 24]); // not adjacent / likely empty
  final after = (cubit.state as GamePlaying).board;
  expect(after.score, before.score);
  expect(after.movesRemaining, before.movesRemaining);
});

test('peekDropTiers returns the next tiers without consuming them', () async {
  final storage = InMemoryStorageService();
  final cubit = GameCubit(storage: storage, todayProvider: () => '2026-06-20');
  await cubit.init(difficulty: Difficulty.easy);
  final a = cubit.peekDropTiers();
  final b = cubit.peekDropTiers();
  expect(a.length, kDropQueueVisible);
  expect(a, b); // idempotent (no consumption)
});
```

Make sure this test file imports `constants.dart`, `move.dart`, `game_status.dart`, and `difficulty.dart`.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/application/game_cubit_test.dart`
Expected: FAIL — `playChain`/`peekDropTiers` undefined.

- [ ] **Step 3: Implement the cubit changes**

In `lib/application/game_cubit.dart`:

(a) Add imports:

```dart
import '../domain/models/daily_objective.dart';
```

(b) Replace the field `late List<int> _dropTiers;` with:

```dart
  /// On-demand drop-tier stream (stream "drops"), advanced in lock-step with
  /// dropIndex exactly like [_landing]. Rebuilt by replay on resume/undo.
  late Prng _dropTier;

  /// The day's objective (seed-derived). Read by the UI and tracked per chain.
  late DailyObjective _objective;
  DailyObjective get objective => _objective;
```

(c) In `init`, replace `_dropTiers = start.dropTiers;` and the landing setup. After `final start = _seeder.generate();`:

```dart
    _objective = _seeder.dailyObjective();
```

In the resume branch, rebuild BOTH streams and add the version guard. Replace:

```dart
    final snap = storage.loadSnapshot(_date, difficulty);
    if (snap != null && snap.date == _date) {
```
with:
```dart
    final snap = storage.loadSnapshot(_date, difficulty);
    if (snap != null && snap.date == _date && snap.version == kSnapshotVersion) {
      _dropTier = _rebuildDropTierTo(snap.board.dropIndex);
```
and keep the existing `_landing = _rebuildLandingTo(...)` line right after.

In the fresh-day branch, after `_landing = _seeder.landingPrng();` add:

```dart
    _dropTier = _seeder.dropTierPrng();
```

(d) Add the drop-tier rebuild helper next to `_rebuildLandingTo`:

```dart
  /// Rebuild the drop-tier stream and advance it to [draws] taken (one draw per
  /// applied drop), mirroring [_rebuildLandingTo]. Deterministic rewind.
  Prng _rebuildDropTierTo(int draws) {
    final p = _seeder.dropTierPrng();
    for (var i = 0; i < draws; i++) {
      _seeder.dropTierAt(p, i);
    }
    return p;
  }
```

(e) Add `peekDropTiers` (rebuilds a temp stream to current dropIndex; no consumption):

```dart
  /// The next [count] drop tiers, peeked without consuming the live stream.
  /// Returns fewer only at the theoretical schedule edge (never in practice —
  /// the stream is unbounded). Powers the visible planning queue.
  List<int> peekDropTiers([int count = kDropQueueVisible]) {
    final s = state;
    final dropIndex = s is GamePlaying ? s.board.dropIndex : 0;
    final p = _rebuildDropTierTo(dropIndex);
    return [for (var k = 0; k < count; k++) _seeder.dropTierAt(p, dropIndex + k)];
  }
```

(f) Add `playChain`. Model it on the existing `merge` method (golden bonus, undo frame, persistence, completion flow) but generalized to a path with a multi-drop refill:

```dart
  /// Play a Connect-Merge: validate [path], collapse it, refill the board to the
  /// difficulty's starting fill, track the daily objective, then persist/emit.
  /// Mirrors [merge]'s lifecycle (undo frame, golden bonus, completion hooks).
  Future<void> playChain(List<int> path) async {
    final s = state;
    if (s is! GamePlaying) return;
    if (!GameEngine.isValidChain(s.board, path)) return;

    // Golden bonus: every golden tile consumed anywhere in the path pays out.
    // Computed on the PRE-collapse board; never touches score/log.
    var goldenBonus = 0;
    for (final idx in path) {
      if (s.board.cells[idx]?.golden ?? false) goldenBonus += kGoldenMergeBonus;
    }

    _undoStack.add(_UndoFrame(
      board: s.board,
      landingDraws: s.board.dropIndex,
      coinsCredited: goldenBonus,
    ));
    if (_undoStack.length > kUndoStackDepth) _undoStack.removeAt(0);

    final log = List<MoveEvent>.of(s.board.moveLog)..add(ChainEvent(path: path));

    var board =
        GameEngine.collapseChain(s.board, path).copyWith(moveLog: log);

    // Refill to the difficulty's starting fill (a chain of N freed N-1 cells).
    final targetFill = _difficulty.startingFill;
    while (board.filledCount < targetFill && board.emptyIndices.isNotEmpty) {
      final tier = _seeder.dropTierAt(_dropTier, board.dropIndex);
      board = GameEngine.applyDrop(
        board,
        tier,
        _landing,
        golden: _goldenDrops.contains(board.dropIndex),
      );
    }

    // Track the daily objective (monotonic; recomputable on replay).
    final newProgress = _objective.progressAfter(
      board.objectiveProgress,
      chainLength: path.length,
      highestTier: board.highestTier,
    );
    final justMet = !_objectiveMet &&
        !_objective.isMet(board.objectiveProgress) &&
        _objective.isMet(newProgress);
    board = board.copyWith(objectiveProgress: newProgress);

    board = GameEngine.evaluateStatus(board);

    if (goldenBonus > 0) {
      _coinsEarnedThisRun += goldenBonus;
      await onCoinsEarned?.call(goldenBonus);
    }
    if (justMet) {
      _objectiveMet = true;
      _coinsEarnedThisRun += kObjectiveRewardCoins;
      await onCoinsEarned?.call(kObjectiveRewardCoins);
    }

    final done = board.status != GameStatus.playing;
    await storage.saveSnapshot(GameSnapshot(
        date: _date,
        difficulty: _difficulty,
        board: board,
        completed: done));

    if (done) {
      await _finishRun(board); // extracted below
    } else {
      emit(GamePlaying(board: board, difficulty: _difficulty));
    }
  }

  /// Whether the objective reward has already been paid this run (idempotency).
  bool _objectiveMet = false;
```

(g) Extract the existing completion tail of `merge` (everything from `final firstCompletionToday = ...` through the `_submit` call) into a private `Future<void> _finishRun(BoardState board)` so both `merge` and `playChain` reuse it. Then make `playChain` call it (done above). Keep `merge` working by calling `_finishRun(board)` in its `if (done)` branch.

> Note: `merge` may be retained for the legacy 2-path and for back-compat tests; it now delegates its completion tail to `_finishRun`. New gameplay calls `playChain`.

(h) Reset `_objectiveMet = false;` in `init` alongside `_undoStack.clear();`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/application/game_cubit_test.dart`
Expected: PASS (new tests + existing ones).

- [ ] **Step 5: Add an undo regression test**

Append inside `main()` of `test/application/game_cubit_undo_test.dart`:

```dart
test('undo after a chain restores board, score, and drop streams', () async {
  final storage = InMemoryStorageService();
  final cubit = GameCubit(storage: storage, todayProvider: () => '2026-06-20');
  await cubit.init(difficulty: Difficulty.easy);
  final before = (cubit.state as GamePlaying).board;

  int? from, to;
  for (var i = 0; i < kCellCount && from == null; i++) {
    final t = before.cells[i];
    if (t == null || t.tier >= kMaxTier) continue;
    for (final n in [i + 1, i + kGridSize]) {
      if (n >= kCellCount) continue;
      if (n == i + 1 && (i % kGridSize) == kGridSize - 1) continue;
      final u = before.cells[n];
      if (u != null && u.tier == t.tier) { from = i; to = n; break; }
    }
  }
  await cubit.playChain([from!, to!]);
  expect(cubit.canUndo, isTrue);
  await cubit.undo();
  final restored = (cubit.state as GamePlaying).board;
  expect(restored.score, before.score);
  expect(restored.movesRemaining, before.movesRemaining);
  expect(restored.dropIndex, before.dropIndex);
});
```

- [ ] **Step 6: Run the undo test**

Run: `flutter test test/application/game_cubit_undo_test.dart`
Expected: PASS.

- [ ] **Step 7: Run the full suite (catch fallout from the deadlock/refill changes)**

Run: `flutter test`
Expected: PASS. If `merge`-based tests broke due to the extracted `_finishRun`, fix call sites so behavior is unchanged.

- [ ] **Step 8: Commit**

```bash
git add lib/application/game_cubit.dart test/application/game_cubit_test.dart test/application/game_cubit_undo_test.dart
git commit -m "feat: add playChain orchestration with multi-drop refill, objective, versioned resume"
```

---

### Task 13: Board widget — path gesture

**Files:**
- Modify: `lib/presentation/widgets/board_widget.dart`
- Test: `test/presentation/board_widget_test.dart` (append)

**Interfaces:**
- Produces: `BoardWidget` gains `final void Function(List<int> path) onChain;` and renders walls. The legacy `onMerge` is removed; `game_screen` (Task 16) passes `onChain`.
- Consumes: `GameEngine.areOrthogonallyAdjacent` for live highlight validation; `BoardState.walls`.

- [ ] **Step 1: Write the failing widget test**

Append inside `main()` of `test/presentation/board_widget_test.dart` (match existing harness; it pumps a `BoardWidget` inside a sized box). Add:

```dart
testWidgets('dragging across two adjacent equal tiles reports a 2-path',
    (tester) async {
  final cells = List<Tile?>.filled(kCellCount, null);
  cells[0] = const Tile(id: 1, tier: 2);
  cells[1] = const Tile(id: 2, tier: 2); // east neighbour, same tier
  final board = BoardState(
    cells: cells,
    movesRemaining: 30,
    score: 0,
    nextTileId: 3,
    dropIndex: 0,
    adContinuesUsed: 0,
    movesMade: 0,
    status: GameStatus.playing,
  );

  List<int>? reported;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 350,
          height: 350,
          child: BoardWidget(board: board, onChain: (p) => reported = p),
        ),
      ),
    ),
  ));

  // Drag from the center of cell 0 to the center of cell 1.
  final box = tester.getRect(find.byType(BoardWidget));
  const gap = 8.0;
  final cell = (box.width - gap * (kGridSize + 1)) / kGridSize;
  Offset centerOf(int i) {
    final row = i ~/ kGridSize, col = i % kGridSize;
    return box.topLeft +
        Offset(gap + col * (cell + gap) + cell / 2,
            gap + row * (cell + gap) + cell / 2);
  }

  final g = await tester.startGesture(centerOf(0));
  await tester.pump();
  await g.moveTo(centerOf(1));
  await tester.pump();
  await g.up();
  await tester.pump();

  expect(reported, [0, 1]);
});
```

Ensure imports include `constants.dart`, `board_state.dart`, `tile.dart`, `game_status.dart`.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/presentation/board_widget_test.dart`
Expected: FAIL — `onChain` not defined / drag does nothing.

- [ ] **Step 3: Rewrite the interaction layer**

In `lib/presentation/widgets/board_widget.dart`, convert `BoardWidget` to a `StatefulWidget`. Replace the `Draggable`/`DragTarget` layers with a single `GestureDetector` that hit-tests pointer positions to cell indices and builds a live path. Key implementation:

```dart
// Replace the class signature/fields:
class BoardWidget extends StatefulWidget {
  final BoardState board;
  final void Function(List<int> path) onChain;
  final Cosmetic cosmetic;
  final bool colorblindMode;

  const BoardWidget({
    super.key,
    required this.board,
    required this.onChain,
    this.cosmetic = Cosmetic.classic,
    this.colorblindMode = false,
  });

  @override
  State<BoardWidget> createState() => _BoardWidgetState();
}

class _BoardWidgetState extends State<BoardWidget> {
  final List<int> _path = [];
  double _cell = 0;
  double _gap = 8;

  int? _cellAt(Offset local) {
    final step = _cell + _gap;
    for (var i = 0; i < kCellCount; i++) {
      final row = i ~/ kGridSize, col = i % kGridSize;
      final rect = Rect.fromLTWH(
          _gap + col * step, _gap + row * step, _cell, _cell);
      if (rect.contains(local)) return i;
    }
    return null;
  }

  bool _canExtend(int idx) {
    if (widget.board.walls.contains(idx)) return false;
    final t = widget.board.cells[idx];
    if (t == null || t.tier >= kMaxTier) return false;
    if (_path.isEmpty) return true;
    if (_path.contains(idx)) return false;
    final headTier = widget.board.cells[_path.first]!.tier;
    if (t.tier != headTier) return false;
    return GameEngine.areOrthogonallyAdjacent(_path.last, idx);
  }

  void _onStart(Offset local) {
    final idx = _cellAt(local);
    if (idx != null && _canExtend(idx)) setState(() => _path
      ..clear()
      ..add(idx));
  }

  void _onUpdate(Offset local) {
    final idx = _cellAt(local);
    if (idx == null) return;
    // Backtrack: dragging onto the previous cell un-picks the last.
    if (_path.length >= 2 && idx == _path[_path.length - 2]) {
      setState(() => _path.removeLast());
      return;
    }
    if (_canExtend(idx)) setState(() => _path.add(idx));
  }

  void _onEnd() {
    if (_path.length >= 2) widget.onChain(List<int>.of(_path));
    setState(() => _path.clear());
  }
```

In `build`, keep `LayoutBuilder` and the existing `offsetFor`, store `_cell`/`_gap` into state for hit-testing, render walls as a distinct backing cell, highlight cells in `_path`, and wrap the `Stack` in a `GestureDetector`:

```dart
        _gap = gap;
        _cell = cell;
        // backing slots: render walls distinctly
        for (var i = 0; i < kCellCount; i++) {
          final pos = offsetFor(i);
          final isWall = widget.board.walls.contains(i);
          children.add(Positioned(
            left: pos.dx,
            top: pos.dy,
            child: isWall
                ? Container(
                    width: cell,
                    height: cell,
                    decoration: BoxDecoration(
                      color: const Color(0xFF3A3F52),
                      borderRadius: BorderRadius.circular(cell * 0.16),
                    ),
                    child: const Icon(Icons.block, color: Colors.white24),
                  )
                : GridCellWidget(
                    tile: null, size: cell, cosmetic: widget.cosmetic),
          ));
        }
        // floating tiles: add a glow when in the current path
        // (reuse the existing AnimatedPositioned loop; wrap the face in a
        //  DecoratedBox highlight when widget index is in _path).

        return GestureDetector(
          onPanStart: (d) => _onStart(d.localPosition),
          onPanUpdate: (d) => _onUpdate(d.localPosition),
          onPanEnd: (_) => _onEnd(),
          child: SizedBox(
            width: boardSize,
            height: boardSize,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF1E2230),
                borderRadius: BorderRadius.circular(gap * 1.5),
              ),
              child: Stack(children: children),
            ),
          ),
        );
```

Add `import '../../domain/engine/game_engine.dart';` and remove the now-unused `_DraggableTile`, `Draggable`, and `DragTarget` code. Replace the per-tile float widget with a plain `GridCellWidget` (optionally wrapped to show selection when `widget.board` index is in `_path`). Keep the `AnimatedPositioned` + `ValueKey(tile.id)` wrapper so merges/drops still animate.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/presentation/board_widget_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/presentation/widgets/board_widget.dart test/presentation/board_widget_test.dart
git commit -m "feat: replace drag-merge with path-drawing gesture and wall rendering"
```

---

### Task 14: Drop-queue rail widget

**Files:**
- Create: `lib/presentation/widgets/drop_queue_rail.dart`
- Test: `test/presentation/drop_queue_rail_test.dart`

**Interfaces:**
- Produces: `DropQueueRail({required List<int> tiers, Cosmetic cosmetic})` — renders one mini tile per upcoming tier, left-to-right, labelled `NEXT`.
- Consumes: `TilePalette.colorFor`, `Cosmetic`.

- [ ] **Step 1: Write the failing test**

Create `test/presentation/drop_queue_rail_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_count/presentation/widgets/drop_queue_rail.dart';

void main() {
  testWidgets('renders one chip per upcoming tier with its value', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: DropQueueRail(tiers: [1, 2, 3])),
    ));
    expect(find.text('2'), findsOneWidget); // 2^1
    expect(find.text('4'), findsOneWidget); // 2^2
    expect(find.text('8'), findsOneWidget); // 2^3
    expect(find.textContaining('NEXT'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/presentation/drop_queue_rail_test.dart`
Expected: FAIL — file missing.

- [ ] **Step 3: Create the widget**

Create `lib/presentation/widgets/drop_queue_rail.dart`:

```dart
import 'package:flutter/material.dart';

import '../../domain/models/cosmetic.dart';
import '../theme/tile_palette.dart';

/// Shows the next few drop tiers openly (the planning queue). Read-only flair.
class DropQueueRail extends StatelessWidget {
  final List<int> tiers;
  final Cosmetic cosmetic;

  const DropQueueRail({
    super.key,
    required this.tiers,
    this.cosmetic = Cosmetic.classic,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('NEXT  ',
            style: TextStyle(
                color: Colors.white54,
                fontSize: 12,
                letterSpacing: 2,
                fontWeight: FontWeight.w700)),
        for (final tier in tiers)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: TilePalette.colorFor(cosmetic, tier),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('${1 << tier}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold)),
            ),
          ),
      ],
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/presentation/drop_queue_rail_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/presentation/widgets/drop_queue_rail.dart test/presentation/drop_queue_rail_test.dart
git commit -m "feat: add drop-queue rail widget"
```

---

### Task 15: Objective banner widget

**Files:**
- Create: `lib/presentation/widgets/objective_banner.dart`
- Test: `test/presentation/objective_banner_test.dart`

**Interfaces:**
- Produces: `ObjectiveBanner({required DailyObjective objective, required int progress})` — shows `objective.label` and `progress/target`, marked done when met.
- Consumes: `DailyObjective` (Task 4).

- [ ] **Step 1: Write the failing test**

Create `test/presentation/objective_banner_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_count/domain/models/daily_objective.dart';
import 'package:merge_count/presentation/widgets/objective_banner.dart';

void main() {
  testWidgets('shows label and progress, and a done state when met',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ObjectiveBanner(
          objective: DailyObjective(kind: ObjectiveKind.chainLength, target: 5),
          progress: 3,
        ),
      ),
    ));
    expect(find.textContaining('Land a 5-chain'), findsOneWidget);
    expect(find.textContaining('3/5'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ObjectiveBanner(
          objective: DailyObjective(kind: ObjectiveKind.chainLength, target: 5),
          progress: 5,
        ),
      ),
    ));
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/presentation/objective_banner_test.dart`
Expected: FAIL — file missing.

- [ ] **Step 3: Create the widget**

Create `lib/presentation/widgets/objective_banner.dart`:

```dart
import 'package:flutter/material.dart';

import '../../domain/models/daily_objective.dart';

/// The day's bonus goal and progress. Read-only flair; reward is credited by the
/// cubit when met.
class ObjectiveBanner extends StatelessWidget {
  final DailyObjective objective;
  final int progress;

  const ObjectiveBanner({
    super.key,
    required this.objective,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final met = objective.isMet(progress);
    final shown = progress > objective.target ? objective.target : progress;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E2230),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(met ? Icons.check_circle : Icons.flag,
              size: 18, color: met ? Colors.greenAccent : Colors.white70),
          const SizedBox(width: 8),
          Text(objective.label,
              style: const TextStyle(color: Colors.white, fontSize: 13)),
          const SizedBox(width: 10),
          Text('$shown/${objective.target}',
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 13,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/presentation/objective_banner_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/presentation/widgets/objective_banner.dart test/presentation/objective_banner_test.dart
git commit -m "feat: add daily objective banner widget"
```

---

### Task 16: Wire `game_screen` to the new mechanic

**Files:**
- Modify: `lib/presentation/screens/game_screen.dart`
- Test: `test/presentation/board_widget_test.dart` already covers the gesture; add a smoke check if a `game_screen` test exists, otherwise rely on `flutter test` compiling the screen.

**Interfaces:**
- Consumes: `cubit.playChain(path)`, `cubit.peekDropTiers()`, `cubit.objective`; `DropQueueRail`, `ObjectiveBanner`.

- [ ] **Step 1: Update `_buildPlaying`**

In `lib/presentation/screens/game_screen.dart`:

(a) Add imports:

```dart
import '../widgets/drop_queue_rail.dart';
import '../widgets/objective_banner.dart';
```

(b) Replace the `BoardWidget(... onMerge: ...)` call with the path API:

```dart
                child: BoardWidget(
                  board: board,
                  cosmetic: _cosmetic,
                  colorblindMode: _colorblind,
                  onChain: (path) => cubit.playChain(path),
                ),
```

(c) Add the objective banner above `MovesCounter` and the drop-queue rail below the board. After the `difficulty.label` Text/SizedBox, insert:

```dart
          ObjectiveBanner(
              objective: cubit.objective, progress: board.objectiveProgress),
          const SizedBox(height: 8),
```

After the `Expanded(child: Center(... BoardWidget ...))`, add:

```dart
          const SizedBox(height: 12),
          DropQueueRail(tiers: cubit.peekDropTiers(), cosmetic: _cosmetic),
```

(d) The hint flow already exists; no change needed beyond it continuing to call `cubit.revealNextDropAfterReward()` (its lookahead semantics are a follow-up tuning; not required for v1 compile).

- [ ] **Step 2: Compile-check via the full suite**

Run: `flutter test`
Expected: PASS — the screen compiles against the new `onChain`/`playChain`/`peekDropTiers`/`objective` API and all widget/unit tests pass.

- [ ] **Step 3: Manual smoke (optional but recommended)**

Run: `flutter run` on a device/emulator; verify you can draw a path across adjacent equal tiles, the chain collapses, the queue updates, and the objective banner advances. (Use the `/run` skill if available.)

- [ ] **Step 4: Commit**

```bash
git add lib/presentation/screens/game_screen.dart
git commit -m "feat: wire game screen to Connect-Merge (path play, queue, objective)"
```

---

### Task 17: Leaderboard season (hard reset)

**Files:**
- Modify: `lib/infrastructure/leaderboard_service.dart`
- Test: `test/infrastructure/leaderboard_service_test.dart` (append)

**Interfaces:**
- Produces: every score submission carries `kLeaderboardSeason`, and reads filter to the current season, so pre-relaunch (season 1) scores never appear — an effective hard reset without deleting historical rows.
- Consumes: `kLeaderboardSeason` (Task 1).

- [ ] **Step 1: Read the service to find the submit/query shape**

Run: open `lib/infrastructure/leaderboard_service.dart` and `test/infrastructure/leaderboard_service_test.dart`. Identify the method that writes a score row (the Supabase insert/upsert payload) and the method that reads the ranked list (the select/filter). Note their exact names and the payload map keys.

- [ ] **Step 2: Write the failing test**

Append a test mirroring the file's existing test style (it uses a fake/mock Supabase or an injected client). Assert the submission payload includes `'season': kLeaderboardSeason` and that the read query filters by that season. Example shape (adapt to the file's actual fake):

```dart
test('submission tags the current leaderboard season', () async {
  final fake = FakeLeaderboardBackend(); // existing test double in this file
  final service = LeaderboardService(fake); // adapt to real constructor
  await service.submit(/* date, difficulty, score, ... as the API requires */);
  expect(fake.lastInsert['season'], kLeaderboardSeason);
});

test('reads only the current season', () async {
  final fake = FakeLeaderboardBackend()
    ..rows = [
      {'season': 1, 'score': 9999, 'name': 'old'},
      {'season': kLeaderboardSeason, 'score': 10, 'name': 'new'},
    ];
  final service = LeaderboardService(fake);
  final top = await service.topScores(/* date, difficulty */);
  expect(top.every((e) => e.name != 'old'), isTrue);
});
```

If the existing test file has no backend double, follow whatever injection the current tests use; do not invent a new abstraction.

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/infrastructure/leaderboard_service_test.dart`
Expected: FAIL — season not present in payload / old rows still returned.

- [ ] **Step 4: Implement**

In `lib/infrastructure/leaderboard_service.dart`, add `import '../domain/constants.dart';` (if absent). In the submit method, add `'season': kLeaderboardSeason` to the insert/upsert payload map. In the read method, add a `.eq('season', kLeaderboardSeason)` filter (Supabase) or the equivalent predicate the existing query uses. Keep all other columns/keys exactly as they are.

> Requires a one-time DB migration to add a nullable `season int` column (default 1) to the leaderboard table. Document it in the PR description; pre-existing rows become season 1 and are filtered out — the hard reset, with history preserved for an optional future Hall of Fame.

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/infrastructure/leaderboard_service_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/infrastructure/leaderboard_service.dart test/infrastructure/leaderboard_service_test.dart
git commit -m "feat: tag and filter leaderboard by season (Connect-Merge hard reset)"
```

---

### Task 18: Full-suite regression & determinism guard

**Files:**
- Test: `test/application/replay_determinism_test.dart` (create)

**Interfaces:**
- Consumes: `GameCubit.playChain`, `DailySeeder`, `ChainEvent`.

- [ ] **Step 1: Write a replay-determinism test**

Create `test/application/replay_determinism_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_count/application/game_cubit.dart';
import 'package:merge_count/application/game_state.dart';
import 'package:merge_count/domain/constants.dart';
import 'package:merge_count/domain/models/difficulty.dart';
import 'package:merge_count/infrastructure/storage_service.dart';

GameCubit freshCubit() => GameCubit(
    storage: InMemoryStorageService(), todayProvider: () => '2026-06-20');

void main() {
  test('same date+difficulty yields identical boards and identical play results',
      () async {
    final a = freshCubit();
    final b = freshCubit();
    await a.init(difficulty: Difficulty.medium);
    await b.init(difficulty: Difficulty.medium);

    final ba = (a.state as GamePlaying).board;
    final bb = (b.state as GamePlaying).board;
    // Identical seeded boards for two players.
    for (var i = 0; i < kCellCount; i++) {
      expect(ba.cells[i]?.tier, bb.cells[i]?.tier);
    }
    expect(ba.walls, bb.walls);
    expect(a.objective.kind, b.objective.kind);
    expect(a.objective.target, b.objective.target);

    // Same chain on both => same score + same queue afterward.
    int? from, to;
    for (var i = 0; i < kCellCount && from == null; i++) {
      final t = ba.cells[i];
      if (t == null || t.tier >= kMaxTier) continue;
      for (final n in [i + 1, i + kGridSize]) {
        if (n >= kCellCount) continue;
        if (n == i + 1 && (i % kGridSize) == kGridSize - 1) continue;
        final u = ba.cells[n];
        if (u != null && u.tier == t.tier) { from = i; to = n; break; }
      }
    }
    await a.playChain([from!, to!]);
    await b.playChain([from, to]);
    expect((a.state as GamePlaying).board.score,
        (b.state as GamePlaying).board.score);
    expect(a.peekDropTiers(), b.peekDropTiers());
  });
}
```

- [ ] **Step 2: Run it**

Run: `flutter test test/application/replay_determinism_test.dart`
Expected: PASS.

- [ ] **Step 3: Run the entire suite + analyzer**

Run: `flutter test`
Then: `flutter analyze`
Expected: All tests PASS; no analyzer errors. Fix any unused-import/dead-code warnings left by removing the `Draggable`/`DragTarget` path.

- [ ] **Step 4: Commit**

```bash
git add test/application/replay_determinism_test.dart
git commit -m "test: guard Connect-Merge replay determinism"
```

---

## Self-Review

**1. Spec coverage**

| Spec section | Task(s) |
|---|---|
| §3 Core mechanic (path, adjacency, +1 tier, endpoint) | 5, 7, 13 |
| §4 Scoring & combo (2^(T+1) × superlinear; 2-chain == legacy) | 1, 6 |
| §5 Drops/queue (visible 3-tier, top-up refill, on-demand stream, ad-hint lookahead) | 1, 10, 12, 14, 16 |
| §6 End/budget/deadlock (move budget, spatial deadlock) | 8, 12 |
| §7 Daily variety v1 (walls, objective) | 1, 4, 9, 10, 12, 15 |
| §8 Determinism/replay/migration (ChainEvent, version, additive fields, undo) | 2, 3, 11, 12, 18 |
| §9 Leaderboards (hard reset via season) | 1, 17 |
| §10 UI/UX (path gesture, live badge, queue rail, objective banner, walls, colorblind) | 13, 14, 15, 16 |

Gaps intentionally deferred (spec §7 v1.1/v1.2, §14 non-goals): bonus-multiplier cells, locked/decaying tiles, cross-move combo streak, landing-cell preview, diagonal days — not in this plan. The live chain badge (§10) is folded into Task 13's gesture layer as on-screen feedback; if a dedicated badge widget is wanted it is a trivial follow-up.

**2. Placeholder scan:** No "TBD"/"implement later" steps. Task 17 is the one task that begins with a read step because the leaderboard service internals were not inspected during planning; its transformation (add `season` to payload + filter reads) is concrete, with the read step only to bind exact method/key names.

**3. Type consistency:** `playChain(List<int>)`, `peekDropTiers([int])`, `objective` getter, `onChain(List<int>)`, `ChainEvent.path`, `BoardState.walls`/`objectiveProgress`, `DailyObjective.{kind,target,progressAfter,isMet,label}`, `GameEngine.{areOrthogonallyAdjacent,isValidChain,comboScore,collapseChain,hasMergeAvailable}`, `comboMultiplier`, `wallCountFor`, `DailySeeder.{wallIndices,dropTierPrng,dropTierAt,dailyObjective}`, `GameSnapshot.version` — all defined before first use and referenced consistently.
