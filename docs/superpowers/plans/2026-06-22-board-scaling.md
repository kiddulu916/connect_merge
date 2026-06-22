# Board Scaling + Deadlock Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the Connect-Merge deadlock bug by adding variable grid sizes per difficulty (8×8 → 6×6) and a refill guarantee that ensures a merge is always available after each chain collapse.

**Architecture:** `gridSize` moves from the global constant `kGridSize=5` to a field on the `Difficulty` enum, flows into `BoardState` as an optional field (default 5 for legacy test compatibility), then is read at runtime by all engine geometry methods. The refill loop in both `GameCubit` (Dart) and `verifyRun` (TypeScript) gains a `needsMerge` branch that keeps dropping until `hasMergeAvailable` is true, or the board is full.

**Tech Stack:** Flutter/Dart (client), Deno/TypeScript (Supabase Edge Functions), flutter_test, Deno test runner.

## Global Constraints

- `kSnapshotVersion` bumps 2 → 3 (old saves discarded on load).
- `kGridSize = 5` and `kCellCount = 25` remain in `constants.dart` **as legacy/test-only constants** — do NOT delete them; existing test helpers construct 5×5 boards and must keep compiling.
- `BoardState.gridSize` defaults to 5 so all existing `BoardState(cells: ..., ...)` constructors that don't pass `gridSize` compile unchanged.
- Dart and TypeScript refill loops must be byte-identical — any divergence causes valid client runs to be rejected by `verifyRun`.
- Grid sizes: easy=8, medium=7, hard=6, legendary=6. Fill: easy=40, medium=25, hard=20, legendary=15. Walls: easy=2, medium=4, hard=5, legendary=6.
- Do NOT change `kMovesPerDay`, `dropCap`, scoring, `kLeaderboardSeason`, ad-continue logic, or the objective system.

---

### Task 1: Core domain types — Difficulty, BoardState, constants

**Files:**
- Modify: `lib/domain/models/difficulty.dart`
- Modify: `lib/domain/models/board_state.dart`
- Modify: `lib/domain/constants.dart`
- Modify (tests): `test/domain/models/difficulty_test.dart`

**Interfaces:**
- Produces: `Difficulty.gridSize` (int), `Difficulty.cellCount` (int getter), updated `startingFill` values
- Produces: `BoardState.gridSize` (int, default 5), updated `copyWith` / `toJson` / `fromJson`
- Produces: `kSnapshotVersion = 3`, updated `wallCountFor`, legacy comments on `kGridSize`/`kCellCount`

- [ ] **Step 1: Write the failing tests for difficulty**

Update `test/domain/models/difficulty_test.dart` — replace the first test and add a gridSize test:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_count/domain/models/difficulty.dart';

