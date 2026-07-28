# Dual-Engine Board-Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Dart↔TS board-generation parity a dense, structural check (1,825 committed digests) independent of full-run replay, and collapse the duplicated TS deadlock scan that is the drift's structural cause.

**Architecture:** A committed `board_vectors.json` holds one SHA-256 digest of each daily generated board (365 days × 5 difficulties). Dart authors it and asserts against it; Deno recomputes with the TS engine and asserts equality — the same handoff as `golden_vectors.json`, but board-only and dense. Two supporting TS refactors remove/​single-source the generation code the digest exercises.

**Tech Stack:** Flutter (Dart, `package:crypto` `sha256`, `flutter_test`), Deno (TypeScript, `crypto.subtle`, `jsr:@std/assert`).

**Design doc:** `docs/superpowers/specs/2026-07-28-dual-engine-board-parity-design.md`

## Global Constraints

- **Dual-engine byte-parity:** any change to merge validity, scoring, deadlock detection, or seeded generation in Dart must be mirrored into the TS port; results must be identical. This plan does not change any rule — Tasks 1–2 are behavior-preserving refactors, Tasks 3–4 only observe.
- **Regen discipline:** `board_vectors.json` regenerates only under `UPDATE_GOLDENS=1`, same flag as the golden vectors. **No `season` field** — board digests never touch the leaderboard.
- **`kLeaderboardSeason`** stays untouched (no rule change here).
- **Canonical digest string (verbatim, both languages):** `g=<gridSize>;m=<movesRemaining>;cells=<c0>,...,<cN-1>;walls=<w0>,...;drops=<d0>,...,<d38>;rule=<name|->;mcl=<minChainLength>` where `cells[i]` = tier or `x` (null), `walls` sorted ascending, `drops` = 39 values from the `':drops'` stream, `rule` = `-` for standard, `mcl` = `2` for standard.
- **Toolchain:** Flutter 3.44.2, Deno 2.8.3 (from `.github/workflows/test.yml`).

---

### Task 1: Collapse the duplicated TS deadlock scan

**Files:**
- Modify: `supabase/functions/_shared/engine.ts:199-217` (`hasMergeAvailable` body) and its import block (`:32`)
- Test (existing safety net): `supabase/functions/_shared/engine.test.ts`

**Interfaces:**
- Consumes: `hasChainOfLength(cells, gridSize, minLength)` — already imported in `engine.ts:21`, already delegates to `constants.ts` `hasAnyMergeablePair` for `minLength <= 2`.
- Produces: `hasMergeAvailable(s: BoardState): boolean` — unchanged public signature; now a one-line delegation.

This is a behavior-preserving refactor. `engine.test.ts` already pins `hasMergeAvailable` (`:208, :365, :510-538`), including `"hasChainOfLength: minLength <= 2 is byte-identical to hasMergeAvailable"` (`:529`) — that suite is the gate.

- [ ] **Step 1: Run the existing scan tests to confirm a green baseline**

Run: `deno test supabase/functions/_shared/engine.test.ts`
Expected: PASS (all existing tests green before touching anything).

- [ ] **Step 2: Replace the duplicated loop with a delegation**

In `supabase/functions/_shared/engine.ts`, replace the whole `hasMergeAvailable` function (currently `:196-217`, including its doc comment) with:

```typescript
/**
 * True if any two orthogonally-adjacent live tiles could legally merge in
 * SOME direction (spatial deadlock — non-adjacent mergeable tiles do NOT
 * count). Delegates to the single scan in `constants.ts` (`hasAnyMergeablePair`,
 * reached via `hasChainOfLength` at minLength 2) so the adjacency scan is
 * written exactly once in TypeScript. Must stay in lockstep with Dart
 * `GameEngine.hasMergeAvailable`.
 */
export function hasMergeAvailable(s: BoardState): boolean {
  return hasChainOfLength(s.cells, s.gridSize, 2);
}
```

- [ ] **Step 3: Drop the now-unused `pairMergeable` import**

In the `from "./constants.ts"` import block (`engine.ts:13-36`), remove the line:

```typescript
  pairMergeable,
```

(`pairMergeable` was used only inside the old `hasMergeAvailable` loop; leaving it imported would be dead code / a lint failure.)

- [ ] **Step 4: Run the full Deno suite**

Run: `deno test supabase/functions/`
Expected: PASS. In particular `engine.test.ts:529` still passes — `hasMergeAvailable` now *is* `hasChainOfLength(...,2)`, so byte-identity holds by construction. Type-check is clean (no unused import).

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/_shared/engine.ts
git commit -m "refactor(engine-ts): single-source the deadlock scan

