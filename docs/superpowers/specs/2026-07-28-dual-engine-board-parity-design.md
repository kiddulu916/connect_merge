# Dual-Engine Board-Parity — Design

**Date:** 2026-07-28
**Status:** Approved (grilled 2026-07-26/28)
**Source:** Architecture review candidate #1 — "Make dual-engine parity structural, not sampled."

## Problem

`lib/domain/engine` (Dart) is the source of truth for game rules; `supabase/functions/_shared` (TS) is a hand-maintained port with no codegen link. The `submit-score` Edge Function replays a client's move log through the TS engine, so **any Dart↔TS drift in board generation rejects every legitimate run for the affected day.**

Board-generation parity is currently guarded only by `golden_vectors.json` — ~12 hand-picked full-run dates. On **2026-07-17** a seeder re-roll predicate drifted (an inlined copy still required equal-tier pairs after the ascend rule shipped); the sampled fixture did not distinguish it, and **every challenge (wallMaze) run that day was server-rejected.** It was found by luck (re-running the generator against new dates), then patched with a reactive `ascend-only-initial-board` coverage requirement.

Two structural weaknesses:
1. **Sampled, not dense.** Board generation is verified at ~1 date/difficulty; the drift class hides on dates the samples don't cover.
2. **Duplicated scan.** The adjacency deadlock scan is written twice inside TS (`engine.ts` `hasMergeAvailable` + `constants.ts` `hasAnyMergeablePair`) — the same multiplicity that let the now-removed 4th (seeder) copy drift.

## Goal

Make board-generation parity a **dense, structural check** independent of full-run replay, and remove the duplicated scan that is the drift's structural cause. Scoring parity stays with the existing golden vectors.

## Decisions (grilled)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Scope | Generation surface only: initial board (cells+walls), `':drops'` schedule, geometry, challenge rule + `minChainLength`. Not scoring. |
| 2 | Mechanism | Committed fixture (Dart authors, both sides assert) — same handoff as golden vectors. |
| 3 | Content | One SHA-256 **digest** per `(date, difficulty)`. Tiny, diff-friendly, names the drifted entry. |
| 4 | Coverage | 365 contiguous days from epoch `2026-07-14` × {easy, medium, hard, legendary, challenge} = **1,825 entries**. |
| 5 | Scan dedup | **Bundled.** `constants.ts` `hasAnyMergeablePair` is the sole TS scan; `engine.ts` `hasMergeAvailable` delegates. |
| 6 | File layout | Separate `board_vectors.json` + `board_vectors_test.dart` + `board_vectors.test.ts`. |
| 7 | Regen guard | Reuse `UPDATE_GOLDENS=1`; **no `season` field** — board digests never touch the leaderboard; assert-against-committed is the guard. |
| 8 | Challenge board | Reuse the real generation path: Dart reads the board from `GameCubit.init`; TS extracts `seedChallengeStart(date)` from `verifyRunChallenge` (small deepening) and the digest calls it. Standard uses `DailySeeder.generate()` directly on both sides (verified: `verifyRun` starts from a plain `generate().board`). |

## Canonical digest

For each `(date, difficulty)`, build a byte-identical canonical string on both sides, then SHA-256 (lowercase hex):

```
g=<gridSize>;m=<movesRemaining>;cells=<c0>,...,<cN-1>;walls=<w0>,...;drops=<d0>,...,<d38>;rule=<name|->;mcl=<minChainLength>
```

- `cells[i]` = the tile's `tier`, or `x` if the cell is null/empty.
- `walls` = wall indices sorted ascending, comma-joined (empty string if none).
- `drops` = `dropTierAt(dropTierPrng(), n)` for `n` in `0..kMaxDrops-1` (39 values) — the replay-relevant `':drops'` stream, **not** the vestigial Dart-only stream-A `dropTiers` list.
- `rule` = `challengeRule.name` for challenge, `-` for standard. `mcl` = `2` for standard, `minChainLengthFor(rule)` for challenge.

**Board source per side:**
- Standard (both sides): `DailySeeder(date, difficulty).generate().board`.
- Challenge Dart: `GameCubit.init(difficulty: challenge)` → `(state as GamePlaying).board`.
- Challenge TS: `(await seedChallengeStart(date)).start.board`.
- Drops (both, all difficulties): computed directly from `DailySeeder(...).dropTierPrng()` + `dropTierAt`.

A drifting canonical/hash only ever fails **loud** (never silent), so it is safe: a false failure points at the serializer; there is no false pass that hides a real board difference, because every gameplay-determining field is in the string.

## Guard semantics

- **Dart test** (`board_vectors_test.dart`): under `UPDATE_GOLDENS=1` regenerates and writes `board_vectors.json`; always then recomputes each digest and asserts it equals the committed value → catches a stale fixture (Dart seeder changed, forgot to regen).
- **Deno test** (`board_vectors.test.ts`): reads the committed fixture, recomputes each digest with the TS engine, asserts equality → catches TS-vs-Dart drift (the primary goal). Runs under existing `deno test --frozen supabase/functions/`.

After this change, the 2026-07-17 incident would have failed CI on the exact `(date, difficulty)` the day the drift was introduced.

## Fixture shape

```json
{
  "_readme": "Board-generation parity digests (Dart<->TS). Regenerate with UPDATE_GOLDENS=1 alongside any change to DailySeeder generation or challenge overrides. No season: board digests never touch the leaderboard.",
  "epoch": "2026-07-14",
  "days": 365,
  "entries": [
    { "date": "2026-07-14", "difficulty": "easy", "digest": "<64 hex>" }
  ]
}
```

## Out of scope

- Scoring / full-run replay (owned by `golden_vectors.json`).
- The vestigial stream-A `dropTiers` list in Dart `DailyStart` (unused; TS already omits it).
- Codegen of `constants.ts`/predicate tables from Dart (larger lift; deferred).
- The broader `verifyRun`/`verifyRunChallenge` orchestration dedup (Explore candidate #5) — only the minimal `seedChallengeStart` extraction is in scope.

## Files

- Create: `supabase/functions/_shared/board_vectors.json`
- Create: `test/domain/engine/board_vectors_test.dart`
- Create: `supabase/functions/_shared/board_vectors.test.ts`
- Modify: `supabase/functions/_shared/engine.ts` (dedup `hasMergeAvailable`; add `seedChallengeStart`; refactor `verifyRunChallenge`)
