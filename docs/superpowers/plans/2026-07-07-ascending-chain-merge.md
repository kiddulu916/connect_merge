# Ascending Chain Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Connect-Merge chains ascend one tier at a time (never skip, never descend) instead of requiring every tile in the path to share one tier, with an additive score bonus per ascend transition, mirrored into the server-side replay validator and gated behind a leaderboard season bump.

**Architecture:** A single per-step validity rule change in the pure `GameEngine` (`isValidChain`, `canMerge`), a matching additive scoring term in `collapseChain`, a deadlock-detection fix (`hasMergeAvailable`) so ascend-only boards aren't misreported as stuck, a drag-gesture update in `BoardWidget` so the UI never lets a player drag a path the engine would reject, and a byte-for-byte mirror of all of the above into the hand-maintained TypeScript replay validator (`supabase/functions/_shared/engine.ts`) that the leaderboard submission Edge Function uses.

**Tech Stack:** Flutter/Dart (client + pure engine), Deno/TypeScript (Supabase Edge Function replay validator), `flutter_test` (widget + unit tests), `deno test` (TS unit tests).

## Global Constraints

- Ascend rule: a chain step's tier delta from the previous tile must be `0` (same tier) or `1` (ascend); any other delta invalidates the whole chain. Direction is fixed by drag order — descending is always invalid.
- Result tier is unchanged in meaning: the chain's endpoint (`path.last`, now always the peak since the path is non-decreasing) becomes `peakTier + 1`. The `kMaxTier` cap check applies to the peak tile, not the first tile.
- Scoring: base score stays `comboScore(mergedTier, chainLength) = (1 << (mergedTier + 1)) * comboMultiplier(chainLength)`, unchanged. A new additive `ascendBonus(intoTier) = 1 << intoTier` is added once per ascend transition in the path (delta `== 1` between consecutive path entries).
- The legacy pairwise API (`GameEngine.canMerge`/`merge` — Dart only, no TS equivalent) gets the same delta rule for `canMerge`; `merge()`'s body is unchanged.
- `hasMergeAvailable` must treat any orthogonally-adjacent pair whose tiers differ by at most 1 (with the higher tile below `kMaxTier`) as a legal move, not just exact-tier-equal pairs.
- The drag UI (`BoardWidget._canExtend`) must mirror `isValidChain`'s per-step rule exactly (compare against `_path.last`, not `_path.first`).
- An ascend step in the active drag path gets a distinct visual cue: amber glow (`Colors.amber.withValues(alpha: 0.6)`) instead of the existing white glow (`Colors.white.withValues(alpha: 0.45)`).
- `supabase/functions/_shared/engine.ts` and `supabase/functions/_shared/constants.ts` must mirror every Dart engine/constants change in this plan — they are a hand-maintained TS port with no shared source, and the server rejects any chain the TS copy doesn't recognize as valid.
- `kLeaderboardSeason` bumps from `2` to `3` in both `lib/domain/constants.dart` and `supabase/functions/_shared/constants.ts` as the final task, so pre-change and post-change scores never mix on the same leaderboard. No database migration is needed — the `scores` table and all three leaderboard RPCs already take `season` as a parameter.
- No new cap on total chain "span" (e.g. tier1→tier8 in one drag is allowed).

---

### Task 1: `ascendBonus` pure function (Dart constants)

**Files:**
- Modify: `lib/domain/constants.dart:123` (insert after `comboMultiplier`, before the `kDropQueueVisible` comment block)
- Test: `test/domain/constants_test.dart`

**Interfaces:**
- Produces: `int ascendBonus(int intoTier)` — used by `GameEngine.collapseChain` in Task 3.

- [ ] **Step 1: Write the failing test**

In `test/domain/constants_test.dart`, inside the existing `group('Connect-Merge constants', ...)` block, add a new test right after the `comboMultiplier` test (after the closing `});` of that test, before `wall count increases...`):

```dart
    test('ascendBonus mirrors the tile-value convention (2^intoTier)', () {
      expect(ascendBonus(1), 2);
      expect(ascendBonus(2), 4);
      expect(ascendBonus(3), 8);
      expect(ascendBonus(10), 1 << 10);
    });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/domain/constants_test.dart`
Expected: FAIL — `ascendBonus` isn't defined.

- [ ] **Step 3: Implement `ascendBonus`**

In `lib/domain/constants.dart`, immediately after the `comboMultiplier` function (after its closing `}` at line 123) and before the `kDropQueueVisible` doc comment, insert:

```dart

/// Connect-Merge — bonus added once per ascend transition inside a chain (a
/// step where the next tile's tier is exactly one higher than the previous
/// tile's). Uses the same power-of-two convention as tile values, so
/// stepping into a higher tier mid-chain pays out more. Pure tuning knob.
int ascendBonus(int intoTier) => 1 << intoTier;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/domain/constants_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/domain/constants.dart test/domain/constants_test.dart
git commit -m "feat(engine): add ascendBonus scoring constant"
```

---

### Task 2: Relax merge validity — `isValidChain` and `canMerge` (Dart engine)

**Files:**
- Modify: `lib/domain/engine/game_engine.dart:13-19` (`canMerge`), `lib/domain/engine/game_engine.dart:132-152` (`isValidChain`)
- Test: `test/domain/engine/game_engine_test.dart`

**Interfaces:**
- Consumes: nothing new.
- Produces: `GameEngine.canMerge`/`GameEngine.isValidChain` now accept ascend-by-1 steps. `GameEngine.collapseChain` (Task 3) and `BoardWidget._canExtend` (Task 5) depend on this rule being in place first.

- [ ] **Step 1: Write the failing tests**

In `test/domain/engine/game_engine_test.dart`, replace the existing `canMerge` test (lines 25-37):

```dart
  test('canMerge: same tier, distinct cells, below max tier', () {
```

...through its closing `});`, with:

```dart
  test('canMerge: same tier or ascend-by-1 into a higher-tier destination, below max tier', () {
    final b = boardWith({
      0: const Tile(id: 1, tier: 3),
      1: const Tile(id: 2, tier: 3),
      2: const Tile(id: 3, tier: 4),
      3: const Tile(id: 4, tier: kMaxTier),
      4: const Tile(id: 5, tier: kMaxTier),
      5: const Tile(id: 6, tier: 6),
    });
    expect(GameEngine.canMerge(b, 0, 1), isTrue); // same tier
    expect(GameEngine.canMerge(b, 0, 2), isTrue); // ascend by 1 (3 -> 4)
    expect(GameEngine.canMerge(b, 2, 0), isFalse); // descend (4 -> 3)
    expect(GameEngine.canMerge(b, 0, 5), isFalse); // skips a tier (3 -> 6)
    expect(GameEngine.canMerge(b, 0, 0), isFalse); // same cell
    expect(GameEngine.canMerge(b, 3, 4), isFalse); // at max tier
  });
```