void main() {
  test('starting tile counts are 40/25/20/15', () {
    expect(Difficulty.easy.startingFill, 40);
    expect(Difficulty.medium.startingFill, 25);
    expect(Difficulty.hard.startingFill, 20);
    expect(Difficulty.legendary.startingFill, 15);
  });

  test('grid sizes are 8/7/6/6', () {
    expect(Difficulty.easy.gridSize, 8);
    expect(Difficulty.medium.gridSize, 7);
    expect(Difficulty.hard.gridSize, 6);
    expect(Difficulty.legendary.gridSize, 6);
  });

  test('cellCount == gridSize * gridSize', () {
    for (final d in Difficulty.values) {
      expect(d.cellCount, d.gridSize * d.gridSize);
    }
  });

  test('labels map correctly', () {
    expect(Difficulty.easy.label, 'Easy');
    expect(Difficulty.medium.label, 'Medium');
    expect(Difficulty.hard.label, 'Hard');
    expect(Difficulty.legendary.label, 'Legendary');
  });

  test('names are the stable seed-key tokens', () {
    expect(Difficulty.easy.name, 'easy');
    expect(Difficulty.medium.name, 'medium');
    expect(Difficulty.hard.name, 'hard');
    expect(Difficulty.legendary.name, 'legendary');
  });

  test('there are exactly four tiers ordered easy -> legendary', () {
    expect(Difficulty.values, [
      Difficulty.easy,
      Difficulty.medium,
      Difficulty.hard,
      Difficulty.legendary,
    ]);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```
flutter test test/domain/models/difficulty_test.dart
```

Expected: FAIL — `'startingFill'` returns 10/8/6/4 (not 40/25/20/15) and `gridSize` getter doesn't exist.

- [ ] **Step 3: Implement difficulty.dart**

Replace `lib/domain/models/difficulty.dart` entirely:

```dart
enum Difficulty {
  easy(gridSize: 8, startingFill: 40, label: 'Easy'),
  medium(gridSize: 7, startingFill: 25, label: 'Medium'),
  hard(gridSize: 6, startingFill: 20, label: 'Hard'),
  legendary(gridSize: 6, startingFill: 15, label: 'Legendary');

  const Difficulty({
    required this.gridSize,
    required this.startingFill,
    required this.label,
  });

  final int gridSize;
  final int startingFill;
  final String label;

  int get cellCount => gridSize * gridSize;
}
```

- [ ] **Step 4: Add gridSize field to board_state.dart**

In `lib/domain/models/board_state.dart`:

Add `final int gridSize;` after the `walls` field (line ~22):

```dart
  /// Grid side length. Default 5 for legacy test boards that don't pass it.
  final int gridSize;
```

Add `this.gridSize = 5,` to the constructor (after `this.objectiveProgress = 0,`):

```dart
  const BoardState({
    required this.cells,
    required this.movesRemaining,
    required this.score,
    required this.nextTileId,
    required this.dropIndex,
    required this.adContinuesUsed,
    required this.movesMade,
    required this.status,
    this.moveLog = const [],
    this.walls = const {},
    this.objectiveProgress = 0,
    this.gridSize = 5,
  });
```

Add `int? gridSize,` to `copyWith` params and `gridSize: gridSize ?? this.gridSize,` to the returned object:

```dart
  BoardState copyWith({
    List<Tile?>? cells,
    int? movesRemaining,
    int? score,
    int? nextTileId,
    int? dropIndex,
    int? adContinuesUsed,
    int? movesMade,
    GameStatus? status,
    List<MoveEvent>? moveLog,
    Set<int>? walls,
    int? objectiveProgress,
    int? gridSize,
  }) {
    return BoardState(
      cells: cells ?? this.cells,
      movesRemaining: movesRemaining ?? this.movesRemaining,
      score: score ?? this.score,
      nextTileId: nextTileId ?? this.nextTileId,
      dropIndex: dropIndex ?? this.dropIndex,
      adContinuesUsed: adContinuesUsed ?? this.adContinuesUsed,
      movesMade: movesMade ?? this.movesMade,
      status: status ?? this.status,
      moveLog: moveLog ?? this.moveLog,
      walls: walls ?? this.walls,
      objectiveProgress: objectiveProgress ?? this.objectiveProgress,
      gridSize: gridSize ?? this.gridSize,
    );
  }
```

Update `toJson` — add `'gridSize': gridSize,` after the `objectiveProgress` line:

```dart
  Map<String, dynamic> toJson() => {
        'cells': cells.map((c) => c?.toJson()).toList(),
        'movesRemaining': movesRemaining,
        'score': score,
        'nextTileId': nextTileId,
        'dropIndex': dropIndex,
        'adContinuesUsed': adContinuesUsed,
        'movesMade': movesMade,
        'status': status.name,
        'moveLog': moveLog.map((e) => e.toJson()).toList(),
        if (walls.isNotEmpty) 'walls': walls.toList(),
        if (objectiveProgress != 0) 'objectiveProgress': objectiveProgress,
        'gridSize': gridSize,
      };
```

Update `fromJson` — add `gridSize: (j['gridSize'] as int?) ?? 5,` before the closing `)`:

```dart
  static BoardState fromJson(Map<String, dynamic> j) {
    final rawCells = j['cells'] as List;
    final rawLog = j['moveLog'] as List?;
    return BoardState(
      cells: rawCells
          .map((e) => e == null
              ? null
              : Tile.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      movesRemaining: j['movesRemaining'] as int,
      score: j['score'] as int,
      nextTileId: j['nextTileId'] as int,
      dropIndex: j['dropIndex'] as int,
      adContinuesUsed: j['adContinuesUsed'] as int,
      movesMade: j['movesMade'] as int,
      status: GameStatus.values.byName(j['status'] as String),
      moveLog: rawLog == null
          ? const []
          : rawLog
              .map((e) =>
                  MoveEvent.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList(),
      walls: ((j['walls'] as List?) ?? const [])
          .map((e) => e as int)
          .toSet(),
      objectiveProgress: (j['objectiveProgress'] as int?) ?? 0,
      gridSize: (j['gridSize'] as int?) ?? 5,
    );
  }
```

- [ ] **Step 5: Update constants.dart**

In `lib/domain/constants.dart`:

1. Change `kSnapshotVersion` from 2 to 3:
```dart
const int kSnapshotVersion = 3;
```

2. Add legacy comment to `kGridSize` and `kCellCount` (lines 7-8):
```dart
// Legacy constant — 5×5 test boards only. All game code now uses
// board.gridSize / board.cells.length or difficulty.gridSize / difficulty.cellCount.
const int kGridSize = 5;
const int kCellCount = kGridSize * kGridSize; // 25
```

3. Update `wallCountFor` (near the end):
```dart
int wallCountFor(Difficulty d) => switch (d) {
      Difficulty.easy => 2,
      Difficulty.medium => 4,
      Difficulty.hard => 5,
      Difficulty.legendary => 6,
    };
```

- [ ] **Step 6: Run tests to verify they pass**

```
flutter test test/domain/models/difficulty_test.dart
```

Expected: PASS (6 tests).

- [ ] **Step 7: Commit**

```bash
git add lib/domain/models/difficulty.dart lib/domain/models/board_state.dart lib/domain/constants.dart test/domain/models/difficulty_test.dart
git commit -m "feat: add gridSize to Difficulty enum + BoardState; bump kSnapshotVersion to 3"
```

---

### Task 2: Engine geometry — areOrthogonallyAdjacent, hasMergeAvailable, isValidChain

**Files:**
- Modify: `lib/domain/engine/game_engine.dart`
- Modify (fix compile errors): `test/domain/engine/game_engine_test.dart`

**Interfaces:**
- Consumes: `BoardState.gridSize` (from Task 1)
- Produces: `GameEngine.areOrthogonallyAdjacent(int a, int b, int gridSize)` — 3-param signature (breaking change)

**Note:** The 4 compile errors in `game_engine_test.dart` on the old 2-param `areOrthogonallyAdjacent` calls ARE the failing tests — the build itself fails until they're fixed.

- [ ] **Step 1: Fix the failing tests (update call sites)**

In `test/domain/engine/game_engine_test.dart`, find the `areOrthogonallyAdjacent` test (around line 143) and add the `gridSize` argument (5 for all — test boards are 5×5):

```dart
test('areOrthogonallyAdjacent: true for N/S/E/W, false for diagonal/wrap', () {
  expect(GameEngine.areOrthogonallyAdjacent(0, 1, 5), isTrue);          // E
  expect(GameEngine.areOrthogonallyAdjacent(0, kGridSize, 5), isTrue);  // S
  expect(GameEngine.areOrthogonallyAdjacent(0, kGridSize + 1, 5), isFalse); // diag
  expect(GameEngine.areOrthogonallyAdjacent(4, 5, 5), isFalse);        // row wrap
});
```

- [ ] **Step 2: Run tests to verify they fail (compile error)**

```
flutter test test/domain/engine/game_engine_test.dart
```

Expected: FAIL — compilation error `Too many positional arguments: 2 expected, but 3 found`.

- [ ] **Step 3: Update game_engine.dart**

In `lib/domain/engine/game_engine.dart`:

**a) `areOrthogonallyAdjacent` — add `int gridSize` param:**

```dart
  static bool areOrthogonallyAdjacent(int a, int b, int gridSize) {
    final ra = a ~/ gridSize, ca = a % gridSize;
    final rb = b ~/ gridSize, cb = b % gridSize;
    final dr = (ra - rb).abs(), dc = (ca - cb).abs();
    return (dr + dc) == 1;
  }
```

**b) `hasMergeAvailable` — use `s.gridSize` and `s.cells.length`:**

```dart
  static bool hasMergeAvailable(BoardState s) {
    final gs = s.gridSize;
    for (var i = 0; i < s.cells.length; i++) {
      final t = s.cells[i];
      if (t == null || t.tier >= kMaxTier) continue;
      final row = i ~/ gs, col = i % gs;
      if (col + 1 < gs) {
        final e = s.cells[i + 1];
        if (e != null && e.tier == t.tier) return true;
      }
      if (row + 1 < gs) {
        final so = s.cells[i + gs];
        if (so != null && so.tier == t.tier) return true;
      }
    }
    return false;
  }
```

**c) `isValidChain` — use `s.gridSize`, `s.cells.length`, and 3-arg `areOrthogonallyAdjacent`:**

