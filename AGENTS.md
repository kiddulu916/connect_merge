# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## What this is

Connect Merge: a deterministic daily spatial merge puzzle (Flutter client + Supabase backend). Every player gets the same board on the same UTC day, derived from `SHA-256("$date:$difficulty")`. Nothing about fairness relies on trusting the client — a finished run is a move log that the server independently replays to compute the authoritative score. See `README.md` for full gameplay rules (Connect-Merge chains, scoring, difficulty tiers, streaks, duels, etc.).

## Commands

```powershell
flutter pub get                              # install deps
flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
                                              # run the app (offline-capable without the dart-defines)
flutter test                                 # run the full Dart test suite
flutter test test/domain/engine/game_engine_test.dart   # run a single test file
flutter test --plain-name "canMerge"         # run tests matching a name
flutter test test/domain/engine/golden_vectors_test.dart # assert golden vectors
$env:UPDATE_GOLDENS='1'; flutter test test/domain/engine/golden_vectors_test.dart
$env:UPDATE_GOLDENS='1'; $env:UPDATE_GOLDENS_FORCE='1'; flutter test test/domain/engine/golden_vectors_test.dart

deno test supabase/functions/_shared/engine.test.ts      # run the TS replay-validator tests
deno test --frozen supabase/functions/        # run all Edge Function tests
deno test supabase/functions/match-contacts/sanitize.test.ts
```

`flutter analyze` follows `analysis_options.yaml` (`flutter_lints` + `strict-casts`/`strict-raw-types`, `prefer_const_constructors`, `prefer_final_locals`, `avoid_print`).

## Architecture

```
lib/
  domain/         # Pure game rules & models — no Flutter, no I/O, no mutation
    engine/       # GameEngine, DailySeeder, DailyLoot, NearMiss, ShareGridBuilder, Prng
    models/       # BoardState, Tile, Difficulty, Achievement, Cosmetic, ...
  application/    # Cubits (flutter_bloc) orchestrating domain + infrastructure
  infrastructure/ # Hive storage, Supabase client, ads, auth, notifications, deep links
  presentation/   # Screens & widgets
supabase/
  functions/
    _shared/      # engine.ts, constants.ts, seeder.ts, prng.ts — hand-maintained TS port of lib/domain
    submit-score/ # Edge Function: auth -> parse -> replay-verify -> upsert best score -> rank
    match-contacts/
  migrations/     # Postgres schema
test/             # Mirrors lib/ — heavy on domain/engine determinism and replay tests
```

### The dual-engine invariant (read this before touching game rules)

`lib/domain/engine/game_engine.dart` (and `lib/domain/constants.dart`) is the single source of truth for game rules on the client. `supabase/functions/_shared/engine.ts` and `constants.ts` are a **hand-maintained TypeScript port with no shared source** — there is no codegen link between them. The `submit-score` Edge Function only trusts a client's move log after replaying it through the TS engine (`verifyRun`/`verifyRunChallenge` in `engine.ts`); if the TS port doesn't recognize a move as legal, the server rejects an otherwise-legitimate run.

**Any change to merge validity, scoring, deadlock detection, or seeded generation in the Dart engine must be mirrored byte-for-byte into the TS engine**, including doc comments that state the parity requirement. `supabase/functions/_shared/engine.test.ts` pins this with test vectors captured directly from Dart runs — if Dart and TS ever drift, real client scores start failing server verification.

The tier-step predicate is single-sourced as `GameEngine.canFollow` in Dart and `canFollow`/`pairMergeable` in TypeScript `constants.ts`; all chain, pair, widget, and seeder checks route through it. Post-chain refill is single-sourced as `GameEngine.refill` in Dart and exported `refillBoard` in TypeScript `engine.ts`; both verifier modes use the latter. These are lockstep surfaces even though Dart alone carries the cosmetic `goldenDrops` flag.

The committed `supabase/functions/_shared/golden_vectors.json` fixture records real `GameCubit` runs and is asserted by both Flutter and Deno at this seam.

Whenever gameplay-rule changes ship, `kLeaderboardSeason` (in both `lib/domain/constants.dart` and `supabase/functions/_shared/constants.ts`) is bumped in lockstep so old and new scoring never mix on a leaderboard — no DB migration needed, since `season` is already a parameter on the `scores` table and all leaderboard RPCs.

### Determinism model

The domain layer is intentionally pure: `GameEngine` methods return new `BoardState`s and never mutate. Board contents, drop schedule, walls, golden tiles, loot, and the daily Challenge-mode rule are all derived from the daily seed (`DailySeeder`, keyed off `"$date:$difficulty"`) via a seeded PRNG (`Prng`). This is what makes a run replayable/verifiable from its move log alone, and it's why `lib/domain/engine` and its TS mirror have to stay exactly in sync (see above) — any nondeterminism or drift breaks replay verification for every player, not just the one who hit it.

Cosmetic/economy systems (golden tile coin bonus, XP/level, almanac, daily objective coin reward) are explicitly walled off from `BoardState.score` and the move log — see the comments in `lib/domain/constants.dart` — so they never need to be ported to the TS side.

### Planning workflow

Nontrivial features in this repo go through the `superpowers` plan/spec skills: a design doc under `docs/superpowers/specs/` and a task-by-task implementation plan under `docs/superpowers/plans/` (each task = failing test → implementation → passing test → commit). Check `docs/superpowers/plans/` for the most recent plan before starting related work — it documents the exact rule/invariant set currently in force (e.g. the ascend-chain merge rule, its scoring formula, and every file its Dart-to-TS mirror touched).
