# Competitive Daily Expansion Contract

**Created**: 2026-06-07
**Confidence Score**: 95/100
**Status**: Approved
**Supersedes**: None
**Approved Scope Tier**: Stretch (MVP + Full + Stretch)

## Problem Statement

merge_loop is a polished but solitary single-player daily puzzle: every player gets one deterministic board per day (seeded from a SHA256 of the date) and plays it alone. There is no reason to return beyond a personal best, no social pull, and no way to compare your run against anyone else's — leaving engagement, reach, and daily session count on the table.

Separately, the AdMob configuration is nearly correct but has a release-blocking defect: the real ad unit IDs are wired up and `useTestAds` is `false`, yet the iOS `GADApplicationIdentifier` in `Info.plist` still holds Google's TEST App ID. On iOS this mismatch (real unit IDs + test App ID) prevents ads from serving and can get the app flagged.

The goal is to convert the solo daily puzzle into a competitive, social, habit-forming daily game — difficulty tiers, global and friends leaderboards, identity, and retention mechanics — while keeping infrastructure cost at $0 (Supabase free tier) and shipping a cheat-resistant leaderboard from day one.

## Goals

1. Fix the iOS AdMob App ID so ads serve correctly on both platforms (unit IDs already correct).
2. Add 4 difficulty tiers (easy=10, medium=8, hard=6, legendary=4 starting tiles; 30 moves all tiers), each a separate deterministic daily board playable once per tier per day.
3. Seed boards and leaderboards by UTC date so "everyone plays the same board today" holds globally.
4. Ship a global per-tier daily leaderboard with **server-side replay-verified** scores (cheating effectively impossible).
5. Give every player a zero-friction identity (Supabase anonymous auth + display name), a friends/local leaderboard (friend codes + contacts + outbound share), and retention mechanics (streaks + notifications, achievements, extended leaderboards, practice mode + extra ad spots + cosmetics) — all on the Supabase free tier ($0).

## Success Criteria

- [ ] On a real iOS build, real ads serve and `Info.plist` `GADApplicationIdentifier` is the real App ID (not `...3940256099942544`).
- [ ] Selecting each of the 4 tiers loads a distinct, deterministic board; the same tier on the same UTC date yields an identical board for every player; tile counts are 10/8/6/4.
- [ ] A player can complete each tier exactly once per UTC day; a second attempt that day is blocked.
- [ ] Submitting a completed run posts the move sequence; the Supabase edge function replays it against the regenerated `(date,tier)` board and writes a score matching the client's local score for legitimate runs.
- [ ] A fabricated or illegal move sequence is rejected by the edge function and never reaches the leaderboard.
- [ ] The global daily leaderboard for a given tier shows ranked display names + scores and resets at 00:00 UTC.
- [ ] A player can generate a friend code/link, a second device can redeem it, and both appear on each other's friends leaderboard.
- [ ] Contacts matching (with permission) surfaces opted-in test contacts; denying permission degrades gracefully.
- [ ] A local notification fires at the configured daily time and when a streak is about to expire.
- [ ] Daily streak increments on consecutive-day completion and resets after a missed UTC day; achievements unlock on their trigger conditions.
- [ ] Cross-language test: the TypeScript PRNG and seeder produce byte-identical output to the Dart implementations for a battery of seeds.
- [ ] `flutter analyze` is clean and `flutter test` passes, including new engine/seeder/tier tests.

## Scope Boundaries

### In Scope

**MVP** (Phases 1–2)
- Fix iOS AdMob App ID in `Info.plist`.
- UTC-date seeding (replace local-date) with a local countdown to reset.
- 4 difficulty tiers via per-tier starting fill (10/8/6/4); 30 moves all tiers.
- Per-`(date,tier)` seeding, snapshots, and stats; once-per-tier-per-day rule.
- Record the move sequence per run (input for replay verification).
- Supabase project + schema + RLS (players, scores).
- Anonymous auth + display name (optional avatar/emoji).
- Server-side replay verification (Dart engine/PRNG/seeder ported to a TS edge function).
- Global per-tier daily leaderboard UI.

**Full** (Phase 3 + Phase 4 core)
- Friend codes + invite (deep) links; contacts matching (hashed); outbound share cards; friends leaderboard UI.
- Streak surfacing + milestones + rewarded-ad streak freeze; local daily/streak-expiry notifications.
- Achievements/badges; extended (weekly/monthly/all-time) leaderboards.

**Stretch** (Phase 4 — approved, in scope)
- Practice/unlimited off-leaderboard mode.
- Extra rewarded-ad placements (hint / reveal-next-drop).
- Cosmetic tile themes.

### Out of Scope

- Facebook friends import (`user_friends` OAuth) — requires Meta App Review and only returns mutual app users.
- Instagram / X friend-graph import — no supported friend-graph API on Instagram; X follower endpoints are paid-only. Replaced by outbound sharing.
- Replay / spectate top runs — cut from this round (near-free later given recorded moves).
- Real-time multiplayer — this is async daily competition by design.
- Paid Supabase tier / managed push (FCM) — stay at $0 until growth justifies it.
- Email/password accounts and cross-device recovery — anonymous-first.

### Future Considerations

- Replay & spectate the day's top runs (architecture already records move sequences).
- Facebook login + friends import once an audience justifies Meta review.
- Account linking for cross-device identity recovery.
- Push notifications when a friend beats your score (needs FCM).
- Cosmetics store / seasonal cosmetic rewards.
- Seasons with resets and seasonal badges.

## Execution Plan

_Pick up this contract cold and know exactly how to execute._

### Dependency Graph

```
Phase 1: Ads fix + Difficulty tiers + UTC seeding   (blocking, low risk)
  └── Phase 2: Supabase + identity + replay-verified global LB   (blocked by Phase 1, HIGH risk)
        ├── Phase 3: Friends / local leaderboard      (blocked by Phase 2)   ┐ parallel
        └── Phase 4: Retention & engagement           (blocked by Phase 2)   ┘
```

### Execution Steps

**Strategy**: Hybrid (sequential 1→2, then 3 ∥ 4)

1. **Phase 1** — Ads fix + Difficulty tiers + UTC seeding _(blocking)_

   ```bash
   /ideation:execute-spec docs/ideation/competitive-daily-expansion/spec-phase-1.md
   ```

2. **Phase 2** — Supabase + identity + replay-verified global leaderboard _(blocked by Phase 1)_

   ```bash
   /ideation:execute-spec docs/ideation/competitive-daily-expansion/spec-phase-2.md
   ```

3. **Phases 3 & 4** — parallel after Phase 2 (see agent team prompt, or run sequentially)

   ```bash
   /ideation:execute-spec docs/ideation/competitive-daily-expansion/spec-phase-3.md
   /ideation:execute-spec docs/ideation/competitive-daily-expansion/spec-phase-4.md
   ```

Or run the whole graph automatically:

```bash
/ideation:autopilot
```

### Agent Team Prompt

```
After Phase 2 is merged, two independent tracks can run in parallel.
Teammate A: implement Phase 3 (Friends / local leaderboard) from
  docs/ideation/competitive-daily-expansion/spec-phase-3.md.
Teammate B: implement Phase 4 (Retention & engagement) from
  docs/ideation/competitive-daily-expansion/spec-phase-4.md.
Both depend only on Phase 2 (identity + backend), not on each other.
Coordinate on shared files (lib/main.dart, pubspec.yaml, the Supabase
schema/migrations, and any shared leaderboard widgets) to avoid merge
conflicts — only one teammate should modify a shared file at a time.
```

---

_This contract was generated from brain dump input and approved at Stretch scope._