```dart
  static bool isValidChain(BoardState s, List<int> path) {
    if (path.length < 2) return false;
    final seen = <int>{};
    final first = s.cells[path.first];
    if (first == null || first.tier >= kMaxTier || s.walls.contains(path.first)) return false;
    final tier = first.tier;
    for (var i = 0; i < path.length; i++) {
      final idx = path[i];
      if (idx < 0 || idx >= s.cells.length) return false;
      if (!seen.add(idx)) return false;
      if (s.walls.contains(idx)) return false;
      final t = s.cells[idx];
      if (t == null || t.tier != tier) return false;
      if (i > 0 && !areOrthogonallyAdjacent(path[i - 1], idx, s.gridSize)) return false;
    }
    return true;
  }
```

**d) `canExtend` call in `board_widget.dart` — will be fixed in Task 5, but note that `game_engine.dart` no longer imports `kCellCount` from the engine side. The `kMaxTier` import stays.** (Do not remove the `constants.dart` import — `kMaxTier` and `kGoldenMergeBonus` still come from there.)

- [ ] **Step 4: Run tests to verify they pass**

```
flutter test test/domain/engine/game_engine_test.dart
```

Expected: PASS — all existing geometry tests pass with the 3-arg signature.

- [ ] **Step 5: Commit**

```bash
git add lib/domain/engine/game_engine.dart test/domain/engine/game_engine_test.dart
git commit -m "feat(engine): parameterize areOrthogonallyAdjacent with gridSize; use board.gridSize in hasMergeAvailable/isValidChain"
```

---

### Task 3: Daily seeder (Dart)

**Files:**
- Modify: `lib/domain/engine/daily_seeder.dart`
- Modify (tests): `test/domain/engine/daily_seeder_test.dart`

**Interfaces:**
- Consumes: `Difficulty.gridSize`, `Difficulty.cellCount` (from Task 1)
- Consumes: `BoardState.gridSize` constructor param (from Task 1)
- Produces: `BoardState` from `generate()` with `gridSize` set to `difficulty.gridSize`

- [ ] **Step 1: Write the failing tests (gridSize on generated boards)**

In `test/domain/engine/daily_seeder_test.dart`:

