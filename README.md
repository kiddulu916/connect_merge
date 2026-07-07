# Connect Merge

A deterministic daily spatial merge puzzle, built with Flutter. Every player on
Earth gets the **same board** on the same UTC day — so scores are honestly
comparable, no run can be re-rolled for a better seed, and the whole game can
run for $0 (no authoritative server needed for gameplay itself).

## Gameplay

**Connect-Merge:** drag a chain of two or more orthogonally-adjacent tiles of
the same tier to collapse them onto the last tile in the chain, which levels
up one tier (`2 → 4 → 8 → … → 2048`). Longer chains score a superlinear combo
bonus instead of just the sum of pairwise merges, so hunting for long chains
beats greedily merging pairs.

- **Moves:** 30 per day. Every collapse costs one move and immediately backfills
  the board with a new tile, so the board never runs dry mid-turn.
- **Scoring:** a `2^tier` merge of `n` tiles scores `2^tier × comboMultiplier(n)`,
  where `comboMultiplier(2) == 1` (identical to a plain pairwise merge) and grows
  quadratically with chain length.
- **End of day:** the run ends when moves run out or the board **deadlocks**
  (no two adjacent tiles share a tier). Walls (seed-placed blocked cells) can
  force a deadlock even with moves left.
- **Cap:** tier 11 (2048) is the ceiling — two maxed tiles can no longer fuse.

### Difficulty tiers

| Tier | Grid | Starting fill |
|---|---|---|
| Easy | 8×8 | 40 tiles |
| Medium | 7×7 | 25 tiles |
| Hard | 6×6 | 20 tiles |
| Legendary | 6×6 | 15 tiles |
| Challenge | 6×6 | 8 tiles + a daily special rule |

**Challenge mode** rolls one of six modifiers each day from the same seed
(`Budget Cut`, `Long Chains Only`, `Dense Start`, `Sparse Start`, `Wall Maze`,
`Combo Rush`), so it's a different puzzle shape every day, not just a smaller
grid.

### Determinism, by design

The day's board, drop schedule, walls, golden tiles, loot reward, and even the
Challenge rule are all derived from `SHA-256("$date:$difficulty")` (and
sub-keyed streams off of it). That means:

- The same date + tier produces a byte-identical board for every player.
- A finished run can be **replayed and verified** from its move log alone —
  nothing about fairness relies on trusting the client.
- Daily/weekly/monthly leaderboards, duels, and loot are all cheat-resistant
  without needing server-authoritative gameplay.

## Beyond the daily board

- **Duels** — challenge a friend to beat your score on today's board via a
  deep link (`connectmerge://duel/...`). The link carries the challenge
  entirely client-side; only the verified leaderboard is authoritative, so a
  hand-edited link can't forge a ranking.
- **Rivalries** — pick a persistent rival and track your head-to-head history.
- **Friends & invites** — add friends via invite codes / deep links (Supabase-
  backed) and compare progress.
- **Leaderboards** — daily, weekly, and monthly boards per difficulty tier,
  with weekly/monthly prize payouts.
- **Streaks** — a daily-active streak plus a per-tier streak, with a freeze
  token that bridges one missed day.
- **Achievements** — badges like *Legend* (2048 on Legendary), *Week Warrior*
  / *Unstoppable* (streaks), *Top 10*, *Tier Master*, and *High Roller*.
- **Merge Almanac** — a collection log tracking how many times you've reached
  each tier, with a mastery badge per tier.
- **Player level / XP** — a flair progression layer derived from lifetime
  score; purely cosmetic, never touches scoring.
- **Cosmetics** — unlockable tile-color themes (streak-gated, achievement-
  gated, ad-unlocked, or coin-purchased).
- **Daily Loot Chest** — a seeded, free daily coin reward (common/uncommon/
  jackpot bands) with a rare chance at a cosmetic shard.
- **Golden tiles** — a small seeded fraction of each day's drops are golden;
  merging one credits bonus coins (visual/economy only, never affects score).
- **Daily objective** — a seeded bonus goal (land an N-chain, or reach a given
  tier) for extra coins.
- **Near-miss messaging & Wordle-style share card** — a finished run can
  surface an honest "so close" line and export an emoji grid summary to share.
- **Undo & hints** — a small number of free undos and drop-reveal hints per
  day, with rewarded-video top-ups; these only affect local convenience, never
  the seed-fixed drop schedule.
- **Rewarded-ad continues** — extra moves via rewarded video, capped per day.

## Tech stack

- **Flutter** (Dart ≥3.4) with **flutter_bloc/Cubit** for state management.
- **Hive** for local persistence (profiles, snapshots, history).
- **Supabase** (Postgres + Edge Functions) for auth, leaderboards, and friend
  matching — the app degrades gracefully to fully offline play if Supabase
  isn't configured or reachable.
- **google_mobile_ads** for rewarded video (moves, hints, undos, cosmetics).
- **flutter_local_notifications** for local-only daily reminders (no FCM, $0).
- **app_links** for deep-link invites and duels.

### Architecture

```
lib/
  domain/         # Pure game rules & models — no Flutter, no I/O
    engine/       # GameEngine, DailySeeder, DailyLoot, NearMiss, ShareGridBuilder, Prng
    models/       # BoardState, Tile, Difficulty, Achievement, Cosmetic, ...
  application/    # Cubits orchestrating domain + infrastructure (GameCubit, DuelCubit, ...)
  infrastructure/ # Hive storage, Supabase client, ads, auth, notifications, deep links
  presentation/   # Screens & widgets
supabase/
  functions/      # Edge functions (submit-score, match-contacts)
  migrations/     # Postgres schema
test/             # Mirrors lib/ — 50+ test files, heavy on domain/engine determinism
```

The domain layer is intentionally pure (`GameEngine` returns new `BoardState`s,
never mutates) so every rule is unit-testable and replay-safe.

## Getting started

```bash
flutter pub get
flutter run
```

Run the test suite:

```bash
flutter test
```

Supabase features (auth, leaderboards, friends) require `--dart-define`
credentials at build/run time:

```bash
flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
```

Without them the app runs fully offline with local-only daily play, streaks,
and cosmetics.