Then, inside `group('Connect-Merge path validation', ...)`, replace the test `'isValidChain: rejects length<2, mixed tier, gaps, repeats, walls'` (lines 159-172):

```dart
    test('isValidChain: rejects length<2, mixed tier, gaps, repeats, walls', () {
```

...through its closing `});`, with:

```dart
    test('isValidChain: rejects length<2, non-adjacent, repeats, empty cells', () {
      final b = boardWith({
        0: const Tile(id: 1, tier: 2),
        1: const Tile(id: 2, tier: 2),
        6: const Tile(id: 4, tier: 2),
      });
      expect(GameEngine.isValidChain(b, [0]), isFalse); // too short
      expect(GameEngine.isValidChain(b, [0, 6]), isFalse); // not adjacent
      expect(GameEngine.isValidChain(b, [0, 1, 0]), isFalse); // repeat
      final empty = boardWith({0: const Tile(id: 1, tier: 2)});
      expect(GameEngine.isValidChain(empty, [0, 1]), isFalse); // cell 1 empty
    });

    test('isValidChain: accepts an ascend-by-1 step, rejects descend and skip', () {
      final b = boardWith({
        0: const Tile(id: 1, tier: 2),
        1: const Tile(id: 2, tier: 3), // east of 0, one tier higher
        2: const Tile(id: 3, tier: 5), // east of 1, skips a tier
      });
      expect(GameEngine.isValidChain(b, [0, 1]), isTrue); // ascend by 1
      expect(GameEngine.isValidChain(b, [1, 0]), isFalse); // descend (3 -> 2)
      expect(GameEngine.isValidChain(b, [1, 2]), isFalse); // skip (3 -> 5)
    });

    test('isValidChain: accepts a run-then-ascend-then-run chain', () {
      // tier1 run (0,1,6) -> ascend -> tier2 run (7,8) -> ascend -> tier3 peak (13)
      final b = boardWith({
        0: const Tile(id: 1, tier: 1),
        1: const Tile(id: 2, tier: 1),
        6: const Tile(id: 3, tier: 1),
        7: const Tile(id: 4, tier: 2),
        8: const Tile(id: 5, tier: 2),
        13: const Tile(id: 6, tier: 3),
      });
      expect(GameEngine.isValidChain(b, [0, 1, 6, 7, 8, 13]), isTrue);
    });
```