Replace the hardcoded counts test (the one that says `'tile counts are 10/8/6/4'`) and add gridSize assertions:

```dart
  test('tile counts are 40/25/20/15 for easy/medium/hard/legendary', () {
    expect(const DailySeeder('2026-06-06', Difficulty.easy)
        .generate()
        .board
        .filledCount, 40);
    expect(const DailySeeder('2026-06-06', Difficulty.medium)
        .generate()
        .board
        .filledCount, 25);
    expect(const DailySeeder('2026-06-06', Difficulty.hard)
        .generate()
        .board
        .filledCount, 20);
    expect(const DailySeeder('2026-06-06', Difficulty.legendary)
        .generate()
        .board
        .filledCount, 15);
  });
```

Add this new test alongside the others:

```dart
  test('generated board has correct gridSize and cell count per difficulty', () {
    for (final d in Difficulty.values) {
      final board = DailySeeder('2026-06-06', d).generate().board;
      expect(board.gridSize, d.gridSize,
          reason: '${d.name} board.gridSize should be ${d.gridSize}');
      expect(board.cells.length, d.cellCount,
          reason: '${d.name} cells.length should be ${d.cellCount}');
    }
  });
```

- [ ] **Step 2: Run tests to verify they fail**

```
flutter test test/domain/engine/daily_seeder_test.dart
```

Expected: FAIL — hardcoded counts test fails (10/8/6/4 ≠ 40/25/20/15) and gridSize test fails (gridSize is 5, cells.length is 25 for all difficulties).

- [ ] **Step 3: Update daily_seeder.dart**

In `lib/domain/engine/daily_seeder.dart`:

**a) `wallIndices()` — use `difficulty.cellCount`:**

```dart
  Set<int> wallIndices() {
    final count = wallCountFor(difficulty);
    if (count == 0) return const {};
    final w = Prng(seedForKey('$_key:walls'));
    final out = <int>{};
    while (out.length < count) {
      out.add(w.nextInt(difficulty.cellCount));
    }
    return out;
  }
```

**b) `generate()` — use `difficulty.gridSize`/`difficulty.cellCount`; pass `gridSize` to both board constructions:**

```dart
  DailyStart generate() {
    final a = Prng(_seedA);
    final walls = wallIndices();
    final startingFill = difficulty.startingFill;
    final cellCount = difficulty.cellCount;

    const maxAttempts = 5000;
    List<Tile?> cells;
    int nextId;

    var attempts = 0;
    while (true) {
      attempts++;
      if (attempts > maxAttempts) {
        throw StateError(
          'DailySeeder.generate: could not find a non-deadlocked placement '
          'for $_key after $maxAttempts attempts. '
          'This indicates a pathological seed and must be investigated.',
        );
      }

      cells = List<Tile?>.filled(cellCount, null);
      nextId = 0;
      var placed = 0;
      while (placed < startingFill) {
        final idx = a.nextInt(cellCount);
        if (cells[idx] != null || walls.contains(idx)) continue;
        cells[idx] = Tile(id: nextId++, tier: 1 + a.nextInt(2));
        placed++;
      }

      final candidate = BoardState(
        cells: cells,
        movesRemaining: kMovesPerDay,
        score: 0,
        nextTileId: nextId,
        dropIndex: 0,
        adContinuesUsed: 0,
        movesMade: 0,
        status: GameStatus.playing,
        walls: walls,
        gridSize: difficulty.gridSize,
      );
      if (GameEngine.hasMergeAvailable(candidate)) break;
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
      gridSize: difficulty.gridSize,
    );
    return DailyStart(board, tiers);
  }
```

- [ ] **Step 4: Run tests to verify they pass**

```
flutter test test/domain/engine/daily_seeder_test.dart
```

Expected: PASS — all seeder tests pass including the new gridSize test.

- [ ] **Step 5: Commit**

```bash
git add lib/domain/engine/daily_seeder.dart test/domain/engine/daily_seeder_test.dart
git commit -m "feat(seeder): use difficulty.gridSize/cellCount in generate() and wallIndices()"
```

---

### Task 4: Refill deadlock guarantee (game_cubit.dart)

**Files:**
- Modify: `lib/application/game_cubit.dart`
- Modify (tests): `test/application/game_cubit_test.dart`

**Interfaces:**
- Consumes: `GameEngine.hasMergeAvailable(BoardState)` (from Task 2)
- Produces: Updated refill loop that continues dropping until both `filledCount >= targetFill` AND `hasMergeAvailable` are true (or board is full)

- [ ] **Step 1: Write the failing test**

Add this test to `test/application/game_cubit_test.dart`. It needs the existing `boardWith` helper and the cubit setup that already exists in that file. Add it in the `group` that tests `playChain`:

