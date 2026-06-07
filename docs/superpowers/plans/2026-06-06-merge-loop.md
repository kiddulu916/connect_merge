# Merge Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a fully-offline, deterministic daily 5×5 merge puzzle in Flutter that ships to iOS/Android, monetized with AdMob and shared Wordle-style.

**Architecture:** Domain-Driven Design in four layers. A pure-Dart domain (deterministic PRNG, seeder, merge engine) with zero Flutter imports; a `flutter_bloc` Cubit application layer; an infrastructure layer (Hive persistence, AdMob); and a presentation layer (Stack + `AnimatedPositioned` board, drag-to-merge). Determinism comes from a SHA-256-seeded Mulberry32 PRNG keyed to the `YYYY-MM-DD` date.

**Tech Stack:** Dart 3.x, flutter_bloc, hive/hive_flutter, google_mobile_ads, path_provider, crypto, flutter_lints.

---

## File Structure

```
lib/
├── domain/
│   ├── constants.dart                # tunable game constants + dropCap()
│   ├── models/
│   │   ├── tile.dart                  # Tile{ id, tier }
│   │   ├── game_status.dart           # enum playing|outOfMoves|deadlocked
│   │   └── board_state.dart           # immutable board + helpers + JSON
│   └── engine/
│       ├── prng.dart                  # Mulberry32 deterministic stream
│       ├── daily_seeder.dart          # date → seed → initial board + drop schedule + landing prng
│       ├── game_engine.dart           # pure merge / drop / deadlock / scoring
│       └── share_grid_builder.dart    # board → Wordle-style emoji string
├── application/
│   ├── game_state.dart                # GameInitial|GamePlaying|GameOverShowScore|GameAdRewardGranted
│   └── game_cubit.dart                # orchestration
├── infrastructure/
│   ├── storage_service.dart           # StorageService interface + models + InMemory fake
│   ├── hive_storage_service.dart      # Hive implementation
│   ├── ad_config.dart                 # test/real AdMob unit IDs
│   └── ad_service.dart                # google_mobile_ads lifecycle
├── presentation/
│   ├── theme/tile_palette.dart        # tier → color/label
│   ├── screens/
│   │   ├── game_screen.dart
│   │   └── score_share_screen.dart
│   └── widgets/
│       ├── grid_cell_widget.dart
│       ├── board_widget.dart
│       ├── moves_counter.dart
│       ├── banner_slot.dart
│       └── rewarded_dialog.dart
└── main.dart
test/                                  # mirrors lib/ for unit + widget tests
```

---

## Task 1: Scaffold the Flutter project

**Files:**
- Create: project scaffold, `pubspec.yaml`, `analysis_options.yaml`

- [ ] **Step 1: Generate the Flutter app in place**

Run (from repo root, which already contains `.git`, `docs/`, `.gitignore`):
```bash
flutter create --org com.mergeloop --project-name merge_loop --platforms android,ios .
```
Expected: scaffold created (`lib/main.dart`, `android/`, `ios/`, `test/`).

- [ ] **Step 2: Replace `pubspec.yaml` dependencies**

```yaml
name: merge_loop
description: A deterministic daily merge puzzle.
publish_to: "none"
version: 1.0.0+1

environment:
  sdk: ">=3.4.0 <4.0.0"

dependencies:
  flutter:
    sdk: flutter
  flutter_bloc: ^9.0.0
  hive: ^2.2.3
  hive_flutter: ^1.1.0
  google_mobile_ads: ^5.3.1
  path_provider: ^2.1.4
  crypto: ^3.0.5

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0

flutter:
  uses-material-design: true
```

- [ ] **Step 3: Tighten `analysis_options.yaml`**

```yaml
include: package:flutter_lints/flutter.yaml

linter:
  rules:
    prefer_const_constructors: true
    prefer_final_locals: true
    avoid_print: true

analyzer:
  language:
    strict-casts: true
    strict-raw-types: true
```

- [ ] **Step 4: Install and verify a clean baseline**

Run:
```bash
flutter pub get
flutter analyze
```
Expected: `flutter pub get` resolves; `flutter analyze` reports "No issues found!" (the default counter app is lint-clean).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: scaffold Flutter app with deps and lints"
```

---

## Task 2: Game constants

**Files:**
- Create: `lib/domain/constants.dart`
- Test: `test/domain/constants_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_loop/domain/constants.dart';