hasMergeAvailable delegates to hasChainOfLength (constants.ts
hasAnyMergeablePair); removes the second TS copy of the adjacency
scan — the same duplication that let the seeder's 4th copy drift."
```

---

### Task 2: Extract `seedChallengeStart` from `verifyRunChallenge`

**Files:**
- Modify: `supabase/functions/_shared/engine.ts` — add `ChallengeStart` + `seedChallengeStart`; refactor `verifyRunChallenge` (`:348-372`); extend two type imports
- Test (existing safety net): `supabase/functions/_shared/golden_vectors.test.ts` (challenge vectors), `engine.test.ts`

**Interfaces:**
- Consumes: `challengeRule`, `DailySeeder` (`seeder.ts`); `kChallengeDenseFill`, `kChallengeSparseFill`, `kChallengeWallMazeCount`, `kChallengeMoves`, `kMovesPerDay`, `STARTING_FILL`, `minChainLengthFor`, `comboMultiplier`, `comboRushMultiplier` (all already imported in `engine.ts:13-36`).
- Produces: `export async function seedChallengeStart(date: string): Promise<ChallengeStart>` where `ChallengeStart = { rule: ChallengeRule; start: DailyStart; startingFill: number; movesOverride: number; minChainLength: number; multiplierFn: (n: number) => number }`. **Task 4 consumes `seedChallengeStart(date).start.board`.**

Behavior-preserving extraction; the existing challenge golden vectors replay through `verifyRunChallenge` and are the faithfulness gate.

- [ ] **Step 1: Confirm a green baseline**

Run: `deno test supabase/functions/_shared/golden_vectors.test.ts`
Expected: PASS (challenge vectors currently replay cleanly).

- [ ] **Step 2: Extend the type imports in `engine.ts`**

In the `from "./seeder.ts"` import (`engine.ts:12`), add `type DailyStart`:

```typescript
import { challengeRule, DailySeeder, type DailyStart } from "./seeder.ts";
```

In the `from "./constants.ts"` import block, add `type ChallengeRule` (alphabetically, e.g. after `canFollow`):

```typescript
  type ChallengeRule,