```dart
    test('refill guarantee: board always has a merge after each chain play', () async {
      // Helper: find any 2-cell chain (east or south neighbour) on the board.
      List<int>? findChain(BoardState board) {
        final gs = board.gridSize;
        final count = board.cells.length;
        for (var i = 0; i < count; i++) {
          final t = board.cells[i];
          if (t == null || t.tier >= kMaxTier) continue;
          final col = i % gs;
          final row = i ~/ gs;
          if (col + 1 < gs) {
            final e = board.cells[i + 1];
            if (e != null && e.tier == t.tier) return [i, i + 1];
          }
          if (row + 1 < gs) {
            final s = board.cells[i + gs];
            if (s != null && s.tier == t.tier) return [i, i + gs];
          }
        }
        return null;
      }

      // Play 8 chains from an Easy game (largest board, most tiles).
      // After each playChain, if the board is still "playing",
      // hasMergeAvailable MUST be true.
      await cubit.init(difficulty: Difficulty.easy);
      for (var move = 0; move < 8; move++) {
        final s = cubit.state;
        if (s is! GamePlaying) break;
        final chain = findChain(s.board);
        if (chain == null) {
          fail('Board deadlocked at move $move — refill guarantee failed');
        }
        await cubit.playChain(chain);
        final after = cubit.state;
        if (after is GamePlaying) {
          expect(
            GameEngine.hasMergeAvailable(after.board),
            isTrue,
            reason: 'hasMergeAvailable must be true after refill (move $move)',
          );
        }
      }
    });
```

Make sure the test file imports `Difficulty` and `GameEngine`:
```dart
import 'package:merge_count/domain/models/difficulty.dart';
import 'package:merge_count/domain/engine/game_engine.dart';
import 'package:merge_count/domain/constants.dart'; // for kMaxTier
```

- [ ] **Step 2: Run test to verify it fails**

```
flutter test test/application/game_cubit_test.dart --name "refill guarantee"
```

Expected: FAIL — test reports `hasMergeAvailable must be true after refill` or `Board deadlocked at move N`.

- [ ] **Step 3: Fix the refill loop in game_cubit.dart**

In `lib/application/game_cubit.dart`, find the refill loop (around line 284–294):

**Replace:**
```dart
    while (board.filledCount < targetFill && board.emptyIndices.isNotEmpty) {
      final tier = _seeder.dropTierAt(_dropTier, board.dropIndex);
      board = GameEngine.applyDrop(
        board,
        tier,
        _landing,
        golden: _goldenDrops.contains(board.dropIndex),
      );
    }
```

**With:**
```dart
    // Fill to targetFill AND guarantee at least one adjacent merge is available.
    // Stop only when the board is completely full (true deadlock → evaluateStatus).
    // Must mirror verifyRun's refill loop in supabase/functions/_shared/engine.ts.
    while (board.emptyIndices.isNotEmpty) {
      final needsFill = board.filledCount < targetFill;
      final needsMerge = !GameEngine.hasMergeAvailable(board);
      if (!needsFill && !needsMerge) break;
      final tier = _seeder.dropTierAt(_dropTier, board.dropIndex);
      board = GameEngine.applyDrop(
        board,
        tier,
        _landing,
        golden: _goldenDrops.contains(board.dropIndex),
      );
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```
flutter test test/application/game_cubit_test.dart
```

Expected: PASS — all cubit tests pass including the new refill guarantee test.

- [ ] **Step 5: Commit**

```bash
git add lib/application/game_cubit.dart test/application/game_cubit_test.dart
git commit -m "fix(cubit): refill loop guarantees hasMergeAvailable after every chain collapse"
```

---

### Task 5: Presentation widgets

**Files:**
- Modify: `lib/presentation/widgets/board_widget.dart`
- Modify: `lib/presentation/widgets/share_card.dart`
- Modify: `lib/domain/engine/share_grid_builder.dart`

**Interfaces:**
- Consumes: `BoardState.gridSize` (from Task 1)
- Consumes: `GameEngine.areOrthogonallyAdjacent(a, b, gridSize)` — 3-arg (from Task 2)
- No new interfaces produced — these are consumer-only changes

**Note:** `board_widget_test.dart` does NOT need code changes. Test boards use the default `gridSize=5`, and `kGridSize=5` stays in `constants.dart`, so the test's own cell-position math (which uses `kGridSize`) continues to match the widget behavior on 5×5 test boards.

- [ ] **Step 1: Update board_widget.dart**

In `lib/presentation/widgets/board_widget.dart`, make these replacements throughout the file:

**a) `_cellAt` method (line ~44):**
```dart
  int? _cellAt(Offset local) {
    final step = _cell + _gap;
    final count = widget.board.cells.length;
    final gs = widget.board.gridSize;
    for (var i = 0; i < count; i++) {
      final row = i ~/ gs, col = i % gs;
      final rect = Rect.fromLTWH(
          _gap + col * step, _gap + row * step, _cell, _cell);
      if (rect.contains(local)) return i;
    }
    return null;
  }
```

**b) `_canExtend` method (line ~61) — add `widget.board.gridSize` to `areOrthogonallyAdjacent`:**
```dart
    return GameEngine.areOrthogonallyAdjacent(_path.last, idx, widget.board.gridSize);
```

**c) `build` method layout math (line ~98):**
```dart
        final gs = widget.board.gridSize;
        final cell = (boardSize - gap * (gs + 1)) / gs;

        _gap = gap;
        _cell = cell;

        Offset offsetFor(int index) {
          final row = index ~/ gs;
          final col = index % gs;
          return Offset(gap + col * (cell + gap), gap + row * (cell + gap));
        }