void main() {
  test('board geometry is 5x5 = 25 cells', () {
    expect(kGridSize, 5);
    expect(kCellCount, 25);
  });

  test('dropCap starts at 2 and steps up, clamped to 6', () {
    expect(dropCap(0), 2);
    expect(dropCap(5), 2);
    expect(dropCap(6), 3);
    expect(dropCap(30), 7 > 6 ? 6 : 7); // clamped
    expect(dropCap(1000), 6);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/domain/constants_test.dart`
Expected: FAIL — `constants.dart` not found / symbols undefined.

- [ ] **Step 3: Write the implementation**

```dart
/// Tunable game constants — the single source of truth for game feel.

/// Board is a fixed kGridSize × kGridSize matrix.
const int kGridSize = 5;
const int kCellCount = kGridSize * kGridSize; // 25

/// Tier 0 = empty. Tiers 1..kMaxTier are live tiles (displayed as 2^tier).
const int kMaxTier = 11; // 2^11 = 2048

/// Daily move budget. One move == one successful merge.
const int kMovesPerDay = 30;

/// Constant board population. Each merge frees a cell and each drop fills one,
/// so occupancy stays at this value all day. Must be <= kMaxTier for deadlock
/// to be reachable (pigeonhole: all-unique tiers needs <= 11 tiles).
const int kStartingFill = 8;

/// Moves granted per rewarded video, and the daily cap on rewarded continues.
const int kAdMoveReward = 3;
const int kMaxAdContinuesPerDay = 3;

/// Maximum number of drops that can ever occur in one day.
const int kMaxDrops = kMovesPerDay + kAdMoveReward * kMaxAdContinuesPerDay; // 39

/// Upper bound (inclusive) of the drop tier band for drop number [n].
/// Drops are drawn from tiers [1 .. dropCap(n)]. The band widens by drop
/// INDEX (not board state) so the item sequence is identical for all players.
int dropCap(int n) {
  final c = 2 + (n ~/ 6);
  return c > 6 ? 6 : c;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/domain/constants_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/domain/constants.dart test/domain/constants_test.dart
git commit -m "feat(domain): add game constants and drop-cap schedule"
```

---

## Task 3: Deterministic PRNG (Mulberry32)

**Files:**
- Create: `lib/domain/engine/prng.dart`
- Test: `test/domain/engine/prng_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_loop/domain/engine/prng.dart';

void main() {
  test('same seed yields identical sequence (reproducible)', () {
    final a = Prng(12345);
    final b = Prng(12345);
    final seqA = List.generate(20, (_) => a.nextU32());
    final seqB = List.generate(20, (_) => b.nextU32());
    expect(seqA, seqB);
  });

  test('different seeds diverge', () {
    final a = Prng(1);
    final b = Prng(2);
    expect(a.nextU32(), isNot(equals(b.nextU32())));
  });

  test('nextU32 stays within unsigned 32-bit range', () {
    final p = Prng(99);
    for (var i = 0; i < 1000; i++) {
      final v = p.nextU32();
      expect(v, greaterThanOrEqualTo(0));
      expect(v, lessThanOrEqualTo(0xFFFFFFFF));
    }
  });

  test('nextInt returns values in [0, max)', () {
    final p = Prng(7);
    for (var i = 0; i < 1000; i++) {
      final v = p.nextInt(5);
      expect(v, inInclusiveRange(0, 4));
    }
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/domain/engine/prng_test.dart`
Expected: FAIL — `Prng` undefined.

- [ ] **Step 3: Write the implementation**

```dart
/// Mulberry32 — a tiny, fast, fully reproducible PRNG.
///
/// Dart's `Random(seed)` is NOT guaranteed stable across platforms or SDK
/// versions, which would break "same board for everyone". We ship our own so
/// the sequence is byte-identical everywhere.
class Prng {
  int _state;

  Prng(int seed) : _state = seed & 0xFFFFFFFF;

  static int _imul(int a, int b) => (a * b) & 0xFFFFFFFF;

  /// Next unsigned 32-bit integer.
  int nextU32() {
    _state = (_state + 0x6D2B79F5) & 0xFFFFFFFF;
    var t = _state;
    t = _imul(t ^ (t >>> 15), t | 1);
    t = ((t + _imul(t ^ (t >>> 7), 61 | t)) & 0xFFFFFFFF) ^ t;
    t &= 0xFFFFFFFF;
    return (t ^ (t >>> 14)) & 0xFFFFFFFF;
  }

  /// Double in [0, 1).
  double nextDouble() => nextU32() / 4294967296.0;

  /// Integer in [0, max). [max] must be > 0.
  int nextInt(int max) => nextU32() % max;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/domain/engine/prng_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/domain/engine/prng.dart test/domain/engine/prng_test.dart
git commit -m "feat(domain): add deterministic Mulberry32 PRNG"
```

---

## Task 4: Tile and GameStatus models

**Files:**
- Create: `lib/domain/models/tile.dart`, `lib/domain/models/game_status.dart`
- Test: `test/domain/models/tile_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_loop/domain/models/tile.dart';

void main() {
  test('value is 2^tier', () {
    expect(const Tile(id: 0, tier: 1).value, 2);
    expect(const Tile(id: 0, tier: 11).value, 2048);
  });

  test('equality is by id and tier', () {
    expect(const Tile(id: 1, tier: 3), const Tile(id: 1, tier: 3));
    expect(const Tile(id: 1, tier: 3), isNot(const Tile(id: 2, tier: 3)));
  });

  test('copyWith changes tier but keeps id', () {
    final t = const Tile(id: 5, tier: 2).copyWith(tier: 3);
    expect(t.id, 5);
    expect(t.tier, 3);
  });

  test('round-trips through json', () {
    final t = const Tile(id: 7, tier: 4);
    expect(Tile.fromJson(t.toJson()), t);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/domain/models/tile_test.dart`
Expected: FAIL — `Tile` undefined.

- [ ] **Step 3: Write the implementations**

`lib/domain/models/game_status.dart`:
```dart
/// Lifecycle of a daily board.
enum GameStatus { playing, outOfMoves, deadlocked }
```

`lib/domain/models/tile.dart`:
```dart
/// A live tile. [id] is a stable identity used as the widget key so the UI can
/// animate a tile as it slides/merges. [tier] is 1..kMaxTier; value is 2^tier.
class Tile {
  final int id;
  final int tier;

  const Tile({required this.id, required this.tier});

  int get value => 1 << tier;

  Tile copyWith({int? tier}) => Tile(id: id, tier: tier ?? this.tier);

  Map<String, dynamic> toJson() => {'id': id, 'tier': tier};

  static Tile fromJson(Map<String, dynamic> j) =>
      Tile(id: j['id'] as int, tier: j['tier'] as int);

  @override
  bool operator ==(Object other) =>
      other is Tile && other.id == id && other.tier == tier;

  @override
  int get hashCode => Object.hash(id, tier);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/domain/models/tile_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/domain/models/tile.dart lib/domain/models/game_status.dart test/domain/models/tile_test.dart
git commit -m "feat(domain): add Tile and GameStatus models"
```

---

## Task 5: BoardState model

**Files:**
- Create: `lib/domain/models/board_state.dart`
- Test: `test/domain/models/board_state_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_loop/domain/constants.dart';
import 'package:merge_loop/domain/models/board_state.dart';
import 'package:merge_loop/domain/models/game_status.dart';
import 'package:merge_loop/domain/models/tile.dart';

BoardState boardWith(Map<int, Tile> tiles) {
  final cells = List<Tile?>.filled(kCellCount, null);
  tiles.forEach((i, t) => cells[i] = t);
  return BoardState(
    cells: cells,
    movesRemaining: kMovesPerDay,
    score: 0,
    nextTileId: 100,
    dropIndex: 0,
    adContinuesUsed: 0,
    movesMade: 0,
    status: GameStatus.playing,
  );
}

void main() {
  test('emptyIndices and filledCount reflect occupancy', () {
    final b = boardWith({0: const Tile(id: 1, tier: 1), 3: const Tile(id: 2, tier: 2)});
    expect(b.filledCount, 2);
    expect(b.emptyIndices.length, kCellCount - 2);
    expect(b.emptyIndices.contains(0), isFalse);
    expect(b.emptyIndices.contains(1), isTrue);
  });

  test('highestTier finds the max live tier', () {
    final b = boardWith({0: const Tile(id: 1, tier: 1), 3: const Tile(id: 2, tier: 7)});
    expect(b.highestTier, 7);
  });

  test('round-trips through json', () {
    final b = boardWith({0: const Tile(id: 1, tier: 1), 24: const Tile(id: 2, tier: 5)})
        .copyWith(score: 42, dropIndex: 3, movesMade: 4);
    expect(BoardState.fromJson(b.toJson()).toJson(), b.toJson());
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/domain/models/board_state_test.dart`
Expected: FAIL — `BoardState` undefined.

- [ ] **Step 3: Write the implementation**

```dart
import '../constants.dart';
import 'game_status.dart';
import 'tile.dart';

/// Immutable snapshot of a daily board. Row-major: index = row * kGridSize + col.
class BoardState {
  final List<Tile?> cells; // length kCellCount
  final int movesRemaining;
  final int score;
  final int nextTileId; // next id to assign to a dropped tile
  final int dropIndex; // how many drops have been consumed (n)
  final int adContinuesUsed;
  final int movesMade; // total successful merges (for display incl. ad moves)
  final GameStatus status;

  const BoardState({
    required this.cells,
    required this.movesRemaining,
    required this.score,
    required this.nextTileId,
    required this.dropIndex,
    required this.adContinuesUsed,
    required this.movesMade,
    required this.status,
  });

  BoardState copyWith({
    List<Tile?>? cells,
    int? movesRemaining,
    int? score,
    int? nextTileId,
    int? dropIndex,
    int? adContinuesUsed,
    int? movesMade,
    GameStatus? status,
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
    );
  }

  List<int> get emptyIndices {
    final out = <int>[];
    for (var i = 0; i < cells.length; i++) {
      if (cells[i] == null) out.add(i);
    }
    return out;
  }

  int get filledCount {
    var n = 0;
    for (final c in cells) {
      if (c != null) n++;
    }
    return n;
  }

  int get highestTier {
    var m = 0;
    for (final c in cells) {
      if (c != null && c.tier > m) m = c.tier;
    }
    return m;
  }

  Map<String, dynamic> toJson() => {
        'cells': cells.map((c) => c?.toJson()).toList(),
        'movesRemaining': movesRemaining,
        'score': score,
        'nextTileId': nextTileId,
        'dropIndex': dropIndex,
        'adContinuesUsed': adContinuesUsed,
        'movesMade': movesMade,
        'status': status.name,
      };

  static BoardState fromJson(Map<String, dynamic> j) {
    final rawCells = j['cells'] as List;
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
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/domain/models/board_state_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/domain/models/board_state.dart test/domain/models/board_state_test.dart
git commit -m "feat(domain): add immutable BoardState with helpers and json"
```

---

## Task 6: DailySeeder (determinism core)

**Files:**
- Create: `lib/domain/engine/daily_seeder.dart`
- Test: `test/domain/engine/daily_seeder_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_loop/domain/constants.dart';
import 'package:merge_loop/domain/engine/daily_seeder.dart';

void main() {
  test('same date yields identical initial board and drop tiers', () {
    final a = DailySeeder('2026-06-06').generate();
    final b = DailySeeder('2026-06-06').generate();
    expect(a.board.toJson(), b.board.toJson());
    expect(a.dropTiers, b.dropTiers);
  });

  test('different dates differ', () {
    final a = DailySeeder('2026-06-06').generate();
    final b = DailySeeder('2026-06-07').generate();
    expect(a.board.toJson(), isNot(b.board.toJson()));
  });

  test('initial board has exactly kStartingFill tiles, all tier 1-2', () {
    final start = DailySeeder('2026-06-06').generate();
    expect(start.board.filledCount, kStartingFill);
    for (final c in start.board.cells) {
      if (c != null) expect(c.tier, inInclusiveRange(1, 2));
    }
  });

  test('drop schedule has kMaxDrops tiers, each within its band', () {
    final start = DailySeeder('2026-06-06').generate();
    expect(start.dropTiers.length, kMaxDrops);
    for (var n = 0; n < start.dropTiers.length; n++) {
      expect(start.dropTiers[n], inInclusiveRange(1, dropCap(n)));
    }
  });

  test('landingPrng is independent of dropTier draws and reproducible', () {
    final s = DailySeeder('2026-06-06');
    final p1 = s.landingPrng();
    final p2 = s.landingPrng();
    expect(List.generate(10, (_) => p1.nextU32()),
        List.generate(10, (_) => p2.nextU32()));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/domain/engine/daily_seeder_test.dart`
Expected: FAIL — `DailySeeder` undefined.

- [ ] **Step 3: Write the implementation**

```dart
import 'dart:convert';
import 'package:crypto/crypto.dart';

import '../constants.dart';
import '../models/board_state.dart';
import '../models/game_status.dart';
import '../models/tile.dart';
import 'prng.dart';

/// Everything the day needs, derived deterministically from the date.
class DailyStart {
  final BoardState board;
  final List<int> dropTiers; // length kMaxDrops; dropTiers[n] = tier of drop n
  const DailyStart(this.board, this.dropTiers);
}

/// Turns a `YYYY-MM-DD` string into the day's board and drop schedule.
///
/// Two independent PRNG streams keep concerns decoupled:
///  - stream A (seedA): initial board placement + drop tiers (the global item
///    sequence — identical for every player).
///  - stream B (seedB): landing-cell selection at drop time (mapped onto each
///    player's own empty cells, so position adapts locally).
class DailySeeder {
  final String date;
  const DailySeeder(this.date);

  static int seedForDate(String date) {
    final bytes = sha256.convert(utf8.encode(date)).bytes;
    return (bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)) &
        0xFFFFFFFF;
  }

  int get _seedA => seedForDate(date);
  int get _seedB => seedForDate(date) ^ 0x9E3779B9;

  DailyStart generate() {
    final a = Prng(_seedA);

    // Initial board: kStartingFill tiles of tier 1-2 in deterministic cells.
    final cells = List<Tile?>.filled(kCellCount, null);
    var nextId = 0;
    var placed = 0;
    while (placed < kStartingFill) {
      final idx = a.nextInt(kCellCount);
      if (cells[idx] != null) continue; // rejection sampling; deterministic
      cells[idx] = Tile(id: nextId++, tier: 1 + a.nextInt(2));
      placed++;
    }

    // Drop schedule: tiers only. Band widens by drop index n.
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
    );
    return DailyStart(board, tiers);
  }

  /// Fresh landing stream (stream B). Advance it `board.dropIndex` times when
  /// resuming a saved game to reach the correct position.
  Prng landingPrng() => Prng(_seedB);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/domain/engine/daily_seeder_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/domain/engine/daily_seeder.dart test/domain/engine/daily_seeder_test.dart
git commit -m "feat(domain): add DailySeeder with dual-stream determinism"
```

---

## Task 7: GameEngine (merge / drop / deadlock / scoring)

**Files:**
- Create: `lib/domain/engine/game_engine.dart`
- Test: `test/domain/engine/game_engine_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_loop/domain/constants.dart';
import 'package:merge_loop/domain/engine/game_engine.dart';
import 'package:merge_loop/domain/engine/prng.dart';
import 'package:merge_loop/domain/models/board_state.dart';
import 'package:merge_loop/domain/models/game_status.dart';
import 'package:merge_loop/domain/models/tile.dart';

BoardState boardWith(Map<int, Tile> tiles, {int moves = kMovesPerDay}) {
  final cells = List<Tile?>.filled(kCellCount, null);
  tiles.forEach((i, t) => cells[i] = t);
  return BoardState(
    cells: cells,
    movesRemaining: moves,
    score: 0,
    nextTileId: 100,
    dropIndex: 0,
    adContinuesUsed: 0,
    movesMade: 0,
    status: GameStatus.playing,
  );
}

void main() {
  test('canMerge: same tier, distinct cells, below max tier', () {
    final b = boardWith({
      0: const Tile(id: 1, tier: 3),
      1: const Tile(id: 2, tier: 3),
      2: const Tile(id: 3, tier: 4),
      3: const Tile(id: 4, tier: kMaxTier),
      4: const Tile(id: 5, tier: kMaxTier),
    });
    expect(GameEngine.canMerge(b, 0, 1), isTrue);
    expect(GameEngine.canMerge(b, 0, 2), isFalse); // different tier
    expect(GameEngine.canMerge(b, 0, 0), isFalse); // same cell
    expect(GameEngine.canMerge(b, 3, 4), isFalse); // at max tier
  });

  test('merge: destination becomes tier+1, source empties, scores 2^newTier, spends a move', () {
    final b = boardWith({
      0: const Tile(id: 1, tier: 3),
      1: const Tile(id: 2, tier: 3),
    });
    final r = GameEngine.merge(b, fromIndex: 0, toIndex: 1);
    expect(r.cells[0], isNull);
    expect(r.cells[1]!.tier, 4);
    expect(r.cells[1]!.id, 2); // destination id preserved for animation
    expect(r.score, 1 << 4); // 16
    expect(r.movesRemaining, kMovesPerDay - 1);
    expect(r.movesMade, 1);
  });

  test('applyDrop: places dropped tier at a deterministic empty cell, advances dropIndex', () {
    final b = boardWith({0: const Tile(id: 1, tier: 1)});
    final landing = Prng(42);
    final r = GameEngine.applyDrop(b, 2, landing);
    expect(r.filledCount, 2);
    expect(r.dropIndex, 1);
    // dropped tile took the next free id and the requested tier
    final dropped = r.cells.firstWhere((c) => c != null && c.id == 100);
    expect(dropped!.tier, 2);
  });

  test('hasMergeAvailable: false when all tiers unique => deadlock', () {
    final dead = boardWith({
      0: const Tile(id: 1, tier: 1),
      1: const Tile(id: 2, tier: 2),
      2: const Tile(id: 3, tier: 3),
    });
    expect(GameEngine.hasMergeAvailable(dead), isFalse);
    expect(GameEngine.evaluateStatus(dead).status, GameStatus.deadlocked);
  });

  test('evaluateStatus: zero moves => outOfMoves even if a merge exists', () {
    final b = boardWith({
      0: const Tile(id: 1, tier: 1),
      1: const Tile(id: 2, tier: 1),
    }, moves: 0);
    expect(GameEngine.evaluateStatus(b).status, GameStatus.outOfMoves);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/domain/engine/game_engine_test.dart`
Expected: FAIL — `GameEngine` undefined.

- [ ] **Step 3: Write the implementation**

```dart
import '../constants.dart';
import '../models/board_state.dart';
import '../models/game_status.dart';
import '../models/tile.dart';
import 'prng.dart';

/// Pure game rules. Every method returns a NEW BoardState; nothing mutates.
class GameEngine {
  const GameEngine._();

  /// A legal merge: both cells hold tiles, distinct cells, equal tier, and the
  /// tier is below the cap (two max-tier tiles cannot fuse further).
  static bool canMerge(BoardState s, int fromIndex, int toIndex) {
    if (fromIndex == toIndex) return false;
    final from = s.cells[fromIndex];
    final to = s.cells[toIndex];
    if (from == null || to == null) return false;
    return from.tier == to.tier && from.tier < kMaxTier;
  }

  /// Fuse [fromIndex] into [toIndex]: destination becomes tier+1 (keeping its
  /// id for animation continuity), source empties, score += 2^newTier, one move
  /// is spent, movesMade increments.
  static BoardState merge(BoardState s,
      {required int fromIndex, required int toIndex}) {
    final to = s.cells[toIndex]!;
    final newTier = to.tier + 1;
    final cells = List<Tile?>.of(s.cells);
    cells[toIndex] = Tile(id: to.id, tier: newTier);
    cells[fromIndex] = null;
    return s.copyWith(
      cells: cells,
      score: s.score + (1 << newTier),
      movesRemaining: s.movesRemaining - 1,
      movesMade: s.movesMade + 1,
    );
  }

  /// Drop a tile of [tier] into a deterministically-chosen empty cell. The
  /// landing index is drawn from [landing] (stream B) mapped onto current
  /// empties, so the item is global but the position adapts to this board.
  static BoardState applyDrop(BoardState s, int tier, Prng landing) {
    final empties = s.emptyIndices;
    if (empties.isEmpty) {
      // Invariant means this should never happen, but stay total.
      return s.copyWith(dropIndex: s.dropIndex + 1);
    }
    final idx = empties[landing.nextInt(empties.length)];
    final cells = List<Tile?>.of(s.cells);
    cells[idx] = Tile(id: s.nextTileId, tier: tier);
    return s.copyWith(
      cells: cells,
      nextTileId: s.nextTileId + 1,
      dropIndex: s.dropIndex + 1,
    );
  }

  /// True if any two live tiles share a tier below the cap (a legal merge).
  static bool hasMergeAvailable(BoardState s) {
    final seen = <int>{};
    for (final c in s.cells) {
      if (c == null || c.tier >= kMaxTier) continue;
      if (!seen.add(c.tier)) return true;
    }
    return false;
  }

  /// Resolve end-of-day status: out of moves first, then deadlock, else playing.
  static BoardState evaluateStatus(BoardState s) {
    if (s.movesRemaining <= 0) {
      return s.copyWith(status: GameStatus.outOfMoves);
    }
    if (!hasMergeAvailable(s)) {
      return s.copyWith(status: GameStatus.deadlocked);
    }
    return s.copyWith(status: GameStatus.playing);
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/domain/engine/game_engine_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/domain/engine/game_engine.dart test/domain/engine/game_engine_test.dart
git commit -m "feat(domain): add pure GameEngine (merge, drop, deadlock, scoring)"
```

---

## Task 8: ShareGridBuilder (emoji share)

**Files:**
- Create: `lib/domain/engine/share_grid_builder.dart`
- Test: `test/domain/engine/share_grid_builder_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_loop/domain/constants.dart';
import 'package:merge_loop/domain/engine/share_grid_builder.dart';
import 'package:merge_loop/domain/models/board_state.dart';
import 'package:merge_loop/domain/models/game_status.dart';
import 'package:merge_loop/domain/models/tile.dart';

void main() {
  test('builds header lines and a 5x5 emoji grid', () {
    final cells = List<Tile?>.filled(kCellCount, null);
    cells[0] = const Tile(id: 1, tier: 1); // low -> blue
    cells[24] = const Tile(id: 2, tier: 11); // max -> purple
    final board = BoardState(
      cells: cells,
      movesRemaining: 6,
      score: 4096,
      nextTileId: 3,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 24,
      status: GameStatus.outOfMoves,
    );

    final out = ShareGridBuilder.build(date: '2026-06-06', board: board);
    final lines = out.split('\n');

    expect(lines[0], 'Merge Loop 2026-06-06');
    expect(lines[1], contains('Score 4096'));
    expect(lines[1], contains('24 moves'));
    expect(lines.length, 2 + kGridSize); // 2 header + 5 grid rows
    expect(lines[2].startsWith('🟦'), isTrue); // cell 0 low tier
    expect(lines.last.endsWith('🟪'), isTrue); // cell 24 max tier
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/domain/engine/share_grid_builder_test.dart`
Expected: FAIL — `ShareGridBuilder` undefined.

- [ ] **Step 3: Write the implementation**

```dart
import '../constants.dart';
import '../models/board_state.dart';

/// Builds a Wordle-style shareable result string from a final board.
class ShareGridBuilder {
  const ShareGridBuilder._();

  static String build({required String date, required BoardState board}) {
    final best = board.highestTier;
    final sb = StringBuffer()
      ..writeln('Merge Loop $date')
      ..writeln(
          'Score ${board.score} · Best ${emojiForTier(best)}${1 << best} · ${board.movesMade} moves');

    for (var r = 0; r < kGridSize; r++) {
      for (var c = 0; c < kGridSize; c++) {
        final tile = board.cells[r * kGridSize + c];
        sb.write(tile == null ? '⬛' : emojiForTier(tile.tier));
      }
      if (r < kGridSize - 1) sb.write('\n');
    }
    return sb.toString();
  }

  /// Tier → color band: ⬛ empty → 🟦 low → 🟩 → 🟨 → 🟧 → 🟥 → 🟪 max.
  static String emojiForTier(int tier) {
    if (tier <= 0) return '⬛';
    if (tier <= 2) return '🟦';
    if (tier <= 4) return '🟩';
    if (tier <= 6) return '🟨';
    if (tier <= 8) return '🟧';
    if (tier <= 10) return '🟥';
    return '🟪';
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/domain/engine/share_grid_builder_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/domain/engine/share_grid_builder.dart test/domain/engine/share_grid_builder_test.dart
git commit -m "feat(domain): add Wordle-style emoji share builder"
```

---

## Task 9: StorageService interface, models, and in-memory fake

**Files:**
- Create: `lib/infrastructure/storage_service.dart`
- Test: `test/infrastructure/in_memory_storage_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_loop/domain/constants.dart';
import 'package:merge_loop/domain/models/board_state.dart';
import 'package:merge_loop/domain/models/game_status.dart';
import 'package:merge_loop/domain/models/tile.dart';
import 'package:merge_loop/infrastructure/storage_service.dart';

BoardState sampleBoard() => BoardState(
      cells: List<Tile?>.filled(kCellCount, null),
      movesRemaining: 30,
      score: 0,
      nextTileId: 0,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 0,
      status: GameStatus.playing,
    );

void main() {
  test('snapshot round-trips through the in-memory fake', () async {
    final s = InMemoryStorageService();
    await s.init();
    expect(s.loadSnapshot(), isNull);

    final snap = GameSnapshot(date: '2026-06-06', board: sampleBoard(), completed: false);
    await s.saveSnapshot(snap);

    final loaded = s.loadSnapshot()!;
    expect(loaded.date, '2026-06-06');
    expect(loaded.completed, isFalse);
    expect(loaded.board.toJson(), snap.board.toJson());
  });

  test('stats default to zero and persist', () async {
    final s = InMemoryStorageService();
    await s.init();
    expect(s.loadStats().bestScore, 0);

    await s.saveStats(const LifetimeStats(
        streak: 3, lastCompletedDate: '2026-06-06', bestScore: 999, bestTier: 7));
    expect(s.loadStats().streak, 3);
    expect(s.loadStats().bestScore, 999);
  });

  test('GameSnapshot and LifetimeStats round-trip through json', () {
    final snap = GameSnapshot(date: '2026-06-06', board: sampleBoard(), completed: true);
    expect(GameSnapshot.fromJson(snap.toJson()).toJson(), snap.toJson());

    const stats = LifetimeStats(streak: 2, lastCompletedDate: '2026-06-05', bestScore: 50, bestTier: 4);
    expect(LifetimeStats.fromJson(stats.toJson()).toJson(), stats.toJson());
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/infrastructure/in_memory_storage_test.dart`
Expected: FAIL — symbols undefined.

- [ ] **Step 3: Write the implementation**

```dart
import '../domain/models/board_state.dart';

/// A persisted in-progress (or finished) day.
class GameSnapshot {
  final String date; // YYYY-MM-DD this snapshot belongs to
  final BoardState board;
  final bool completed; // true once the day is locked

  const GameSnapshot({
    required this.date,
    required this.board,
    required this.completed,
  });

  Map<String, dynamic> toJson() => {
        'date': date,
        'board': board.toJson(),
        'completed': completed,
      };

  static GameSnapshot fromJson(Map<String, dynamic> j) => GameSnapshot(
        date: j['date'] as String,
        board: BoardState.fromJson(Map<String, dynamic>.from(j['board'] as Map)),
        completed: j['completed'] as bool,
      );
}

/// Lifetime, cross-day stats for the offline result screen.
class LifetimeStats {
  final int streak;
  final String? lastCompletedDate;
  final int bestScore;
  final int bestTier;

  const LifetimeStats({
    required this.streak,
    required this.lastCompletedDate,
    required this.bestScore,
    required this.bestTier,
  });

  static const empty = LifetimeStats(
      streak: 0, lastCompletedDate: null, bestScore: 0, bestTier: 0);

  LifetimeStats copyWith({
    int? streak,
    String? lastCompletedDate,
    int? bestScore,
    int? bestTier,
  }) =>
      LifetimeStats(
        streak: streak ?? this.streak,
        lastCompletedDate: lastCompletedDate ?? this.lastCompletedDate,
        bestScore: bestScore ?? this.bestScore,
        bestTier: bestTier ?? this.bestTier,
      );

  Map<String, dynamic> toJson() => {
        'streak': streak,
        'lastCompletedDate': lastCompletedDate,
        'bestScore': bestScore,
        'bestTier': bestTier,
      };

  static LifetimeStats fromJson(Map<String, dynamic> j) => LifetimeStats(
        streak: j['streak'] as int,
        lastCompletedDate: j['lastCompletedDate'] as String?,
        bestScore: j['bestScore'] as int,
        bestTier: j['bestTier'] as int,
      );
}

/// Local persistence boundary. The Hive implementation lives in
/// hive_storage_service.dart; this in-memory fake is used by tests.
abstract class StorageService {
  Future<void> init();
  GameSnapshot? loadSnapshot();
  Future<void> saveSnapshot(GameSnapshot snapshot);
  LifetimeStats loadStats();
  Future<void> saveStats(LifetimeStats stats);
}

class InMemoryStorageService implements StorageService {
  GameSnapshot? _snapshot;
  LifetimeStats _stats = LifetimeStats.empty;

  @override
  Future<void> init() async {}

  @override
  GameSnapshot? loadSnapshot() => _snapshot;

  @override
  Future<void> saveSnapshot(GameSnapshot snapshot) async {
    _snapshot = snapshot;
  }

  @override
  LifetimeStats loadStats() => _stats;

  @override
  Future<void> saveStats(LifetimeStats stats) async {
    _stats = stats;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/infrastructure/in_memory_storage_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/infrastructure/storage_service.dart test/infrastructure/in_memory_storage_test.dart
git commit -m "feat(infra): add storage interface, snapshot/stats models, in-memory fake"
```

---

## Task 10: Hive storage implementation

**Files:**
- Create: `lib/infrastructure/hive_storage_service.dart`
- Test: `test/infrastructure/hive_storage_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:merge_loop/domain/constants.dart';
import 'package:merge_loop/domain/models/board_state.dart';
import 'package:merge_loop/domain/models/game_status.dart';
import 'package:merge_loop/domain/models/tile.dart';
import 'package:merge_loop/infrastructure/hive_storage_service.dart';
import 'package:merge_loop/infrastructure/storage_service.dart';

void main() {
  setUp(() {
    // Use a unique temp dir so each test run is isolated.
    Hive.init('${Directory.systemTemp.path}/merge_loop_test_${DateTime.now().microsecondsSinceEpoch}');
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
  });

  test('persists and reloads a snapshot via Hive', () async {
    final s = HiveStorageService();
    await s.init();

    final board = BoardState(
      cells: List<Tile?>.filled(kCellCount, null),
      movesRemaining: 29,
      score: 16,
      nextTileId: 9,
      dropIndex: 1,
      adContinuesUsed: 0,
      movesMade: 1,
      status: GameStatus.playing,
    );
    await s.saveSnapshot(GameSnapshot(date: '2026-06-06', board: board, completed: false));

    final loaded = s.loadSnapshot()!;
    expect(loaded.date, '2026-06-06');
    expect(loaded.board.score, 16);
    expect(loaded.board.dropIndex, 1);
  });

  test('json encoding is stable', () {
    const stats = LifetimeStats(streak: 1, lastCompletedDate: '2026-06-06', bestScore: 10, bestTier: 3);
    expect(LifetimeStats.fromJson(jsonDecode(jsonEncode(stats.toJson())) as Map<String, dynamic>).bestScore, 10);
  });
}
```

Note: add `import 'dart:io';` at the top of the test (for `Directory`).

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/infrastructure/hive_storage_test.dart`
Expected: FAIL — `HiveStorageService` undefined.

- [ ] **Step 3: Write the implementation**

```dart
import 'dart:convert';

import 'package:hive/hive.dart';

import 'storage_service.dart';

/// Hive-backed persistence. Values are stored as JSON strings to avoid
/// generated TypeAdapters — the payloads are small and this keeps the build
/// toolchain simple (no build_runner).
class HiveStorageService implements StorageService {
  static const _boxName = 'merge_loop';
  static const _snapshotKey = 'snapshot';
  static const _statsKey = 'stats';

  late Box<String> _box;

  @override
  Future<void> init() async {
    _box = await Hive.openBox<String>(_boxName);
  }

  @override
  GameSnapshot? loadSnapshot() {
    final raw = _box.get(_snapshotKey);
    if (raw == null) return null;
    return GameSnapshot.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  @override
  Future<void> saveSnapshot(GameSnapshot snapshot) async {
    await _box.put(_snapshotKey, jsonEncode(snapshot.toJson()));
  }

  @override
  LifetimeStats loadStats() {
    final raw = _box.get(_statsKey);
    if (raw == null) return LifetimeStats.empty;
    return LifetimeStats.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  @override
  Future<void> saveStats(LifetimeStats stats) async {
    await _box.put(_statsKey, jsonEncode(stats.toJson()));
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/infrastructure/hive_storage_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/infrastructure/hive_storage_service.dart test/infrastructure/hive_storage_test.dart
git commit -m "feat(infra): add Hive storage implementation"
```

---

## Task 11: GameState classes

**Files:**
- Create: `lib/application/game_state.dart`
- Test: `test/application/game_state_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_loop/application/game_state.dart';
import 'package:merge_loop/domain/constants.dart';
import 'package:merge_loop/domain/models/board_state.dart';
import 'package:merge_loop/domain/models/game_status.dart';
import 'package:merge_loop/domain/models/tile.dart';
import 'package:merge_loop/infrastructure/storage_service.dart';

BoardState b() => BoardState(
      cells: List<Tile?>.filled(kCellCount, null),
      movesRemaining: 30,
      score: 0,
      nextTileId: 0,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 0,
      status: GameStatus.playing,
    );

void main() {
  test('state subtypes carry their payloads', () {
    expect(GameInitial(), isA<GameState>());
    expect(GamePlaying(board: b()).board.movesRemaining, 30);
    final over = GameOverShowScore(
        board: b(), date: '2026-06-06', stats: LifetimeStats.empty);
    expect(over.date, '2026-06-06');
    expect(GameAdRewardGranted(board: b()).board, isA<BoardState>());
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/application/game_state_test.dart`
Expected: FAIL — symbols undefined.

- [ ] **Step 3: Write the implementation**

```dart
import '../domain/models/board_state.dart';
import '../infrastructure/storage_service.dart';

sealed class GameState {
  const GameState();
}

class GameInitial extends GameState {
  const GameInitial();
}

class GamePlaying extends GameState {
  final BoardState board;
  const GamePlaying({required this.board});
}

class GameOverShowScore extends GameState {
  final BoardState board;
  final String date;
  final LifetimeStats stats;
  const GameOverShowScore({
    required this.board,
    required this.date,
    required this.stats,
  });
}

/// Transient state emitted immediately before resuming play after a rewarded
/// ad, so the UI can flash feedback. The cubit emits GamePlaying right after.
class GameAdRewardGranted extends GameState {
  final BoardState board;
  const GameAdRewardGranted({required this.board});
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/application/game_state_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/application/game_state.dart test/application/game_state_test.dart
git commit -m "feat(app): add sealed GameState classes"
```

---

## Task 12: GameCubit (orchestration)

**Files:**
- Create: `lib/application/game_cubit.dart`
- Test: `test/application/game_cubit_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_loop/application/game_cubit.dart';
import 'package:merge_loop/application/game_state.dart';
import 'package:merge_loop/domain/constants.dart';
import 'package:merge_loop/domain/engine/daily_seeder.dart';
import 'package:merge_loop/domain/engine/game_engine.dart';
import 'package:merge_loop/domain/models/board_state.dart';
import 'package:merge_loop/domain/models/game_status.dart';
import 'package:merge_loop/infrastructure/storage_service.dart';

void main() {
  late InMemoryStorageService storage;
  GameCubit make(String date) =>
      GameCubit(storage: storage, todayProvider: () => date);

  setUp(() => storage = InMemoryStorageService());

  test('init on a fresh day seeds a playing board and persists it', () async {
    final c = make('2026-06-06');
    await c.init();
    expect(c.state, isA<GamePlaying>());
    final board = (c.state as GamePlaying).board;
    expect(board.filledCount, kStartingFill);
    expect(storage.loadSnapshot()!.date, '2026-06-06');
  });

  test('init routes to score screen when today already completed', () async {
    final seeded = DailySeeder('2026-06-06').generate().board.copyWith(
        status: GameStatus.outOfMoves, movesRemaining: 0);
    await storage.saveSnapshot(
        GameSnapshot(date: '2026-06-06', board: seeded, completed: true));

    final c = make('2026-06-06');
    await c.init();
    expect(c.state, isA<GameOverShowScore>());
  });

  test('a legal merge updates score, spends a move, and triggers one drop', () async {
    final c = make('2026-06-06');
    await c.init();
    var board = (c.state as GamePlaying).board;

    // Find any legal merge pair on the seeded board.
    final pair = _findMergePair(board);
    await c.merge(fromIndex: pair.$1, toIndex: pair.$2);

    final after = (c.state as GamePlaying).board;
    expect(after.movesMade, 1);
    expect(after.movesRemaining, kMovesPerDay - 1);
    expect(after.dropIndex, 1);
    expect(after.score, greaterThan(0));
    // occupancy is constant (merge frees one, drop fills one)
    expect(after.filledCount, board.filledCount);
  });

  test('grantAdReward adds moves, increments continues, resumes play', () async {
    // Build a board that is out of moves but still has a merge available.
    final start = DailySeeder('2026-06-06').generate().board;
    final outOfMoves = start.copyWith(movesRemaining: 0, status: GameStatus.outOfMoves);
    await storage.saveSnapshot(
        GameSnapshot(date: '2026-06-06', board: outOfMoves, completed: true));

    final c = make('2026-06-06');
    await c.init();
    expect(c.state, isA<GameOverShowScore>());
    expect(c.canOfferAd, GameEngine.hasMergeAvailable(outOfMoves));

    await c.grantAdReward();
    final board = (c.state as GamePlaying).board;
    expect(board.movesRemaining, kAdMoveReward);
    expect(board.adContinuesUsed, 1);
    expect(board.status, GameStatus.playing);
  });
}

(int, int) _findMergePair(BoardState b) {
  final byTier = <int, int>{};
  for (var i = 0; i < b.cells.length; i++) {
    final t = b.cells[i];
    if (t == null || t.tier >= kMaxTier) continue;
    if (byTier.containsKey(t.tier)) return (byTier[t.tier]!, i);
    byTier[t.tier] = i;
  }
  throw StateError('seeded board unexpectedly has no merge pair');
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/application/game_cubit_test.dart`
Expected: FAIL — `GameCubit` undefined.

- [ ] **Step 3: Write the implementation**

```dart
import 'package:flutter_bloc/flutter_bloc.dart';

import '../domain/constants.dart';
import '../domain/engine/daily_seeder.dart';
import '../domain/engine/game_engine.dart';
import '../domain/engine/prng.dart';
import '../domain/models/board_state.dart';
import '../domain/models/game_status.dart';
import '../infrastructure/storage_service.dart';
import 'game_state.dart';

/// Formats a DateTime as the canonical YYYY-MM-DD seeding key (local date).
String formatDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class GameCubit extends Cubit<GameState> {
  final StorageService storage;
  final String Function() todayProvider;

  late String _date;
  late List<int> _dropTiers;
  late Prng _landing;

  GameCubit({
    required this.storage,
    String Function()? todayProvider,
  })  : todayProvider = todayProvider ?? (() => formatDate(DateTime.now())),
        super(const GameInitial());

  Future<void> init() async {
    _date = todayProvider();
    final seeder = DailySeeder(_date);
    final start = seeder.generate();
    _dropTiers = start.dropTiers;

    final snap = storage.loadSnapshot();
    if (snap != null && snap.date == _date) {
      // Resume today: rebuild the landing stream to the saved position.
      _landing = seeder.landingPrng();
      for (var i = 0; i < snap.board.dropIndex; i++) {
        _landing.nextU32();
      }
      if (snap.completed || snap.board.status != GameStatus.playing) {
        emit(GameOverShowScore(
            board: snap.board, date: _date, stats: storage.loadStats()));
      } else {
        emit(GamePlaying(board: snap.board));
      }
      return;
    }

    // Fresh day.
    _landing = seeder.landingPrng();
    await storage.saveSnapshot(
        GameSnapshot(date: _date, board: start.board, completed: false));
    emit(GamePlaying(board: start.board));
  }

  Future<void> merge({required int fromIndex, required int toIndex}) async {
    final s = state;
    if (s is! GamePlaying) return;
    if (!GameEngine.canMerge(s.board, fromIndex, toIndex)) return;

    var board = GameEngine.merge(s.board, fromIndex: fromIndex, toIndex: toIndex);
    if (board.dropIndex < _dropTiers.length) {
      board = GameEngine.applyDrop(board, _dropTiers[board.dropIndex], _landing);
    }
    board = GameEngine.evaluateStatus(board);

    final done = board.status != GameStatus.playing;
    await storage.saveSnapshot(
        GameSnapshot(date: _date, board: board, completed: done));

    if (done) {
      final stats = await _recordCompletion(board);
      emit(GameOverShowScore(board: board, date: _date, stats: stats));
    } else {
      emit(GamePlaying(board: board));
    }
  }

  /// True when the player ran out of moves, a merge still exists, and the daily
  /// ad-continue allowance is not exhausted. Deadlock is never ad-revivable.
  bool get canOfferAd {
    final s = state;
    return s is GameOverShowScore &&
        s.board.status == GameStatus.outOfMoves &&
        s.board.adContinuesUsed < kMaxAdContinuesPerDay &&
        GameEngine.hasMergeAvailable(s.board);
  }

  Future<void> grantAdReward() async {
    final s = state;
    if (s is! GameOverShowScore) return;
    final board = s.board.copyWith(
      movesRemaining: s.board.movesRemaining + kAdMoveReward,
      adContinuesUsed: s.board.adContinuesUsed + 1,
      status: GameStatus.playing,
    );
    await storage.saveSnapshot(
        GameSnapshot(date: _date, board: board, completed: false));
    emit(GameAdRewardGranted(board: board));
    emit(GamePlaying(board: board));
  }

  /// Update lifetime stats once per completed day (idempotent within a day via
  /// lastCompletedDate guard).
  Future<LifetimeStats> _recordCompletion(BoardState board) async {
    final prev = storage.loadStats();
    if (prev.lastCompletedDate == _date) return prev;

    final yesterday = formatDate(
        DateTime.parse(_date).subtract(const Duration(days: 1)));
    final streak = prev.lastCompletedDate == yesterday ? prev.streak + 1 : 1;

    final updated = prev.copyWith(
      streak: streak,
      lastCompletedDate: _date,
      bestScore: board.score > prev.bestScore ? board.score : prev.bestScore,
      bestTier:
          board.highestTier > prev.bestTier ? board.highestTier : prev.bestTier,
    );
    await storage.saveStats(updated);
    return updated;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/application/game_cubit_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/application/game_cubit.dart test/application/game_cubit_test.dart
git commit -m "feat(app): add GameCubit orchestration with resume and ad reward"
```

---

## Task 13: AdConfig and AdService

**Files:**
- Create: `lib/infrastructure/ad_config.dart`, `lib/infrastructure/ad_service.dart`
- Test: `test/infrastructure/ad_config_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_loop/infrastructure/ad_config.dart';

void main() {
  test('uses Google test unit IDs while useTestAds is true', () {
    expect(AdConfig.useTestAds, isTrue);
    expect(AdConfig.bannerUnitId, isNotEmpty);
    expect(AdConfig.rewardedUnitId, isNotEmpty);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/infrastructure/ad_config_test.dart`
Expected: FAIL — `AdConfig` undefined.

- [ ] **Step 3: Write the implementations**

`lib/infrastructure/ad_config.dart`:
```dart
import 'dart:io' show Platform;

/// Centralizes AdMob unit IDs. Ships with Google's official TEST IDs so the app
/// builds and runs with no AdMob account. Before release: set [useTestAds] to
/// false and fill in the real unit IDs (and the App IDs in the native manifests).
class AdConfig {
  const AdConfig._();

  static const bool useTestAds = true;

  // Google test unit IDs (safe to ship while developing).
  static const _testBannerAndroid = 'ca-app-pub-3940256099942544/6300978111';
  static const _testBannerIos = 'ca-app-pub-3940256099942544/2934735716';
  static const _testRewardedAndroid = 'ca-app-pub-3940256099942544/5224354917';
  static const _testRewardedIos = 'ca-app-pub-3940256099942544/1712485313';

  // TODO(release): replace with real unit IDs before publishing.
  static const _realBannerAndroid = 'ca-app-pub-0000000000000000/0000000000';
  static const _realBannerIos = 'ca-app-pub-0000000000000000/0000000000';
  static const _realRewardedAndroid = 'ca-app-pub-0000000000000000/0000000000';
  static const _realRewardedIos = 'ca-app-pub-0000000000000000/0000000000';

  static bool get _ios => Platform.isIOS;

  static String get bannerUnitId => useTestAds
      ? (_ios ? _testBannerIos : _testBannerAndroid)
      : (_ios ? _realBannerIos : _realBannerAndroid);

  static String get rewardedUnitId => useTestAds
      ? (_ios ? _testRewardedIos : _testRewardedAndroid)
      : (_ios ? _realRewardedIos : _realRewardedAndroid);
}
```

`lib/infrastructure/ad_service.dart`:
```dart
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ad_config.dart';

/// Isolates all google_mobile_ads lifecycle so the rest of the app never
/// imports the plugin directly.
class AdService {
  RewardedAd? _rewarded;

  Future<void> init() async {
    await MobileAds.instance.initialize();
    _preloadRewarded();
  }

  /// Builds a fresh banner ad. The caller is responsible for disposing it.
  BannerAd createBanner() {
    return BannerAd(
      adUnitId: AdConfig.bannerUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: const BannerAdListener(),
    )..load();
  }

  void _preloadRewarded() {
    RewardedAd.load(
      adUnitId: AdConfig.rewardedUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) => _rewarded = ad,
        onAdFailedToLoad: (_) => _rewarded = null,
      ),
    );
  }

  /// Shows a rewarded ad. Calls [onReward] exactly once if the user earns the
  /// reward, then preloads the next ad. [onUnavailable] fires if none is ready.
  void showRewarded({
    required void Function() onReward,
    required void Function() onUnavailable,
  }) {
    final ad = _rewarded;
    if (ad == null) {
      onUnavailable();
      _preloadRewarded();
      return;
    }
    var rewarded = false;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _rewarded = null;
        _preloadRewarded();
      },
      onAdFailedToShowFullScreenContent: (ad, _) {
        ad.dispose();
        _rewarded = null;
        onUnavailable();
        _preloadRewarded();
      },
    );
    ad.show(onUserEarnedReward: (_, __) {
      if (!rewarded) {
        rewarded = true;
        onReward();
      }
    });
  }

  void dispose() {
    _rewarded?.dispose();
    _rewarded = null;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/infrastructure/ad_config_test.dart`
Expected: PASS. (AdService itself is exercised by manual run in Task 18 — it requires the platform plugin.)

- [ ] **Step 5: Commit**

```bash
git add lib/infrastructure/ad_config.dart lib/infrastructure/ad_service.dart test/infrastructure/ad_config_test.dart
git commit -m "feat(infra): add AdConfig (test IDs) and AdService lifecycle"
```

---

## Task 14: Tile palette and GridCellWidget

**Files:**
- Create: `lib/presentation/theme/tile_palette.dart`, `lib/presentation/widgets/grid_cell_widget.dart`
- Test: `test/presentation/grid_cell_widget_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_loop/domain/models/tile.dart';
import 'package:merge_loop/presentation/widgets/grid_cell_widget.dart';

void main() {
  testWidgets('renders the tile value 2^tier', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: GridCellWidget(tile: Tile(id: 1, tier: 5), size: 60),
      ),
    ));
    expect(find.text('32'), findsOneWidget); // 2^5
  });

  testWidgets('empty cell renders no value text', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: GridCellWidget(tile: null, size: 60)),
    ));
    expect(find.byType(Text), findsNothing);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/presentation/grid_cell_widget_test.dart`
Expected: FAIL — `GridCellWidget` undefined.

- [ ] **Step 3: Write the implementations**

`lib/presentation/theme/tile_palette.dart`:
```dart
import 'package:flutter/material.dart';

/// Maps a tier to its tile color. Tier 0 (empty) uses a translucent slot color.
class TilePalette {
  const TilePalette._();

  static const _colors = <Color>[
    Color(0x14FFFFFF), // 0 empty slot
    Color(0xFF3B82F6), // 1
    Color(0xFF06B6D4), // 2
    Color(0xFF10B981), // 3
    Color(0xFF84CC16), // 4
    Color(0xFFEAB308), // 5
    Color(0xFFF59E0B), // 6
    Color(0xFFF97316), // 7
    Color(0xFFEF4444), // 8
    Color(0xFFEC4899), // 9
    Color(0xFFA855F7), // 10
    Color(0xFF7C3AED), // 11 (2048)
  ];

  static Color colorForTier(int tier) =>
      _colors[tier.clamp(0, _colors.length - 1)];

  static Color textColorForTier(int tier) => Colors.white;
}
```

`lib/presentation/widgets/grid_cell_widget.dart`:
```dart
import 'package:flutter/material.dart';

import '../../domain/models/tile.dart';
import '../theme/tile_palette.dart';

/// Renders a single tile face (or an empty slot if [tile] is null).
class GridCellWidget extends StatelessWidget {
  final Tile? tile;
  final double size;

  const GridCellWidget({super.key, required this.tile, required this.size});

  @override
  Widget build(BuildContext context) {
    final t = tile;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: TilePalette.colorForTier(t?.tier ?? 0),
        borderRadius: BorderRadius.circular(size * 0.16),
      ),
      alignment: Alignment.center,
      child: t == null
          ? null
          : FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: EdgeInsets.all(size * 0.12),
                child: Text(
                  '${t.value}',
                  style: TextStyle(
                    color: TilePalette.textColorForTier(t.tier),
                    fontWeight: FontWeight.w800,
                    fontSize: size * 0.34,
                  ),
                ),
              ),
            ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/presentation/grid_cell_widget_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/presentation/theme/tile_palette.dart lib/presentation/widgets/grid_cell_widget.dart test/presentation/grid_cell_widget_test.dart
git commit -m "feat(ui): add tile palette and GridCellWidget"
```

---

## Task 15: BoardWidget (animated drag-to-merge board)

**Files:**
- Create: `lib/presentation/widgets/board_widget.dart`
- Test: `test/presentation/board_widget_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_loop/domain/constants.dart';
import 'package:merge_loop/domain/models/board_state.dart';
import 'package:merge_loop/domain/models/game_status.dart';
import 'package:merge_loop/domain/models/tile.dart';
import 'package:merge_loop/presentation/widgets/board_widget.dart';

void main() {
  testWidgets('reports a merge when a tile is dragged onto a matching tile', (tester) async {
    final cells = List<Tile?>.filled(kCellCount, null);
    cells[0] = const Tile(id: 1, tier: 2);
    cells[1] = const Tile(id: 2, tier: 2);
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

    int? gotFrom, gotTo;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BoardWidget(
          board: board,
          onMerge: (from, to) {
            gotFrom = from;
            gotTo = to;
          },
        ),
      ),
    ));

    // Two tiles of tier 2 are rendered.
    expect(find.text('4'), findsNWidgets(2));

    final gesture = await tester.startGesture(tester.getCenter(find.text('4').first));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(tester.getCenter(find.text('4').last));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(gotFrom, 0);
    expect(gotTo, 1);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/presentation/board_widget_test.dart`
Expected: FAIL — `BoardWidget` undefined.

- [ ] **Step 3: Write the implementation**

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/constants.dart';
import '../../domain/models/board_state.dart';
import '../../domain/models/tile.dart';
import 'grid_cell_widget.dart';

/// Renders the 5×5 board as a static slot grid (painted backing) with live
/// tiles floating above as AnimatedPositioned widgets keyed by tile id, so
/// merges slide and drops fall smoothly. Drag a tile onto a matching tile to
/// merge; [onMerge] is invoked with (fromIndex, toIndex).
class BoardWidget extends StatelessWidget {
  final BoardState board;
  final void Function(int fromIndex, int toIndex) onMerge;

  const BoardWidget({super.key, required this.board, required this.onMerge});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 8.0;
        final boardSize = constraints.maxWidth;
        final cell = (boardSize - gap * (kGridSize + 1)) / kGridSize;

        Offset offsetFor(int index) {
          final row = index ~/ kGridSize;
          final col = index % kGridSize;
          return Offset(
            gap + col * (cell + gap),
            gap + row * (cell + gap),
          );
        }

        final children = <Widget>[];

        // Static backing slots + drag targets.
        for (var i = 0; i < kCellCount; i++) {
          final pos = offsetFor(i);
          children.add(Positioned(
            left: pos.dx,
            top: pos.dy,
            child: DragTarget<int>(
              onWillAcceptWithDetails: (d) =>
                  _isMergeable(d.data, i),
              onAcceptWithDetails: (d) {
                HapticFeedback.mediumImpact();
                onMerge(d.data, i);
              },
              builder: (context, _, __) =>
                  const GridCellWidget(tile: null, size: 0).buildSlot(cell),
            ),
          ));
        }

        // Floating live tiles, keyed by id.
        for (var i = 0; i < kCellCount; i++) {
          final tile = board.cells[i];
          if (tile == null) continue;
          final pos = offsetFor(i);
          children.add(AnimatedPositioned(
            key: ValueKey(tile.id),
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            left: pos.dx,
            top: pos.dy,
            width: cell,
            height: cell,
            child: _DraggableTile(
              index: i,
              tile: tile,
              size: cell,
            ),
          ));
        }

        return SizedBox(
          width: boardSize,
          height: boardSize,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF1E2230),
              borderRadius: BorderRadius.circular(gap * 1.5),
            ),
            child: Stack(children: children),
          ),
        );
      },
    );
  }

  bool _isMergeable(int fromIndex, int toIndex) {
    if (fromIndex == toIndex) return false;
    final from = board.cells[fromIndex];
    final to = board.cells[toIndex];
    if (from == null || to == null) return false;
    return from.tier == to.tier && from.tier < kMaxTier;
  }
}

class _DraggableTile extends StatelessWidget {
  final int index;
  final Tile tile;
  final double size;

  const _DraggableTile({
    required this.index,
    required this.tile,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final face = GridCellWidget(tile: tile, size: size);
    return Draggable<int>(
      data: index,
      feedback: Transform.scale(scale: 1.1, child: face),
      childWhenDragging: Opacity(opacity: 0.25, child: face),
      child: face,
    );
  }
}

/// Helper to render an empty backing slot at a given size.
extension on GridCellWidget {
  Widget buildSlot(double size) => GridCellWidget(tile: null, size: size);
}
```

Note: the `buildSlot` extension exists only to keep slot sizing in one place; if it reads awkwardly during implementation, inline `GridCellWidget(tile: null, size: cell)` directly in the DragTarget builder and delete the extension.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/presentation/board_widget_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/presentation/widgets/board_widget.dart test/presentation/board_widget_test.dart
git commit -m "feat(ui): add animated drag-to-merge BoardWidget"
```

---

## Task 16: MovesCounter, BannerSlot, RewardedDialog

**Files:**
- Create: `lib/presentation/widgets/moves_counter.dart`, `lib/presentation/widgets/banner_slot.dart`, `lib/presentation/widgets/rewarded_dialog.dart`
- Test: `test/presentation/moves_counter_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_loop/presentation/widgets/moves_counter.dart';

void main() {
  testWidgets('shows moves remaining and score', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: MovesCounter(movesRemaining: 12, score: 256)),
    ));
    expect(find.text('12'), findsOneWidget);
    expect(find.text('256'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/presentation/moves_counter_test.dart`
Expected: FAIL — `MovesCounter` undefined.

- [ ] **Step 3: Write the implementations**

`lib/presentation/widgets/moves_counter.dart`:
```dart
import 'package:flutter/material.dart';

class MovesCounter extends StatelessWidget {
  final int movesRemaining;
  final int score;

  const MovesCounter({
    super.key,
    required this.movesRemaining,
    required this.score,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _stat(context, 'MOVES', '$movesRemaining'),
        _stat(context, 'SCORE', '$score'),
      ],
    );
  }

  Widget _stat(BuildContext context, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 12, letterSpacing: 1.5, color: Colors.white54)),
        Text(value,
            style: const TextStyle(
                fontSize: 28, fontWeight: FontWeight.w800, color: Colors.white)),
      ],
    );
  }
}
```

`lib/presentation/widgets/banner_slot.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../../infrastructure/ad_service.dart';

/// Persistent bottom banner area. The height is reserved up front (standard
/// 320×50 banner) so the layout never shifts when the ad loads.
class BannerSlot extends StatefulWidget {
  final AdService adService;
  const BannerSlot({super.key, required this.adService});

  @override
  State<BannerSlot> createState() => _BannerSlotState();
}

class _BannerSlotState extends State<BannerSlot> {
  BannerAd? _banner;

  @override
  void initState() {
    super.initState();
    _banner = widget.adService.createBanner();
  }

  @override
  void dispose() {
    _banner?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final banner = _banner;
    return SizedBox(
      height: 50,
      width: double.infinity,
      child: banner == null ? const SizedBox.shrink() : AdWidget(ad: banner),
    );
  }
}
```

`lib/presentation/widgets/rewarded_dialog.dart`:
```dart
import 'package:flutter/material.dart';

import '../../domain/constants.dart';

/// Out-of-moves prompt offering a rewarded video for extra moves. Returns true
/// (via [onWatch]) when the user opts in, or dismisses otherwise.
class RewardedDialog extends StatelessWidget {
  final VoidCallback onWatch;
  final VoidCallback onDecline;

  const RewardedDialog({
    super.key,
    required this.onWatch,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Out of moves!'),
      content: Text(
          'Watch a short video for +$kAdMoveReward moves and keep your run going.'),
      actions: [
        TextButton(onPressed: onDecline, child: const Text('No thanks')),
        FilledButton(
            onPressed: onWatch, child: Text('Watch for +$kAdMoveReward')),
      ],
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/presentation/moves_counter_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/presentation/widgets/moves_counter.dart lib/presentation/widgets/banner_slot.dart lib/presentation/widgets/rewarded_dialog.dart test/presentation/moves_counter_test.dart
git commit -m "feat(ui): add moves counter, banner slot, rewarded dialog"
```

---

## Task 17: GameScreen and ScoreShareScreen

**Files:**
- Create: `lib/presentation/screens/game_screen.dart`, `lib/presentation/screens/score_share_screen.dart`
- Test: `test/presentation/score_share_screen_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_loop/domain/constants.dart';
import 'package:merge_loop/domain/models/board_state.dart';
import 'package:merge_loop/domain/models/game_status.dart';
import 'package:merge_loop/domain/models/tile.dart';
import 'package:merge_loop/infrastructure/storage_service.dart';
import 'package:merge_loop/presentation/screens/score_share_screen.dart';

void main() {
  testWidgets('shows score, best tier, streak, and copies share text', (tester) async {
    final cells = List<Tile?>.filled(kCellCount, null);
    cells[0] = const Tile(id: 1, tier: 6);
    final board = BoardState(
      cells: cells,
      movesRemaining: 0,
      score: 1234,
      nextTileId: 2,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 30,
      status: GameStatus.outOfMoves,
    );

    final copied = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });

    await tester.pumpWidget(MaterialApp(
      home: ScoreShareScreen(
        board: board,
        date: '2026-06-06',
        stats: const LifetimeStats(
            streak: 4, lastCompletedDate: '2026-06-06', bestScore: 5000, bestTier: 9),
        canOfferAd: false,
        onWatchAd: () {},
      ),
    ));

    expect(find.text('1234'), findsWidgets); // score shown
    expect(find.textContaining('4'), findsWidgets); // streak shown somewhere

    await tester.tap(find.text('Share'));
    await tester.pump();
    expect(copied.single, contains('Merge Loop 2026-06-06'));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/presentation/score_share_screen_test.dart`
Expected: FAIL — `ScoreShareScreen` undefined.

- [ ] **Step 3: Write the implementations**

`lib/presentation/screens/score_share_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/engine/share_grid_builder.dart';
import '../../domain/models/board_state.dart';
import '../../infrastructure/storage_service.dart';

/// Offline daily result: the player's own score/tier/moves plus local personal
/// stats. The emoji share is the (offline) comparison mechanism.
class ScoreShareScreen extends StatelessWidget {
  final BoardState board;
  final String date;
  final LifetimeStats stats;
  final bool canOfferAd;
  final VoidCallback onWatchAd;

  const ScoreShareScreen({
    super.key,
    required this.board,
    required this.date,
    required this.stats,
    required this.canOfferAd,
    required this.onWatchAd,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12141C),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Daily Result',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 24),
              _bigStat('SCORE', '${board.score}'),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _smallStat('BEST TILE', '${1 << board.highestTier}'),
                  _smallStat('MOVES', '${board.movesMade}'),
                  _smallStat('STREAK', '${stats.streak}'),
                ],
              ),
              const SizedBox(height: 8),
              _smallStat('BEST EVER', '${stats.bestScore}'),
              const SizedBox(height: 24),
              if (canOfferAd)
                FilledButton.tonal(
                  onPressed: onWatchAd,
                  child: const Text('Watch ad for more moves'),
                ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => _share(context),
                child: const Text('Share'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _share(BuildContext context) async {
    final text = ShareGridBuilder.build(date: date, board: board);
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Result copied to clipboard!')),
      );
    }
  }

  Widget _bigStat(String label, String value) => Column(
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white54, letterSpacing: 2)),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 48,
                  fontWeight: FontWeight.w900)),
        ],
      );

  Widget _smallStat(String label, String value) => Column(
        children: [
          Text(label,
              style: const TextStyle(
                  color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700)),
        ],
      );
}
```

`lib/presentation/screens/game_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../application/game_cubit.dart';
import '../../application/game_state.dart';
import '../../infrastructure/ad_service.dart';
import '../widgets/banner_slot.dart';
import '../widgets/board_widget.dart';
import '../widgets/moves_counter.dart';
import '../widgets/rewarded_dialog.dart';
import 'score_share_screen.dart';

class GameScreen extends StatelessWidget {
  final AdService adService;
  const GameScreen({super.key, required this.adService});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12141C),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: BlocConsumer<GameCubit, GameState>(
                listener: (context, state) {
                  if (state is GameOverShowScore) {
                    final cubit = context.read<GameCubit>();
                    if (cubit.canOfferAd) {
                      _promptRewarded(context, cubit);
                    }
                  }
                },
                builder: (context, state) {
                  return switch (state) {
                    GameInitial() =>
                      const Center(child: CircularProgressIndicator()),
                    GameAdRewardGranted(:final board) ||
                    GamePlaying(:final board) =>
                      _buildPlaying(context, board),
                    GameOverShowScore(:final board, :final date, :final stats) =>
                      ScoreShareScreen(
                        board: board,
                        date: date,
                        stats: stats,
                        canOfferAd: context.read<GameCubit>().canOfferAd,
                        onWatchAd: () =>
                            _watchRewarded(context, context.read<GameCubit>()),
                      ),
                  };
                },
              ),
            ),
            BannerSlot(adService: adService),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaying(BuildContext context, board) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          MovesCounter(
              movesRemaining: board.movesRemaining, score: board.score),
          const SizedBox(height: 24),
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: BoardWidget(
                  board: board,
                  onMerge: (from, to) => context
                      .read<GameCubit>()
                      .merge(fromIndex: from, toIndex: to),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _promptRewarded(BuildContext context, GameCubit cubit) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => RewardedDialog(
        onWatch: () {
          Navigator.of(dialogContext).pop();
          _watchRewarded(context, cubit);
        },
        onDecline: () => Navigator.of(dialogContext).pop(),
      ),
    );
  }

  void _watchRewarded(BuildContext context, GameCubit cubit) {
    adService.showRewarded(
      onReward: () => cubit.grantAdReward(),
      onUnavailable: () {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No ad available right now.')),
          );
        }
      },
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/presentation/score_share_screen_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/presentation/screens/ test/presentation/score_share_screen_test.dart
git commit -m "feat(ui): add GameScreen and offline ScoreShareScreen"
```

---

## Task 18: main.dart wiring + native AdMob config + manual verification

**Files:**
- Modify: `lib/main.dart`, `android/app/src/main/AndroidManifest.xml`, `ios/Runner/Info.plist`

- [ ] **Step 1: Write `lib/main.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'application/game_cubit.dart';
import 'infrastructure/ad_service.dart';
import 'infrastructure/hive_storage_service.dart';
import 'presentation/screens/game_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();
  final storage = HiveStorageService();
  await storage.init();

  final adService = AdService();
  await adService.init();

  runApp(MergeLoopApp(storage: storage, adService: adService));
}

class MergeLoopApp extends StatelessWidget {
  final HiveStorageService storage;
  final AdService adService;

  const MergeLoopApp({
    super.key,
    required this.storage,
    required this.adService,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Merge Loop',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: BlocProvider(
        create: (_) => GameCubit(storage: storage)..init(),
        child: GameScreen(adService: adService),
      ),
    );
  }
}
```

- [ ] **Step 2: Add the AdMob App ID to `android/app/src/main/AndroidManifest.xml`**

Inside `<application ...>` (uses the official Android **test App ID**):
```xml
<meta-data
    android:name="com.google.android.gms.ads.APPLICATION_ID"
    android:value="ca-app-pub-3940256099942544~3347511713"/>
```

- [ ] **Step 3: Add the AdMob App ID to `ios/Runner/Info.plist`**

Inside the top-level `<dict>` (official iOS **test App ID**):
```xml
<key>GADApplicationIdentifier</key>
<string>ca-app-pub-3940256099942544~1458002511</string>
```

- [ ] **Step 4: Verify the whole suite and a static analysis pass**

Run:
```bash
flutter analyze
flutter test
```
Expected: "No issues found!" and all tests passing.

- [ ] **Step 5: Manual smoke test on a device/emulator**

Run: `flutter run`
Verify by observation (the parts tests can't cover — feel and ads):
- Board renders 8 tiles; dragging a tile onto a matching tile merges (Tier+1), slides smoothly, and fires haptic feedback.
- Score and moves update; a new tile drops after each merge.
- Test banner shows at the bottom without shifting the layout.
- Spend all 30 moves → out-of-moves dialog offers a rewarded video; completing the test video grants +3 moves.
- Force a deadlock (or wait out moves) → score screen shows score, best tile, moves, streak; Share copies the emoji block (paste to confirm).
- Kill and relaunch the app same day → routes straight to the score screen.

- [ ] **Step 6: Commit**

```bash
git add lib/main.dart android/app/src/main/AndroidManifest.xml ios/Runner/Info.plist
git commit -m "feat: wire main, Hive/Ads init, and native AdMob app IDs"
```

---

## Self-Review (completed during plan authoring)

**Spec coverage:**
- §2.1 board/tiers → Tasks 2, 4, 5 ✓
- §2.2 move loop / merges-only / drop-per-move → Task 7 + Task 12 ✓
- §2.3 constant population (8) → Task 7 (merge+drop) verified in Task 12 cubit test ✓
- §2.4 end conditions (out-of-moves, deadlock) → Task 7 `evaluateStatus` ✓
- §2.5 determinism (SHA-256 → Mulberry32, index-scaled drops, dual stream, local landing) → Tasks 3, 6 ✓
- §3 DDD layering / pure domain → enforced by Tasks 2–8 (no Flutter imports) ✓
- §3.2 cubit flow (init/restore/merge/ad) → Task 12 ✓
- §4 presentation (Stack+AnimatedPositioned, Draggable, haptics) → Tasks 14–17 ✓
- §4.1 offline result + personal stats → Tasks 9, 12, 17 ✓
- §5 rewarded/banner/ad config/share → Tasks 8, 13, 16, 17 ✓
- §6 deps / Hive → Tasks 1, 10 ✓
- §7 tunable constants → Task 2 ✓
- §8 acceptance criteria → covered across unit + Task 18 manual checklist ✓
- §10 Phase 2 deferral → intentionally not implemented ✓

**Placeholder scan:** No "TBD"/"handle edge cases" steps; every code step shows full code. The only `TODO` is the intentional real-ad-ID swap marker in `AdConfig`, documented as release work.

**Type consistency:** `BoardState` fields (incl. `movesMade`) are consistent across Tasks 5, 7, 9, 12, 17. `GameEngine` static method names (`canMerge`, `merge`, `applyDrop`, `hasMergeAvailable`, `evaluateStatus`) match between Tasks 7 and 12. `StorageService` method names match between Tasks 9, 10, 12. `GameState` subtypes match between Tasks 11, 12, 17.