```

- [ ] **Step 3: Add `ChallengeStart` + `seedChallengeStart` above `verifyRunChallenge`**

Insert immediately before `export async function verifyRunChallenge(` in `engine.ts`:

```typescript
export interface ChallengeStart {
  rule: ChallengeRule;
  start: DailyStart;
  startingFill: number;
  movesOverride: number;
  minChainLength: number;
  multiplierFn: (n: number) => number;
}

/**
 * Resolve the per-rule generation overrides for today's Challenge board and
 * seed the starting board. Single source for how the daily challenge board is
 * built, so the board-parity digest and verifyRunChallenge cannot diverge on
 * it. Mirrors the challenge branch of Dart `GameCubit.init`.
 */
export async function seedChallengeStart(
  date: string,
): Promise<ChallengeStart> {
  const rule = await challengeRule(date);
  const startingFill = rule === "denseStart"
    ? kChallengeDenseFill
    : rule === "sparseStart"
    ? kChallengeSparseFill
    : rule === "longChainsOnly"
    ? kChallengeDenseFill
    : STARTING_FILL["challenge"];
  const wallCountOverride = rule === "wallMaze" ? kChallengeWallMazeCount : 0;
  const movesOverride = rule === "budgetCut" ? kChallengeMoves : kMovesPerDay;
  const multiplierFn = rule === "comboRush"
    ? comboRushMultiplier
    : comboMultiplier;
  const minChainLength = minChainLengthFor(rule);
  const seeder = new DailySeeder(date, "challenge");
  const start = await seeder.generate({
    startingFillOverride: startingFill,
    wallCountOverride,
    movesOverride,
    minChainLength,
  });
  return { rule, start, startingFill, movesOverride, minChainLength, multiplierFn };
}
```

- [ ] **Step 4: Refactor `verifyRunChallenge` to use it**

Replace the head of `verifyRunChallenge` — from `if (!Array.isArray(log)) return REJECT;` down through `let board = start.board;` (currently `:352-380`) — with:

```typescript
  if (!Array.isArray(log)) return REJECT;

  const { start, startingFill, minChainLength, multiplierFn } =
    await seedChallengeStart(date);

  const seeder = new DailySeeder(date, "challenge");
  const dropPrng = await seeder.dropTierPrng();
  const landing = await seeder.landingPrng();

  let board = start.board;
```

Leave the replay loop and `return { valid: true, ... }` below it unchanged. (`movesOverride` and `rule` are consumed inside `seedChallengeStart` for generation only, so they are intentionally not destructured here.)

- [ ] **Step 5: Run the full Deno suite**

Run: `deno test supabase/functions/`
Expected: PASS. The challenge golden vectors (`golden_vectors.test.ts`) prove `verifyRunChallenge` behaves identically through the extracted helper.

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/_shared/engine.ts
git commit -m "refactor(engine-ts): extract seedChallengeStart from verifyRunChallenge

Single source for the per-rule challenge generation overrides so the
board-parity digest (next commit) and verifyRunChallenge build the same
daily challenge board. Behavior-preserving; guarded by challenge golden
vectors."
```

---

### Task 3: Dart board-parity generator + fixture

**Files:**
- Create: `test/domain/engine/board_vectors_test.dart`
- Create: `supabase/functions/_shared/board_vectors.json` (generated in Step 3)

**Interfaces:**
- Consumes: `DailySeeder(date, difficulty)` → `.generate().board`, `.dropTierPrng()`, `.dropTierAt(p, n)`, `.challengeRule`; `GameCubit(storage:, todayProvider:)` → `.init(difficulty:)` → `(state as GamePlaying).board`; `kMaxDrops`; `ChallengeRuleMinChainLength.minChainLength`; `sha256`.
- Produces: `supabase/functions/_shared/board_vectors.json` with shape `{ "_readme", "epoch": "2026-07-14", "days": 365, "entries": [ { "date", "difficulty", "digest" } ] }`. **Task 4 reads this file.**

> **ponytail:** the assert path re-drives `GameCubit.init` for all 365 challenge entries on every `flutter test` run (standard uses the cheap `generate()`). Expected to add a few seconds. If it ever dominates CI, cache the challenge board or thin the challenge date set — do not reintroduce a Dart copy of the override table (that copy is exactly what Option 2 avoids).

- [ ] **Step 1: Write the generator/asserter test**

Create `test/domain/engine/board_vectors_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:connect_merge/application/game_cubit.dart';
import 'package:connect_merge/application/game_state.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/engine/daily_seeder.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/challenge_rule.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/tile.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixturePath = 'supabase/functions/_shared/board_vectors.json';
const _epoch = '2026-07-14';
const _days = 365;
const _difficulties = <Difficulty>[
  Difficulty.easy,
  Difficulty.medium,
  Difficulty.hard,
  Difficulty.legendary,
  Difficulty.challenge,
];

void main() {
  test('Dart board generation matches the committed board-parity digests',
      () async {
    if (Platform.environment['UPDATE_GOLDENS'] == '1') {
      await _generateFixture();
    }

    final fixture =
        jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;
    expect(fixture['epoch'], _epoch);
    expect(fixture['days'], _days);

    final entries = (fixture['entries'] as List<dynamic>)
        .map((e) => Map<String, dynamic>.from(e as Map<String, dynamic>))
        .toList();
    expect(entries.length, _days * _difficulties.length);

    for (final entry in entries) {
      final date = entry['date'] as String;
      final difficulty =
          Difficulty.values.byName(entry['difficulty'] as String);
      final digest = await _digestFor(date, difficulty);
      expect(digest, entry['digest'],
          reason: 'board digest drift at $date ${difficulty.name}');
    }
  });
}

String _dateAtOffset(int offset) {
  final d = DateTime.utc(2026, 7, 14).add(Duration(days: offset));
  final mm = d.month.toString().padLeft(2, '0');
  final dd = d.day.toString().padLeft(2, '0');
  return '${d.year}-$mm-$dd';
}

Future<String> _digestFor(String date, Difficulty difficulty) async {
  final seeder = DailySeeder(date, difficulty);
  final BoardState board;
  final String rule;
  final int mcl;
  if (difficulty == Difficulty.challenge) {
    final cubit = GameCubit(
      storage: InMemoryStorageService(),
      todayProvider: () => date,
    );
    await cubit.init(difficulty: Difficulty.challenge);
    board = (cubit.state as GamePlaying).board;
    rule = seeder.challengeRule.name;
    mcl = seeder.challengeRule.minChainLength;
  } else {
    board = seeder.generate().board;
    rule = '-';
    mcl = 2;
  }
  return _digest(_canonical(board, _dropSchedule(seeder), rule, mcl));
}

List<int> _dropSchedule(DailySeeder seeder) {
  final p = seeder.dropTierPrng();
  return [for (var n = 0; n < kMaxDrops; n++) seeder.dropTierAt(p, n)];
}

String _canonical(BoardState board, List<int> drops, String rule, int mcl) {
  final cells = [
    for (final Tile? t in board.cells) t == null ? 'x' : '${t.tier}',
  ].join(',');
  final walls = (board.walls.toList()..sort()).join(',');
  return 'g=${board.gridSize};m=${board.movesRemaining};cells=$cells;'
      'walls=$walls;drops=${drops.join(',')};rule=$rule;mcl=$mcl';
}

String _digest(String canonical) =>
    sha256.convert(utf8.encode(canonical)).toString();

Future<void> _generateFixture() async {
  final entries = <Map<String, dynamic>>[];
  for (var offset = 0; offset < _days; offset++) {
    final date = _dateAtOffset(offset);
    for (final difficulty in _difficulties) {
      entries.add(<String, dynamic>{
        'date': date,
        'difficulty': difficulty.name,
        'digest': await _digestFor(date, difficulty),
      });
    }
  }
  final fixture = <String, dynamic>{
    '_readme':
        'Board-generation parity digests (Dart<->TS). Regenerate with '
            'UPDATE_GOLDENS=1 alongside any change to DailySeeder generation or '
            'challenge overrides. No season: board digests never touch the '
            'leaderboard.',
    'epoch': _epoch,
    'days': _days,
    'entries': entries,
  };
  File(_fixturePath).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(fixture)}\n');
}
```

- [ ] **Step 2: Run the test to verify it fails (no fixture yet)**

Run: `flutter test test/domain/engine/board_vectors_test.dart`
Expected: FAIL — `board_vectors.json` does not exist, so `File(...).readAsStringSync()` throws `FileSystemException`.

- [ ] **Step 3: Generate the fixture**

Run: `$env:UPDATE_GOLDENS='1'; flutter test test/domain/engine/board_vectors_test.dart`
Expected: PASS. Writes `supabase/functions/_shared/board_vectors.json` with 1,825 entries, then asserts each recomputed digest equals what was just written.

- [ ] **Step 4: Run without the flag to confirm the committed fixture asserts clean**

Run: `flutter test test/domain/engine/board_vectors_test.dart`
Expected: PASS (recompute == committed).

- [ ] **Step 5: Commit the test and the fixture**

```bash
git add test/domain/engine/board_vectors_test.dart supabase/functions/_shared/board_vectors.json
git commit -m "test(board-parity): dense Dart board-generation digests

Commits board_vectors.json: one SHA-256 digest of the generated board
(cells, walls, drop schedule, geometry, rule) for 365 days x 5
difficulties. Dart authors and asserts; regen via UPDATE_GOLDENS=1."
```

---

### Task 4: Deno board-parity asserter

**Files:**
- Create: `supabase/functions/_shared/board_vectors.test.ts`

**Interfaces:**
- Consumes: `board_vectors.json` (Task 3); `seedChallengeStart` (Task 2); `DailySeeder`, `challengeRule` (`seeder.ts`); `kMaxDrops`, `minChainLengthFor`, `type BoardState`, `type ChallengeRule`, `type Difficulty` (`constants.ts`).
- Produces: a Deno test asserting the TS engine reproduces every committed digest. No exports.

This is a regression/parity guard, not red-green: parity already holds after Tasks 1–3, so Step 2 is expected to **PASS on first run**. A **FAIL means genuine live Dart↔TS drift** — stop and reconcile the engines, do not edit the fixture.

- [ ] **Step 1: Write the asserter**

Create `supabase/functions/_shared/board_vectors.test.ts`:

```typescript
import { assertEquals } from "jsr:@std/assert@1";
import {
  type BoardState,
  type ChallengeRule,
  type Difficulty,
  kMaxDrops,
  minChainLengthFor,
} from "./constants.ts";
import { challengeRule, DailySeeder } from "./seeder.ts";
import { seedChallengeStart } from "./engine.ts";
import fixture from "./board_vectors.json" with { type: "json" };

interface Entry {
  date: string;
  difficulty: string;
  digest: string;
}

const entries = fixture.entries as Entry[];

async function dropSchedule(seeder: DailySeeder): Promise<number[]> {
  const p = await seeder.dropTierPrng();
  const out: number[] = [];
  for (let n = 0; n < kMaxDrops; n++) out.push(seeder.dropTierAt(p, n));
  return out;
}

function canonical(
  board: BoardState,
  drops: number[],
  rule: string,
  mcl: number,
): string {
  const cells = board.cells
    .map((t) => (t === null ? "x" : `${t.tier}`))
    .join(",");
  const walls = [...board.walls].sort((a, b) => a - b).join(",");
  return `g=${board.gridSize};m=${board.movesRemaining};cells=${cells};` +
    `walls=${walls};drops=${drops.join(",")};rule=${rule};mcl=${mcl}`;
}

async function digest(canonicalStr: string): Promise<string> {
  const bytes = new TextEncoder().encode(canonicalStr);
  const buf = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(buf)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function digestFor(date: string, difficulty: string): Promise<string> {
  const seeder = new DailySeeder(date, difficulty as Difficulty);
  let board: BoardState;
  let rule: string;
  let mcl: number;
  if (difficulty === "challenge") {
    const seed = await seedChallengeStart(date);
    board = seed.start.board;
    const r: ChallengeRule = await challengeRule(date);
    rule = r;
    mcl = minChainLengthFor(r);
  } else {
    board = (await seeder.generate()).board;
    rule = "-";
    mcl = 2;
  }
  return await digest(canonical(board, await dropSchedule(seeder), rule, mcl));
}

Deno.test("board_vectors: TS board generation matches the committed digests", async () => {
  assertEquals(entries.length, (fixture.days as number) * 5);
  for (const entry of entries) {
    const actual = await digestFor(entry.date, entry.difficulty);
    assertEquals(
      actual,
      entry.digest,
      `board digest drift at ${entry.date} ${entry.difficulty}`,
    );
  }
});
```

- [ ] **Step 2: Run the asserter**

Run: `deno test supabase/functions/_shared/board_vectors.test.ts`
Expected: PASS — the TS engine reproduces all 1,825 digests. If it FAILS, the message names the exact `(date, difficulty)` that drifted; reconcile the Dart/TS engines (do not touch the fixture).

- [ ] **Step 3: Run the full Deno suite as CI will (`--frozen`)**

Run: `deno test --frozen supabase/functions/`
Expected: PASS (new asserter included alongside the golden vectors).

- [ ] **Step 4: Commit**

```bash
git add supabase/functions/_shared/board_vectors.test.ts
git commit -m "test(board-parity): Deno asserts TS reproduces the board digests

Recomputes each board_vectors.json digest with the TS engine and asserts
equality. Board-generation drift now fails CI on the exact date/difficulty
it is introduced, instead of slipping past ~12 sampled full-run vectors."
```

---

## Self-Review

**1. Spec coverage:**
- Decision 1 (generation-surface digest) → Tasks 3–4 canonical (cells, walls, drops, geometry, rule, mcl). ✓
- Decision 2 (committed fixture) → Task 3 writes, Tasks 3+4 assert. ✓
- Decision 3 (digest per entry) → `_digest`/`digest` SHA-256. ✓
- Decision 4 (365 × 5) → `_days=365`, `_difficulties` len 5, `entries.length` assertions. ✓
- Decision 5 (scan dedup) → Task 1. ✓
- Decision 6 (separate files) → `board_vectors.json` / `board_vectors_test.dart` / `board_vectors.test.ts`. ✓
- Decision 7 (reuse `UPDATE_GOLDENS`, no season) → Task 3 Step 3; no `season` key in fixture. ✓
- Decision 8 (real challenge path) → Task 2 `seedChallengeStart` (TS) + Task 3 cubit-drive (Dart); standard via `generate()` both sides. ✓

**2. Placeholder scan:** No TBD/TODO/"add error handling"/"similar to Task N". Every code step is complete and copy-paste ready. ✓

**3. Type consistency:**
- `seedChallengeStart` defined (Task 2) with `.start.board` → consumed identically (Task 4). ✓
- Canonical string identical in Dart `_canonical` and TS `canonical` (field order, `x` for null, sorted walls, 39 drops, `rule`, `mcl`). ✓
- Fixture keys `epoch`/`days`/`entries[].{date,difficulty,digest}` written (Task 3) == read (Tasks 3, 4). ✓
- Digest is lowercase hex both sides (`sha256.convert(...).toString()` == `b.toString(16).padStart(2,"0")`). ✓
- `rule` value: Dart `challengeRule.name` (e.g. `"wallMaze"`) == TS `ChallengeRule` union string. ✓