```

**d) Both slot loops (lines ~113, ~136) — use `widget.board.cells.length`:**
```dart
        // Backing slots
        for (var i = 0; i < widget.board.cells.length; i++) {
```
```dart
        // Floating live tiles
        for (var i = 0; i < widget.board.cells.length; i++) {
```

Also remove the `kGridSize` and `kCellCount` usage. The import `import '../../domain/constants.dart';` can stay (it provides `kMaxTier` indirectly via `GridCellWidget`, but the direct `kGridSize`/`kCellCount` references are gone).

Full updated `build` method relevant section (replacing lines 94–113):

```dart
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 8.0;
        final boardSize = constraints.maxWidth;
        final gs = widget.board.gridSize;
        final cell = (boardSize - gap * (gs + 1)) / gs;

        _gap = gap;
        _cell = cell;

        Offset offsetFor(int index) {
          final row = index ~/ gs;
          final col = index % gs;
          return Offset(gap + col * (cell + gap), gap + row * (cell + gap));
        }

        final children = <Widget>[];

        for (var i = 0; i < widget.board.cells.length; i++) {
```

- [ ] **Step 2: Update share_card.dart**

In `lib/presentation/widgets/share_card.dart`, find where `kGridSize` (line ~179) and `kCellCount` (line ~184) are used inside `_MiniGrid` or the build method:

Replace `crossAxisCount: kGridSize` with `crossAxisCount: board.gridSize`.
Replace the loop bound `kCellCount` with `board.cells.length`.

The `board` variable in `share_card.dart` is `widget.board` or just `board` depending on which class/method it's in — use whatever the surrounding code uses.

- [ ] **Step 3: Update share_grid_builder.dart**

In `lib/domain/engine/share_grid_builder.dart`, replace all 4 uses of `kGridSize`:

```dart
  static String build({required String date, required BoardState board}) {
    final gs = board.gridSize;
    final best = board.highestTier;
    final sb = StringBuffer()
      ..writeln('Merge Count $date')
      ..writeln(
          'Score ${board.score} · Best ${emojiForTier(best)}${1 << best} · ${board.movesMade} moves');

    for (var r = 0; r < gs; r++) {
      for (var c = 0; c < gs; c++) {
        final tile = board.cells[r * gs + c];
        sb.write(tile == null ? '⬛' : emojiForTier(tile.tier));
      }
      if (r < gs - 1) sb.write('\n');
    }
    return sb.toString();
  }
```

Remove the `import '../constants.dart';` line from `share_grid_builder.dart` since `kGridSize` is no longer used. (`board_state.dart` is still needed.)

- [ ] **Step 4: Run flutter analyze**

```
flutter analyze lib/presentation/widgets/board_widget.dart lib/presentation/widgets/share_card.dart lib/domain/engine/share_grid_builder.dart
```

Expected: No issues on these files.

- [ ] **Step 5: Run the full test suite**

```
flutter test
```

Expected: PASS — all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/presentation/widgets/board_widget.dart lib/presentation/widgets/share_card.dart lib/domain/engine/share_grid_builder.dart
git commit -m "feat(ui): replace kGridSize/kCellCount with board.gridSize/cells.length in widgets"
```

---

### Task 6: TypeScript server parity

**Files:**
- Modify: `supabase/functions/_shared/constants.ts`
- Modify: `supabase/functions/_shared/engine.ts`
- Modify: `supabase/functions/_shared/seeder.ts`

**Interfaces:**
- Consumes: approved values from the spec (same as Task 1: fills 40/25/20/15, grids 8/7/6/6, walls 2/4/5/6)
- Produces: `BoardState.gridSize: number` (required field), `areOrthogonallyAdjacent(a, b, gridSize)` 3-arg, updated refill loop in `verifyRun`

**Critical:** The `verifyRun` refill loop must be byte-identical to the Dart loop from Task 4. Same condition, same order of checks.

- [ ] **Step 1: Update constants.ts**

In `supabase/functions/_shared/constants.ts`:

**a) Add `GRID_SIZE` export** (after `STARTING_FILL`):

```typescript
/** Grid side length per difficulty (port of Difficulty.gridSize in Dart). */
export const GRID_SIZE: Record<Difficulty, number> = {
  easy: 8,
  medium: 7,
  hard: 6,
  legendary: 6,
};
```

**b) Update `STARTING_FILL`:**

```typescript
export const STARTING_FILL: Record<Difficulty, number> = {
  easy: 40,
  medium: 25,
  hard: 20,
  legendary: 15,
};
```

**c) Update `WALL_COUNT`:**

```typescript
export const WALL_COUNT: Record<Difficulty, number> = {
  easy: 2,
  medium: 4,
  hard: 5,
  legendary: 6,
};
```

- [ ] **Step 2: Update engine.ts — BoardState, geometry functions, verifyRun refill loop**

In `supabase/functions/_shared/engine.ts`:

**a) Remove `kCellCount` and `kGridSize` from the import** (they are no longer used):

```typescript
import {
  comboMultiplier,
  type Difficulty,
  isDifficulty,
  kAdMoveReward,
  kMaxAdContinuesPerDay,
  kMaxTier,
  STARTING_FILL,
} from "./constants.ts";
```

