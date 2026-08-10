# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

Nontrivial features in this repo go through the `grill-me-codex` skill first — Act 1 grills the request into a locked plan with the user, Act 2 runs adversarial Codex review rounds against it — then get implemented task-by-task (each task = failing test → implementation → passing test → commit). The locked/reviewed plan lives at the repo root as `PLAN.md`, with the Codex review-round history in `PLAN-REVIEW-LOG.md`, replacing that plan's predecessor once a new one starts. Check `PLAN.md` before starting related work — it documents the exact rule/invariant set currently locked in for the next phase.

### Database changes: remote only, Supabase CLI only

This project has no local Postgres/Docker workflow. **Never** run `supabase start`, `supabase db reset`, `supabase test db`, or anything else that spins up a local database container — there is no local stack to fall back to, and none should be created. All schema changes and migrations are written as files under `supabase/migrations/` and applied to the real hosted Supabase project (`nnoqqchqprfikhabrrjt`) via the Supabase CLI (`supabase db push --linked`, `supabase migration list --linked`, `supabase db query --linked --file <path>`), not the MCP tools, and not a fabricated local environment. Pushing to `origin/main` may itself auto-apply pending migrations to the live database via Supabase's GitHub integration — treat every `git push` of a commit that touches `supabase/migrations/` as a live production migration, not just a code push. Verify a migration's real effect with read-only queries (`mcp__supabase__execute_sql` or `supabase db query --linked`) against the actual hosted project, never against a local substitute.

### This repo is the app + its backend only — the marketing site is elsewhere

`supabase/functions/*.ts` are Deno **Edge Functions** (serverless backend code — auth, replay-verification, RPCs), not a website; nothing in this repo renders `connectmerge.app`. The actual marketing/deep-link site (`connectmerge.app`) is a separate, plain HTML/CSS/vanilla-JS static site with its own `CLAUDE.md`, at `C:\Users\dat1k\Projects\connectmerge-site`, deployed on Vercel (auto-deploys on push to its own `main`). If a task is actually about that website (landing page, deep-link handling, `.well-known` files, legal pages), work in that repo instead of this one. For anything at the Vercel deployment/project-configuration level (domains, env vars, deployment protection, build logs, analytics) for either project, use the Vercel MCP tools (`mcp__claude_ai_Vercel__*`) rather than guessing through the dashboard.