Finally, right after the existing test `'isValidChain: rejects a chain at max tier'` (lines 192-198, keep it unchanged), add a new test immediately below it (still inside the same `group`, before the group's closing `});`):

```dart

    test('isValidChain: rejects an ascend chain whose peak sits at max tier', () {
      final b = boardWith({
        0: const Tile(id: 1, tier: kMaxTier - 1),
        1: const Tile(id: 2, tier: kMaxTier),
      });
      expect(GameEngine.isValidChain(b, [0, 1]), isFalse);
    });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/domain/engine/game_engine_test.dart`
Expected: FAIL — the new ascend/descend/skip assertions don't match current same-tier-only behavior.

- [ ] **Step 3: Implement the rule change**

In `lib/domain/engine/game_engine.dart`, replace `canMerge` (lines 11-19):

```dart
  /// A legal merge: both cells hold tiles, distinct cells, equal tier, and the
  /// tier is below the cap (two max-tier tiles cannot fuse further).
  static bool canMerge(BoardState s, int fromIndex, int toIndex) {
    if (fromIndex == toIndex) return false;
    final from = s.cells[fromIndex];
    final to = s.cells[toIndex];
    if (from == null || to == null) return false;
    return from.tier == to.tier && from.tier < kMaxTier;
  }
```

with:

```dart
  /// A legal merge: both cells hold tiles, distinct cells, and [toIndex]'s
  /// tier is either equal to or exactly one higher than [fromIndex]'s tier
  /// (same-tier merge, or ascend-by-1 into the destination), below the cap.
  static bool canMerge(BoardState s, int fromIndex, int toIndex) {
    if (fromIndex == toIndex) return false;
    final from = s.cells[fromIndex];
    final to = s.cells[toIndex];
    if (from == null || to == null) return false;
    final delta = to.tier - from.tier;
    return delta >= 0 && delta <= 1 && to.tier < kMaxTier;
  }
```

Then replace `isValidChain` (lines 132-152):

```dart
  /// A legal Connect-Merge path: length >= 2, no repeated cells, each cell holds
  /// a live tile, all tiles share one tier below the cap, and consecutive cells
  /// are orthogonally adjacent. Walls hold no tile, so they are rejected by the
  /// null-cell check, but we never index a wall as a tile.
  static bool isValidChain(BoardState s, List<int> path) {
    if (path.length < 2) return false;
    final seen = <int>{};
    final first = s.cells[path.first];
    if (first == null || first.tier >= kMaxTier || s.walls.contains(path.first)) return false;
    final tier = first.tier;
    for (var i = 0; i < path.length; i++) {
      final idx = path[i];
      if (idx < 0 || idx >= s.cells.length) return false;
      if (!seen.add(idx)) return false; // repeat
      if (s.walls.contains(idx)) return false; // reject walls
      final t = s.cells[idx];
      if (t == null || t.tier != tier) return false;
      if (i > 0 && !areOrthogonallyAdjacent(path[i - 1], idx, s.gridSize)) return false;
    }
    return true;
  }
```

with:

```dart
  /// A legal Connect-Merge path: length >= 2, no repeated cells, each cell
  /// holds a live tile, consecutive cells are orthogonally adjacent, and each
  /// step's tier is either equal to or exactly one higher than the previous
  /// tile's tier (never descends, never skips a tier). Since the path is thus
  /// non-decreasing, [path.last] is always the peak tile, and it alone must
  /// sit below the cap. Walls hold no tile, so they are rejected by the
  /// null-cell check, but we never index a wall as a tile.
  static bool isValidChain(BoardState s, List<int> path) {
    if (path.length < 2) return false;
    final seen = <int>{};
    Tile? prevTile;
    for (var i = 0; i < path.length; i++) {
      final idx = path[i];
      if (idx < 0 || idx >= s.cells.length) return false;
      if (!seen.add(idx)) return false; // repeat
      if (s.walls.contains(idx)) return false; // reject walls
      final t = s.cells[idx];
      if (t == null) return false;
      if (prevTile != null) {
        final delta = t.tier - prevTile.tier;
        if (delta < 0 || delta > 1) return false; // no descend, no tier skip
        if (!areOrthogonallyAdjacent(path[i - 1], idx, s.gridSize)) return false;
      }
      prevTile = t;
    }
    if (prevTile!.tier >= kMaxTier) return false; // peak tile must be below cap
    return true;
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/domain/engine/game_engine_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/domain/engine/game_engine.dart test/domain/engine/game_engine_test.dart
git commit -m "feat(engine): allow chains and pairwise merges to ascend one tier"
```

---

### Task 3: Ascend-bonus scoring in `collapseChain` (Dart engine)

**Files:**
- Modify: `lib/domain/engine/game_engine.dart:160-189` (`collapseChain`)
- Test: `test/domain/engine/game_engine_test.dart`

**Interfaces:**
- Consumes: `ascendBonus(int intoTier)` from Task 1; the ascend rule from Task 2 (so ascending paths reach this function at all).
- Produces: `GameEngine.collapseChain` now returns a board whose `score` includes the ascend bonus. No signature change.

- [ ] **Step 1: Write the failing tests**

In `test/domain/engine/game_engine_test.dart`, inside `group('Connect-Merge collapse', ...)`, add two new tests after the existing `'collapse: a 2-path matches the legacy merge result'` test, before the group's closing `});`:

```dart

    test('collapse: ascending chain scores base combo PLUS an ascend bonus per transition', () {
      final b = boardWith({
        0: const Tile(id: 10, tier: 1),
        1: const Tile(id: 11, tier: 1),
        6: const Tile(id: 12, tier: 2), // ascend into tier 2
        7: const Tile(id: 13, tier: 2),
        8: const Tile(id: 14, tier: 3), // ascend into tier 3 (endpoint)
      });
      final r = GameEngine.collapseChain(b, [0, 1, 6, 7, 8]);
      expect(r.cells[8]!.tier, 4); // peak tier 3 + 1
      final expectedBase = GameEngine.comboScore(3, 5);
      final expectedAscend = ascendBonus(2) + ascendBonus(3);
      expect(r.score, expectedBase + expectedAscend);
    });

    test('collapse: a flat (same-tier) chain has zero ascend bonus', () {
      final b = boardWith({
        0: const Tile(id: 10, tier: 2),
        1: const Tile(id: 11, tier: 2),
      });
      final r = GameEngine.collapseChain(b, [0, 1]);
      expect(r.score, GameEngine.comboScore(2, 2));
    });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/domain/engine/game_engine_test.dart`
Expected: FAIL — the ascending-chain test's score is short by `ascendBonus(2) + ascendBonus(3)`.

- [ ] **Step 3: Implement the ascend bonus**

In `lib/domain/engine/game_engine.dart`, replace `collapseChain` (lines 160-189):

```dart
  static BoardState collapseChain(
    BoardState s,
    List<int> path, {
    int Function(int)? comboMultiplierFn,
  }) {
    final endIdx = path.last;
    final endTile = s.cells[endIdx]!;
    final mergedTier = endTile.tier;
    final newTier = mergedTier + 1;
    final cells = List<Tile?>.of(s.cells);
    for (final idx in path) {
      cells[idx] = null;
    }
    cells[endIdx] = Tile(id: endTile.id, tier: newTier);
    final fn = comboMultiplierFn ?? comboMultiplier;
    return s.copyWith(
      cells: cells,
      score: s.score + (1 << (mergedTier + 1)) * fn(path.length),
      movesRemaining: s.movesRemaining - 1,
      movesMade: s.movesMade + 1,
    );
  }
```

with:

```dart
  static BoardState collapseChain(
    BoardState s,
    List<int> path, {
    int Function(int)? comboMultiplierFn,
  }) {
    final endIdx = path.last;
    final endTile = s.cells[endIdx]!;
    final mergedTier = endTile.tier;
    final newTier = mergedTier + 1;
    var ascendTotal = 0;
    for (var i = 1; i < path.length; i++) {
      final prevTier = s.cells[path[i - 1]]!.tier;
      final curTier = s.cells[path[i]]!.tier;
      if (curTier == prevTier + 1) {
        ascendTotal += ascendBonus(curTier);
      }
    }
    final cells = List<Tile?>.of(s.cells);
    for (final idx in path) {
      cells[idx] = null;
    }
    cells[endIdx] = Tile(id: endTile.id, tier: newTier);
    final fn = comboMultiplierFn ?? comboMultiplier;
    return s.copyWith(
      cells: cells,
      score: s.score + (1 << (mergedTier + 1)) * fn(path.length) + ascendTotal,
      movesRemaining: s.movesRemaining - 1,
      movesMade: s.movesMade + 1,
    );
  }
```

Also update the doc comment directly above `collapseChain` (the one starting `/// Collapse a validated Connect-Merge [path] onto its endpoint...`) to mention the ascend bonus:

```dart
  /// Collapse a validated Connect-Merge [path] onto its endpoint (`path.last`):
  /// the endpoint becomes tier+1 (keeping its id for animation continuity), all
  /// other path cells empty, score gains the combo total PLUS an
  /// [ascendBonus] for every ascend transition in the path, one move is spent.
  /// Caller must have checked [isValidChain]. Mirrors [merge]: no drop, no log
  /// (the cubit applies the refill and records the [ChainEvent]).
  ///
  /// [comboMultiplierFn] overrides the default [comboMultiplier] for challenge
  /// rules (e.g. [comboRushMultiplier] for the Combo Rush rule).
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/domain/engine/game_engine_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/domain/engine/game_engine.dart test/domain/engine/game_engine_test.dart
git commit -m "feat(engine): add ascend-transition bonus to chain collapse scoring"
```

---

### Task 4: Deadlock detection for ascend-adjacent pairs (Dart engine)

**Files:**
- Modify: `lib/domain/engine/game_engine.dart:90-110` (`hasMergeAvailable`)
- Test: `test/domain/engine/game_engine_test.dart`

**Interfaces:**
- Consumes: nothing new from earlier tasks (independent rule fix, but must match Task 2's `canMerge` semantics).
- Produces: `GameEngine.hasMergeAvailable` now also returns `true` for an ascend-adjacent pair. No signature change. A private `GameEngine._pairMergeable` helper is added (not part of the public interface).

- [ ] **Step 1: Write the failing tests**

In `test/domain/engine/game_engine_test.dart`, right after the existing test `'hasMergeAvailable: needs ADJACENT equal tiles, not just any pair'` (ends at line 80), add three new top-level tests:

```dart

  test('hasMergeAvailable: also finds an ascend-adjacent pair (differs by exactly 1 tier)', () {
    final b = boardWith({
      0: const Tile(id: 1, tier: 2),
      1: const Tile(id: 2, tier: 3), // east neighbour, one tier higher
    });
    expect(GameEngine.hasMergeAvailable(b), isTrue);
    expect(GameEngine.evaluateStatus(b).status, GameStatus.playing);
  });

  test('hasMergeAvailable: does NOT treat a 2-tier gap as available', () {
    final b = boardWith({
      0: const Tile(id: 1, tier: 2),
      1: const Tile(id: 2, tier: 4), // east neighbour, two tiers higher
    });
    expect(GameEngine.hasMergeAvailable(b), isFalse);
    expect(GameEngine.evaluateStatus(b).status, GameStatus.deadlocked);
  });

  test('hasMergeAvailable: an ascend pair sitting at the cap is NOT available', () {
    final b = boardWith({
      0: const Tile(id: 1, tier: kMaxTier - 1),
      1: const Tile(id: 2, tier: kMaxTier),
    });
    expect(GameEngine.hasMergeAvailable(b), isFalse);
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/domain/engine/game_engine_test.dart`
Expected: FAIL — `hasMergeAvailable` still requires exact tier equality.

- [ ] **Step 3: Implement the fix**

In `lib/domain/engine/game_engine.dart`, replace `hasMergeAvailable` (lines 90-110):

```dart
  /// True if any two orthogonally-adjacent live tiles share a tier below the cap
  /// (a legal Connect-Merge of length 2). Position now matters: equal tiles that
  /// are not adjacent do NOT count, so a player can strand tiles into a deadlock.
  static bool hasMergeAvailable(BoardState s) {
    final gs = s.gridSize;
    for (var i = 0; i < s.cells.length; i++) {
      final t = s.cells[i];
      if (t == null || t.tier >= kMaxTier) continue;
      final row = i ~/ gs, col = i % gs;
      // Check east and south neighbours only (covers every adjacency once).
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

with:

```dart
  /// True if any two orthogonally-adjacent live tiles could legally merge in
  /// SOME direction (a legal Connect-Merge of length 2): their tiers differ by
  /// at most one, and the higher of the two is below the cap. Position matters:
  /// a mergeable pair that is not adjacent does NOT count, so a player can
  /// strand tiles into a deadlock.
  static bool hasMergeAvailable(BoardState s) {
    final gs = s.gridSize;
    for (var i = 0; i < s.cells.length; i++) {
      final t = s.cells[i];
      if (t == null) continue;
      final row = i ~/ gs, col = i % gs;
      // Check east and south neighbours only (covers every adjacency once).
      if (col + 1 < gs) {
        final e = s.cells[i + 1];
        if (e != null && _pairMergeable(t, e)) return true;
      }
      if (row + 1 < gs) {
        final so = s.cells[i + gs];
        if (so != null && _pairMergeable(t, so)) return true;
      }
    }
    return false;
  }

  /// True if two adjacent tiles could legally merge in SOME direction: their
  /// tiers differ by at most one, and the higher of the two is below the cap
  /// (the higher tile is always the destination, per [canMerge]/[isValidChain]).
  static bool _pairMergeable(Tile a, Tile b) {
    final delta = (a.tier - b.tier).abs();
    if (delta > 1) return false;
    final higher = a.tier > b.tier ? a.tier : b.tier;
    return higher < kMaxTier;
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/domain/engine/game_engine_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/domain/engine/game_engine.dart test/domain/engine/game_engine_test.dart
git commit -m "fix(engine): detect ascend-adjacent pairs in deadlock check"
```

---

### Task 5: Drag UI accepts ascend-by-1 extensions (`BoardWidget`)

**Files:**
- Modify: `lib/presentation/widgets/board_widget.dart:55-64` (`_canExtend`)
- Test: `test/presentation/board_widget_test.dart`

**Interfaces:**
- Consumes: `GameEngine.areOrthogonallyAdjacent` (already used here); the ascend rule from Task 2 (this task keeps the UI in lockstep with it).
- Produces: `_canExtend` now allows extending the drag path onto a cell one tier higher than `_path.last`, in addition to equal tier.

- [ ] **Step 1: Write the failing tests**

In `test/presentation/board_widget_test.dart`, add two new `testWidgets` after the existing `'dragging across two adjacent equal tiles reports a 2-path'` test, before the closing `}` of `main()`:

```dart

  testWidgets('dragging from a lower tier onto an adjacent higher tier extends the path (ascend)',
      (tester) async {
    final cells = List<Tile?>.filled(kCellCount, null);
    cells[0] = const Tile(id: 1, tier: 2);
    cells[1] = const Tile(id: 2, tier: 3); // east neighbour, one tier higher
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

  testWidgets('dragging from a higher tier onto an adjacent lower tier does NOT extend (descend)',
      (tester) async {
    final cells = List<Tile?>.filled(kCellCount, null);
    cells[0] = const Tile(id: 1, tier: 3);
    cells[1] = const Tile(id: 2, tier: 2); // east neighbour, one tier lower
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

    // The drag never extended past the start cell, so a lone-cell path never
    // fires onChain (BoardWidget._onEnd requires length >= 2).
    expect(reported, isNull);
  });
```

- [ ] **Step 2: Run tests to verify the ascend test fails**

Run: `flutter test test/presentation/board_widget_test.dart`
Expected: the ascend test FAILS (`reported` is `null` because `_canExtend` currently requires exact tier equality to `headTier`); the descend test currently PASSES by coincidence (already rejected, just for the wrong future-proof reason) — that's fine, it's here to pin the behavior going forward.

- [ ] **Step 3: Implement the fix**

In `lib/presentation/widgets/board_widget.dart`, replace `_canExtend` (lines 55-64):

```dart
  bool _canExtend(int idx) {
    if (widget.board.walls.contains(idx)) return false;
    final t = widget.board.cells[idx];
    if (t == null || t.tier >= kMaxTier) return false;
    if (_path.isEmpty) return true;
    if (_path.contains(idx)) return false;
    final headTier = widget.board.cells[_path.first]!.tier;
    if (t.tier != headTier) return false;
    return GameEngine.areOrthogonallyAdjacent(_path.last, idx, widget.board.gridSize);
  }
```

with:

```dart
  bool _canExtend(int idx) {
    if (widget.board.walls.contains(idx)) return false;
    final t = widget.board.cells[idx];
    if (t == null || t.tier >= kMaxTier) return false;
    if (_path.isEmpty) return true;
    if (_path.contains(idx)) return false;
    final lastTier = widget.board.cells[_path.last]!.tier;
    if (t.tier < lastTier || t.tier > lastTier + 1) return false;
    return GameEngine.areOrthogonallyAdjacent(_path.last, idx, widget.board.gridSize);
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/presentation/board_widget_test.dart`
Expected: PASS (both new tests)

- [ ] **Step 5: Commit**

```bash
git add lib/presentation/widgets/board_widget.dart test/presentation/board_widget_test.dart
git commit -m "feat(ui): let the drag path extend onto an adjacent higher tier"
```

---

### Task 6: Amber glow for ascend steps in the drag path (`BoardWidget`)

**Files:**
- Modify: `lib/presentation/widgets/board_widget.dart:137-176` (path-tile rendering loop)
- Test: `test/presentation/board_widget_test.dart`

**Interfaces:**
- Consumes: `_path` (existing field), tile tiers from `widget.board.cells`.
- Produces: no new public interface — purely a rendering change.

- [ ] **Step 1: Write the failing test**

In `test/presentation/board_widget_test.dart`, add this `testWidgets` after the two tests added in Task 5:

```dart

  testWidgets('an ascend step in the path glows amber; a flat step glows white',
      (tester) async {
    final cells = List<Tile?>.filled(kCellCount, null);
    cells[0] = const Tile(id: 1, tier: 1);
    cells[1] = const Tile(id: 2, tier: 1); // flat step from 0
    cells[6] = const Tile(id: 3, tier: 2); // ascend step from 1 (south of 1)
    final board = BoardState(
      cells: cells,
      movesRemaining: 30,
      score: 0,
      nextTileId: 4,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 0,
      status: GameStatus.playing,
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 350,
            height: 350,
            child: BoardWidget(board: board, onChain: (_) {}),
          ),
        ),
      ),
    ));

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
    await g.moveTo(centerOf(6));
    await tester.pump();

    BoxShadow shadowFor(int tileId) {
      final decoratedBox = tester.widget<DecoratedBox>(find.descendant(
        of: find.byKey(ValueKey(tileId)),
        matching: find.byType(DecoratedBox),
      ));
      final decoration = decoratedBox.decoration as BoxDecoration;
      return decoration.boxShadow!.single;
    }

    expect(shadowFor(2).color, Colors.white.withValues(alpha: 0.45)); // flat
    expect(shadowFor(3).color, Colors.amber.withValues(alpha: 0.6)); // ascend

    await g.up();
    await tester.pump();
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/presentation/board_widget_test.dart`
Expected: FAIL — tile id 3's glow is currently white, not amber.

- [ ] **Step 3: Implement the ascend glow**

In `lib/presentation/widgets/board_widget.dart`, replace the path-tile rendering loop (lines 137-176):

```dart
        // Floating live tiles keyed by id (for AnimatedPositioned animations).
        // Cells in the current path get a glow highlight.
        for (var i = 0; i < widget.board.cells.length; i++) {
          final tile = widget.board.cells[i];
          if (tile == null) continue;
          final pos = offsetFor(i);
          final inPath = _path.contains(i);
          children.add(AnimatedPositioned(
            key: ValueKey(tile.id),
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            left: pos.dx,
            top: pos.dy,
            width: cell,
            height: cell,
            child: inPath
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(cell * 0.16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.white.withValues(alpha: 0.45),
                          blurRadius: cell * 0.25,
                          spreadRadius: cell * 0.06,
                        ),
                      ],
                    ),
                    child: GridCellWidget(
                      tile: tile,
                      size: cell,
                      cosmetic: widget.cosmetic,
                      colorblindMode: widget.colorblindMode,
                    ),
                  )
                : GridCellWidget(
                    tile: tile,
                    size: cell,
                    cosmetic: widget.cosmetic,
                    colorblindMode: widget.colorblindMode,
                  ),
```

with:

```dart
        // Floating live tiles keyed by id (for AnimatedPositioned animations).
        // Cells in the current path get a glow highlight; a step that ascends
        // one tier above the previous path entry glows amber instead of white.
        final pathIndexOf = <int, int>{
          for (var p = 0; p < _path.length; p++) _path[p]: p,
        };
        for (var i = 0; i < widget.board.cells.length; i++) {
          final tile = widget.board.cells[i];
          if (tile == null) continue;
          final pos = offsetFor(i);
          final pathPos = pathIndexOf[i];
          final inPath = pathPos != null;
          final isAscend = inPath &&
              pathPos! > 0 &&
              tile.tier == widget.board.cells[_path[pathPos - 1]]!.tier + 1;
          children.add(AnimatedPositioned(
            key: ValueKey(tile.id),
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            left: pos.dx,
            top: pos.dy,
            width: cell,
            height: cell,
            child: inPath
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(cell * 0.16),
                      boxShadow: [
                        BoxShadow(
                          color: isAscend
                              ? Colors.amber.withValues(alpha: 0.6)
                              : Colors.white.withValues(alpha: 0.45),
                          blurRadius: cell * 0.25,
                          spreadRadius: cell * 0.06,
                        ),
                      ],
                    ),
                    child: GridCellWidget(
                      tile: tile,
                      size: cell,
                      cosmetic: widget.cosmetic,
                      colorblindMode: widget.colorblindMode,
                    ),
                  )
                : GridCellWidget(
                    tile: tile,
                    size: cell,
                    cosmetic: widget.cosmetic,
                    colorblindMode: widget.colorblindMode,
                  ),
```

(The remainder of the loop body — the closing `));` and `}` — is unchanged.)

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/presentation/board_widget_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/presentation/widgets/board_widget.dart test/presentation/board_widget_test.dart
git commit -m "feat(ui): glow ascend steps amber in the Connect-Merge drag path"
```

---

### Task 7: Mirror the ascend rule + scoring into the TS replay validator

**Files:**
- Modify: `supabase/functions/_shared/constants.ts:67` (insert `ascendBonus` after `comboMultiplier`)
- Modify: `supabase/functions/_shared/engine.ts:13-27` (imports), `:76-99` (`isValidChain`), `:106-132` (`collapseChain`), `:164-185` (`hasMergeAvailable`)
- Test: `supabase/functions/_shared/engine.test.ts`

**Interfaces:**
- Consumes: none from Dart (independent port), but must produce byte-identical results to Tasks 1-4 for any given board/path.
- Produces: `ascendBonus`, `isValidChain`, `collapseChain`, `hasMergeAvailable` in `engine.ts`/`constants.ts` now match the Dart engine's ascend rule and scoring.

- [ ] **Step 1: Write the failing tests**

In `supabase/functions/_shared/engine.test.ts`, update the import line (line 25):

```ts
import { comboRushMultiplier, comboMultiplier, kCellCount } from "./constants.ts";
```

to:

```ts
import { ascendBonus, comboRushMultiplier, comboMultiplier, kCellCount, kMaxTier } from "./constants.ts";
```

Replace the test `"rejects a chain of distinct tiers"` (lines 225-229):

```ts
Deno.test("rejects a chain of distinct tiers", async () => {
  // easy initial: cell 5 (tier1) is orthogonally adjacent to cell 6 (tier2).
  const r = await verifyRun("2026-06-07", "easy", [{ type: "chain", path: [5, 6] }]);
  assertFalse(r.valid);
});
```

with:

```ts
Deno.test("accepts an ascending chain (adjacent tiles one tier apart)", async () => {
  // easy initial: cell 5 (tier1) is orthogonally adjacent to cell 6 (tier2) —
  // this is now a legal ascend-by-1 chain, not a rejection case.
  const r = await verifyRun("2026-06-07", "easy", [{ type: "chain", path: [5, 6] }]);
  assertEquals(r.valid, true);
  assertEquals(r.score, comboScore(2, 2) + ascendBonus(2));
});
```

Replace the test `"isValidChain: accepts a connected same-tier run, rejects bad paths"` (lines 293-306):

```ts
Deno.test("isValidChain: accepts a connected same-tier run, rejects bad paths", () => {
  const b = boardWith({
    0: { id: 1, tier: 2 },
    1: { id: 2, tier: 2 },
    6: { id: 3, tier: 2 }, // index 6 adjacent to 1
    2: { id: 4, tier: 3 },
  });
  assertEquals(isValidChain(b, [0, 1, 6]), true);
  assertFalse(isValidChain(b, [0])); // too short
  assertFalse(isValidChain(b, [0, 2])); // tier mismatch
  assertFalse(isValidChain(b, [0, 6])); // not adjacent
  assertFalse(isValidChain(b, [0, 1, 0])); // repeat
  assertFalse(isValidChain(b, [0, 5])); // cell 5 empty
});
```

with:

```ts
Deno.test("isValidChain: accepts a connected same-tier run, rejects bad paths", () => {
  const b = boardWith({
    0: { id: 1, tier: 2 },
    1: { id: 2, tier: 2 },
    6: { id: 3, tier: 2 }, // index 6 adjacent to 1
  });
  assertEquals(isValidChain(b, [0, 1, 6]), true);
  assertFalse(isValidChain(b, [0])); // too short
  assertFalse(isValidChain(b, [0, 1, 0])); // repeat
  assertFalse(isValidChain(b, [0, 5])); // cell 5 empty
});

Deno.test("isValidChain: accepts an ascend-by-1 step, rejects descend and skip", () => {
  const b = boardWith({
    0: { id: 1, tier: 2 },
    1: { id: 2, tier: 3 }, // east of 0, one tier higher
    2: { id: 3, tier: 5 }, // east of 1, skips a tier
  });
  assertEquals(isValidChain(b, [0, 1]), true); // ascend by 1
  assertFalse(isValidChain(b, [1, 0])); // descend (3 -> 2)
  assertFalse(isValidChain(b, [1, 2])); // skip (3 -> 5)
});

Deno.test("isValidChain: accepts a run-then-ascend-then-run chain", () => {
  const b = boardWith({
    0: { id: 1, tier: 1 },
    1: { id: 2, tier: 1 },
    6: { id: 3, tier: 1 },
    7: { id: 4, tier: 2 },
    8: { id: 5, tier: 2 },
    13: { id: 6, tier: 3 },
  });
  assertEquals(isValidChain(b, [0, 1, 6, 7, 8, 13]), true);
});

Deno.test("isValidChain: rejects an ascend chain whose peak sits at max tier", () => {
  const b = boardWith({
    0: { id: 1, tier: kMaxTier - 1 },
    1: { id: 2, tier: kMaxTier },
  });
  assertFalse(isValidChain(b, [0, 1]));
});
```

Add two new tests right after `"collapseChain: endpoint +1 keeps id, others empty, scores combo"` (after line 325's closing `});`):

```ts

Deno.test("collapseChain: ascending chain scores base combo PLUS an ascend bonus per transition", () => {
  const b = boardWith({
    0: { id: 10, tier: 1 },
    1: { id: 11, tier: 1 },
    6: { id: 12, tier: 2 },
    7: { id: 13, tier: 2 },
    8: { id: 14, tier: 3 },
  });
  const r = collapseChain(b, [0, 1, 6, 7, 8]);
  assertEquals(r.cells[8], { id: 14, tier: 4 });
  assertEquals(r.score, comboScore(3, 5) + ascendBonus(2) + ascendBonus(3));
});

Deno.test("collapseChain: a flat (same-tier) chain has zero ascend bonus", () => {
  const b = boardWith({
    0: { id: 10, tier: 2 },
    1: { id: 11, tier: 2 },
  });
  const r = collapseChain(b, [0, 1]);
  assertEquals(r.score, comboScore(2, 2));
});
```

Add two new tests right after `"hasMergeAvailable: needs ADJACENT equal tiles (spatial deadlock)"` (after line 332's closing `});`):

```ts

Deno.test("hasMergeAvailable: also finds an ascend-adjacent pair (differs by exactly 1 tier)", () => {
  const b = boardWith({ 0: { id: 1, tier: 2 }, 1: { id: 2, tier: 3 } });
  assertEquals(hasMergeAvailable(b), true);
});

Deno.test("hasMergeAvailable: a 2-tier gap is NOT available", () => {
  const b = boardWith({ 0: { id: 1, tier: 2 }, 1: { id: 2, tier: 4 } });
  assertFalse(hasMergeAvailable(b));
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `deno test supabase/functions/_shared/engine.test.ts`
Expected: FAIL — `ascendBonus` isn't exported yet, `isValidChain`/`collapseChain`/`hasMergeAvailable` still reject/under-score ascend chains.

- [ ] **Step 3: Implement the mirror**

In `supabase/functions/_shared/constants.ts`, immediately after the `comboMultiplier` function (after its closing `}` at line 67) and before the `WALL_COUNT` comment block, insert:

```ts

/**
 * Bonus added once per ascend transition inside a chain (a step where the
 * next tile's tier is exactly one higher than the previous tile's). Uses the
 * same power-of-two convention as tile values. Must stay in lockstep with
 * Dart `ascendBonus`.
 */
export function ascendBonus(intoTier: number): number {
  return 1 << intoTier;
}
```

In `supabase/functions/_shared/engine.ts`, update the import block (lines 13-27):

```ts
import {
  comboMultiplier,
  comboRushMultiplier,
  type Difficulty,
  isDifficulty,
  kAdMoveReward,
  kChallengeDenseFill,
  kChallengeMoves,
  kChallengeSparseFill,
  kChallengeWallMazeCount,
  kMaxAdContinuesPerDay,
  kMaxTier,
  kMovesPerDay,
  STARTING_FILL,
} from "./constants.ts";
```

to:

```ts
import {
  ascendBonus,
  comboMultiplier,
  comboRushMultiplier,
  type Difficulty,
  isDifficulty,
  kAdMoveReward,
  kChallengeDenseFill,
  kChallengeMoves,
  kChallengeSparseFill,
  kChallengeWallMazeCount,
  kMaxAdContinuesPerDay,
  kMaxTier,
  kMovesPerDay,
  STARTING_FILL,
} from "./constants.ts";
```

Replace `isValidChain` (lines 76-99):

```ts
/**
 * A legal Connect-Merge path: length >= 2, no repeats, every cell holds a live
 * tile sharing one tier below the cap, consecutive cells orthogonally adjacent.
 * Walls hold no tile, so they are rejected by the null-cell check.
 */
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

with:

```ts
/**
 * A legal Connect-Merge path: length >= 2, no repeats, every cell holds a
 * live tile, consecutive cells orthogonally adjacent, and each step's tier is
 * either equal to or exactly one higher than the previous tile's tier (never
 * descends, never skips a tier). Since the path is thus non-decreasing, the
 * final tile is always the peak, and it alone must sit below the cap. Walls
 * hold no tile, so they are rejected by the null-cell check.
 */
export function isValidChain(s: BoardState, path: number[]): boolean {
  if (!Array.isArray(path) || path.length < 2) return false;
  const seen = new Set<number>();
  let prev: Tile | null = null;
  for (let i = 0; i < path.length; i++) {
    const idx = path[i];
    if (idx < 0 || idx >= s.cells.length) return false;
    if (seen.has(idx)) return false;
    seen.add(idx);
    const t = s.cells[idx];
    if (t === null || t === undefined) return false;
    if (prev !== null) {
      const delta = t.tier - prev.tier;
      if (delta < 0 || delta > 1) return false;
      if (!areOrthogonallyAdjacent(path[i - 1], idx, s.gridSize)) return false;
    }
    prev = t;
  }
  if (prev === null || prev.tier >= kMaxTier) return false;
  return true;
}
```

Replace `comboScore`'s doc comment and `collapseChain` (lines 101-132):

```ts
/** Points for collapsing a chain of [chainLength] tiles of [mergedTier]. */
export function comboScore(mergedTier: number, chainLength: number): number {
  return (1 << (mergedTier + 1)) * comboMultiplier(chainLength);
}

/**
 * Collapse a validated path onto its endpoint (path.last): endpoint becomes
 * tier+1 keeping its id, all other path cells empty, score gains the combo
 * total, one move spent. Caller must have checked isValidChain.
 * Optional `multiplierFn` overrides the default `comboMultiplier` (used by
 * challenge rules such as comboRush).
 */
export function collapseChain(
  s: BoardState,
  path: number[],
  multiplierFn?: (n: number) => number,
): BoardState {
  const endIdx = path[path.length - 1];
  const end = s.cells[endIdx]!;
  const mergedTier = end.tier;
  const fn = multiplierFn ?? comboMultiplier;
  const cells = s.cells.slice();
  for (const idx of path) cells[idx] = null;
  cells[endIdx] = { id: end.id, tier: mergedTier + 1 };
  return {
    ...s,
    cells,
    score: s.score + (1 << (mergedTier + 1)) * fn(path.length),
    movesRemaining: s.movesRemaining - 1,
    movesMade: s.movesMade + 1,
  };
}
```

with:

```ts
/** Points for collapsing a chain of [chainLength] tiles of [mergedTier]. */
export function comboScore(mergedTier: number, chainLength: number): number {
  return (1 << (mergedTier + 1)) * comboMultiplier(chainLength);
}

/**
 * Collapse a validated path onto its endpoint (path.last): endpoint becomes
 * tier+1 keeping its id, all other path cells empty, score gains the combo
 * total PLUS an ascendBonus for every ascend transition in the path, one
 * move spent. Caller must have checked isValidChain. Optional `multiplierFn`
 * overrides the default `comboMultiplier` (used by challenge rules such as
 * comboRush).
 */
export function collapseChain(
  s: BoardState,
  path: number[],
  multiplierFn?: (n: number) => number,
): BoardState {
  const endIdx = path[path.length - 1];
  const end = s.cells[endIdx]!;
  const mergedTier = end.tier;
  const fn = multiplierFn ?? comboMultiplier;
  let ascendTotal = 0;
  for (let i = 1; i < path.length; i++) {
    const prevTier = s.cells[path[i - 1]]!.tier;
    const curTier = s.cells[path[i]]!.tier;
    if (curTier === prevTier + 1) {
      ascendTotal += ascendBonus(curTier);
    }
  }
  const cells = s.cells.slice();
  for (const idx of path) cells[idx] = null;
  cells[endIdx] = { id: end.id, tier: mergedTier + 1 };
  return {
    ...s,
    cells,
    score: s.score + (1 << (mergedTier + 1)) * fn(path.length) + ascendTotal,
    movesRemaining: s.movesRemaining - 1,
    movesMade: s.movesMade + 1,
  };
}
```

Replace `hasMergeAvailable` (lines 164-185):

```ts
/**
 * True if any two orthogonally-adjacent live tiles share a tier below the cap
 * (spatial deadlock — non-adjacent equal tiles do NOT count).
 */
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

with:

```ts
/**
 * True if two adjacent tiles could legally merge in SOME direction: their
 * tiers differ by at most one, and the higher of the two is below the cap
 * (the higher tile is always the merge destination).
 */
function pairMergeable(a: Tile, b: Tile): boolean {
  const delta = Math.abs(a.tier - b.tier);
  if (delta > 1) return false;
  const higher = a.tier > b.tier ? a.tier : b.tier;
  return higher < kMaxTier;
}

/**
 * True if any two orthogonally-adjacent live tiles could legally merge in
 * SOME direction (spatial deadlock — non-adjacent mergeable tiles do NOT
 * count).
 */
export function hasMergeAvailable(s: BoardState): boolean {
  const gs = s.gridSize;
  for (let i = 0; i < s.cells.length; i++) {
    const t = s.cells[i];
    if (t === null) continue;
    const row = Math.floor(i / gs);
    const col = i % gs;
    if (col + 1 < gs) {
      const e = s.cells[i + 1];
      if (e !== null && pairMergeable(t, e)) return true;
    }
    if (row + 1 < gs) {
      const so = s.cells[i + gs];
      if (so !== null && pairMergeable(t, so)) return true;
    }
  }
  return false;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `deno test supabase/functions/_shared/engine.test.ts`
Expected: PASS (all tests, including the previously-captured Dart parity vectors, since those captured runs are pure same-tier chains and score identically under the new formula — the ascend bonus is 0 when there's no ascend transition).

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/_shared/constants.ts supabase/functions/_shared/engine.ts supabase/functions/_shared/engine.test.ts
git commit -m "feat(server): mirror ascending chain rule and scoring into the TS replay validator"
```

---

### Task 8: Bump the leaderboard season

**Files:**
- Modify: `lib/domain/constants.dart:138`
- Modify: `supabase/functions/_shared/constants.ts:109`
- Test: `test/domain/constants_test.dart` (existing assertion already covers this; no new test needed)

**Interfaces:**
- Consumes: nothing (final, independent step).
- Produces: `kLeaderboardSeason == 3` in both the Dart client and the TS Edge Function, so post-deploy score submissions are segmented from pre-deploy ones on every leaderboard read.

- [ ] **Step 1: Confirm the existing test still covers this**

`test/domain/constants_test.dart:41` already asserts `expect(kLeaderboardSeason >= 2, isTrue);`, which remains true at `3` — no test changes needed. Run it now to confirm the baseline passes before the bump:

Run: `flutter test test/domain/constants_test.dart`
Expected: PASS

- [ ] **Step 2: Bump the Dart constant**

In `lib/domain/constants.dart`, replace line 136-138:

```dart
/// Bumped at the Connect-Merge relaunch. Submitted with every score and used to
/// filter leaderboard reads, so pre-relaunch scores never appear (hard reset).
const int kLeaderboardSeason = 2;
```

with:

```dart
/// Bumped when the ascending-chain-merge rule shipped. Submitted with every
/// score and used to filter leaderboard reads, so pre-bump scores (computed
/// under the old same-tier-only rule) never mix with post-bump scores.
const int kLeaderboardSeason = 3;
```

- [ ] **Step 3: Bump the TS constant**

In `supabase/functions/_shared/constants.ts`, replace lines 103-109:

```ts
/**
 * Leaderboard season (port of Dart `kLeaderboardSeason`). The Connect-Merge
 * relaunch bumped this to 2; the server writes/filters by this constant so
 * pre-relaunch (season 1) scores never appear (the hard reset). The server uses
 * its OWN constant when writing — it never trusts a client-supplied season.
 */
export const kLeaderboardSeason = 2;
```

with:

```ts
/**
 * Leaderboard season (port of Dart `kLeaderboardSeason`). Bumped to 3 when the
 * ascending-chain-merge rule shipped, so pre-bump (season 2) scores never mix
 * with post-bump scores. The server uses its OWN constant when writing — it
 * never trusts a client-supplied season.
 */
export const kLeaderboardSeason = 3;
```

- [ ] **Step 4: Run tests to verify nothing broke**

Run: `flutter test test/domain/constants_test.dart && flutter test test/infrastructure/leaderboard_service_test.dart && flutter test test/infrastructure/friends_service_test.dart`
Expected: PASS (all three files reference `kLeaderboardSeason` symbolically, not as a hardcoded literal, so the bump doesn't break them).

Also run: `deno test supabase/functions/_shared/engine.test.ts`
Expected: PASS (unaffected by the season constant).

- [ ] **Step 5: Commit**

```bash
git add lib/domain/constants.dart supabase/functions/_shared/constants.ts
git commit -m "chore(leaderboard): bump season to 3 for the ascending-chain-merge rule change"
```

---

## Self-Review

**Spec coverage:**
- Core rule change (Section A) → Task 2.
- Scoring / ascend bonus (Section B) → Tasks 1, 3.
- Legacy pairwise API → Task 2 (`canMerge`).
- Deadlock detection → Task 4.
- Drag UI extension rule → Task 5.
- Ascend visual cue (amber glow) → Task 6.
- Server-side mirror (`engine.ts`/`constants.ts`) → Task 7.
- Leaderboard season bump → Task 8.
- Testing section of the spec → covered per-task (Dart unit/widget tests + TS `deno test` mirrors).
- Out-of-scope items (span cap, `longChainsOnly`/`comboRush`, golden/XP/almanac/objective) → correctly untouched by every task; no task modifies those code paths.

**Placeholder scan:** No "TBD"/"TODO"/vague steps — every step has complete, concrete code and exact expected test outcomes.

**Type consistency:** `ascendBonus(int intoTier) -> int` (Dart) / `ascendBonus(intoTier: number): number` (TS) used identically in Tasks 1, 3, 7. `GameEngine.collapseChain`/`isValidChain`/`canMerge`/`hasMergeAvailable` signatures are unchanged across all tasks (no caller elsewhere in the codebase needs updating, confirmed via `game_cubit.dart` reading only `board.highestTier`/`path.length`, both unaffected).

---

Plan complete and saved to `docs/superpowers/plans/2026-07-07-ascending-chain-merge.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