**b) Add `gridSize: number` to `BoardState` interface:**

```typescript
export interface BoardState {
  cells: (Tile | null)[];
  walls: Set<number>;
  movesRemaining: number;
  score: number;
  nextTileId: number;
  dropIndex: number;
  adContinuesUsed: number;
  movesMade: number;
  status: GameStatus;
  gridSize: number;
}
```

**c) Update `areOrthogonallyAdjacent` — add `gridSize` param:**

```typescript
export function areOrthogonallyAdjacent(a: number, b: number, gridSize: number): boolean {
  const ra = Math.floor(a / gridSize), ca = a % gridSize;
  const rb = Math.floor(b / gridSize), cb = b % gridSize;
  return Math.abs(ra - rb) + Math.abs(ca - cb) === 1;
}
```

**d) Update `isValidChain` — use `s.cells.length` and 3-arg adjacent call:**

```typescript
export function isValidChain(s: BoardState, path: number[]): boolean {
  if (!Array.isArray(path) || path.length < 2) return false;
  const seen = new Set<number>();
  const first = s.cells[path[0]];
  if (first === undefined || first === null || first.tier >= kMaxTier) {
    return false;
  }
  const tier = first.tier;
  for (let i = 0; i < path.length; i++) {
    const idx = path[i];
    if (idx < 0 || idx >= s.cells.length) return false;
    if (seen.has(idx)) return false;
    seen.add(idx);
    const t = s.cells[idx];
    if (t === null || t === undefined || t.tier !== tier) return false;
    if (i > 0 && !areOrthogonallyAdjacent(path[i - 1], idx, s.gridSize)) return false;
  }
  return true;
}
```

**e) Update `hasMergeAvailable` — use `s.cells.length` and `s.gridSize`:**

```typescript
export function hasMergeAvailable(s: BoardState): boolean {
  const gs = s.gridSize;
  for (let i = 0; i < s.cells.length; i++) {
    const t = s.cells[i];
    if (t === null || t.tier >= kMaxTier) continue;
    const row = Math.floor(i / gs);
    const col = i % gs;
    if (col + 1 < gs) {
      const e = s.cells[i + 1];
      if (e !== null && e.tier === t.tier) return true;
    }
    if (row + 1 < gs) {
      const so = s.cells[i + gs];
      if (so !== null && so.tier === t.tier) return true;
    }
  }
  return false;
}
```

**f) Update the `verifyRun` refill loop** (replace the `while (filledCount(board) < startingFill ...` block):

```typescript
      // Mirror GameCubit new refill loop (Task 4): fill to startingFill AND
      // guarantee hasMergeAvailable, or stop when board is full.
      while (emptyIndices(board).length > 0) {
        const needsFill = filledCount(board) < startingFill;
        const needsMerge = !hasMergeAvailable(board);
        if (!needsFill && !needsMerge) break;
        const tier = seeder.dropTierAt(dropPrng, board.dropIndex);
        board = applyDrop(board, tier, landing);
      }
```

- [ ] **Step 3: Update seeder.ts — GRID_SIZE, cellCount, gridSize on board**

In `supabase/functions/_shared/seeder.ts`:

**a) Update imports** — remove `kCellCount` and `kGridSize`, add `GRID_SIZE`:

```typescript
import {
  type Difficulty,
  dropCap,
  GRID_SIZE,
  kMaxPlacementAttempts,
  kMaxTier,
  kMovesPerDay,
  STARTING_FILL,
  WALL_COUNT,
} from "./constants.ts";
```

**b) Update `hasAdjacentSameTier` — add `gridSize` param:**

```typescript
function hasAdjacentSameTier(cells: (Tile | null)[], gridSize: number): boolean {
  const cellCount = cells.length;
  for (let i = 0; i < cellCount; i++) {
    const t = cells[i];
    if (t === null || t.tier >= kMaxTier) continue;
    const row = Math.floor(i / gridSize);
    const col = i % gridSize;
    if (col + 1 < gridSize) {
      const e = cells[i + 1];
      if (e !== null && e.tier === t.tier) return true;
    }
    if (row + 1 < gridSize) {
      const s = cells[i + gridSize];
      if (s !== null && s.tier === t.tier) return true;
    }
  }
  return false;
}
```

**c) Update `wallIndices()` — use `GRID_SIZE` for cellCount:**

```typescript
  async wallIndices(): Promise<Set<number>> {
    const count = WALL_COUNT[this.difficulty];
    if (count === 0) return new Set();
    const gridSize = GRID_SIZE[this.difficulty];
    const cellCount = gridSize * gridSize;
    const w = new Prng(await seedForKey(`${this.key}:walls`));
    const out = new Set<number>();
    while (out.size < count) {
      out.add(w.nextInt(cellCount));
    }
    return out;
  }
```

**d) Update `generate()` — use `GRID_SIZE`, compute `cellCount`, add `gridSize` to board:**

```typescript
  async generate(): Promise<DailyStart> {
    const a = new Prng(await this.seedA());
    const walls = await this.wallIndices();
    const startingFill = STARTING_FILL[this.difficulty];
    const gridSize = GRID_SIZE[this.difficulty];
    const cellCount = gridSize * gridSize;

    let cells: (Tile | null)[] = [];
    let nextId = 0;
    let attempts = 0;
    while (true) {
      attempts += 1;
      if (attempts > kMaxPlacementAttempts) {
        throw new Error(
          `DailySeeder.generate: no non-deadlocked placement for ${this.key} ` +
            `after ${kMaxPlacementAttempts} attempts`,
        );
      }
      cells = new Array(cellCount).fill(null);
      nextId = 0;
      let placed = 0;
      while (placed < startingFill) {
        const idx = a.nextInt(cellCount);
        if (cells[idx] !== null || walls.has(idx)) continue;
        cells[idx] = { id: nextId++, tier: 1 + a.nextInt(2) };
        placed += 1;
      }
      if (hasAdjacentSameTier(cells, gridSize)) break;
    }

    const board: BoardState = {
      cells,
      walls,
      movesRemaining: kMovesPerDay,
      score: 0,
      nextTileId: nextId,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 0,
      status: "playing",
      gridSize,
    };
    return { board };
  }
```

- [ ] **Step 4: Run the TypeScript tests**

From the project root (or supabase functions directory):

```
deno test supabase/functions/_shared/
```

Expected: PASS — all existing engine and seeder tests pass.

If any test directly calls `areOrthogonallyAdjacent(a, b)` with 2 args, add the `gridSize` (5) as the third arg (these are 5×5 test boards).

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/_shared/constants.ts supabase/functions/_shared/engine.ts supabase/functions/_shared/seeder.ts
git commit -m "feat(server): port board-scaling + refill deadlock fix to TS; add GRID_SIZE; update verifyRun loop"
```

---

### Task 7: Simulation verification

**Files:**
- Modify: `test/domain/engine/deadlock_repro_test.dart`

**Goal:** Update the simulation harness to use `board.gridSize` (instead of `kGridSize`) and re-run it to confirm the deadlock rate drops dramatically with the new fills and larger boards.

- [ ] **Step 1: Update deadlock_repro_test.dart**

Find the `longestChain` helper (or any helper that iterates adjacency using `kGridSize`) and replace:

```dart
// Any occurrence of this pattern:
final col = i % kGridSize;
final row = i ~/ kGridSize;
if (col + 1 < kGridSize) { ... }
if (row + 1 < kGridSize) { ... i + kGridSize ... }
```

With:

```dart
final gs = board.gridSize;
final col = i % gs;
final row = i ~/ gs;
if (col + 1 < gs) { ... }
if (row + 1 < gs) { ... i + gs ... }
```

Pass `board` (or `board.gridSize`) to any helper that needs grid size, rather than using `kGridSize`.

- [ ] **Step 2: Run the simulation**

```
flutter test test/domain/engine/deadlock_repro_test.dart --reporter=expanded
```

Expected: PASS and the simulation output shows:
- Easy: median merges >> 5, dead-in-≤2 rate well below 20%
- Medium/Hard/Legendary: no longer deadlocking after 1-2 merges

- [ ] **Step 3: Run the full test suite one final time**

```
flutter test
```

Expected: PASS — all tests green.

- [ ] **Step 4: Commit**

```bash
git add test/domain/engine/deadlock_repro_test.dart
git commit -m "test: update deadlock simulation to use board.gridSize; verify fix"
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Covered by |
|---|---|
| gridSize per difficulty (8/7/6/6) | Task 1 (`difficulty.dart`) |
| startingFill (40/25/20/15) | Task 1 (`difficulty.dart`) |
| wallCountFor (2/4/5/6) | Task 1 (`constants.dart`) |
| kSnapshotVersion 2→3 | Task 1 (`constants.dart`) |
| BoardState.gridSize field (default 5) | Task 1 (`board_state.dart`) |
| areOrthogonallyAdjacent 3-param | Task 2 (`game_engine.dart`) |
| hasMergeAvailable uses s.gridSize | Task 2 (`game_engine.dart`) |
| isValidChain uses s.gridSize/s.cells.length | Task 2 (`game_engine.dart`) |
| daily_seeder.dart uses difficulty.gridSize/cellCount | Task 3 |
| BoardState from generate() has correct gridSize | Task 3 |
| Refill deadlock guarantee (Dart) | Task 4 (`game_cubit.dart`) |
| board_widget.dart uses board.gridSize | Task 5 |
| share_card.dart uses board.gridSize | Task 5 |
| share_grid_builder.dart uses board.gridSize | Task 5 |
| TS constants.ts: GRID_SIZE, updated STARTING_FILL/WALL_COUNT | Task 6 |
| TS engine.ts: BoardState.gridSize, updated geometry, verifyRun refill | Task 6 |
| TS seeder.ts: uses GRID_SIZE, gridSize on board | Task 6 |
| Simulation verification | Task 7 |

**Placeholder scan:** None found.

**Type consistency:** All tasks use `board.gridSize` (Dart) / `s.gridSize` (TS) consistently. `areOrthogonallyAdjacent` always takes `gridSize` as the 3rd positional argument in both languages.
