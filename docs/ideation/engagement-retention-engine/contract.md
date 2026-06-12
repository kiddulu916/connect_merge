# Engagement & Retention Engine Contract

**Created**: 2026-06-11
**Confidence Score**: 94/100
**Status**: Approved
**Supersedes**: None
**Approved Scope Tier**: Stretch (MVP + Full + Stretch)

## Problem Statement

merge_count has a polished daily ritual but it is one-and-done: a player finishes their four deterministic boards and has zero reason to reopen the app until the next UTC day. There is no variable reward to create dopamine variance, nothing accumulates across days beyond a streak number and a static achievement list, and the friends leaderboard is passive — it shows ranks but never provokes interaction.

The fix is to layer three missing psychological systems — variable reward, meta-progression, and active async social — onto the existing engine while weaponizing the deterministic shared board the game already generates. Every feature must hold the project's two hard pillars: $0 infrastructure (Supabase free tier + on-device logic, no FCM, no real-time) and a wholesome-but-effective tone (NYT/Duolingo lane, no manipulative timers or guilt).

## Goals

1. Create at least 4 honest daily return moments (staggered content + local notifications) so players reopen mid-day, not just once.
2. Add a variable-reward dopamine loop via a deterministic, cheat-proof, $0 Daily Loot Chest and occasional golden tiles.
3. Introduce a soft-currency meta-progression economy that makes the existing cosmetics screen earnable through play, plus a collection/almanac and player level.
4. Convert the passive friends leaderboard into active competition via async duels (deep-link, same-board, auto-compare) and rivalries.
5. Close core UX gaps (first-run tutorial, undo, stats calendar, colorblind-safe tiles) inside the $0 ceiling and wholesome tone.

## Success Criteria

- [ ] Daily Loot Chest claimable once per UTC day; reward derived from the daily seed, byte-identical for every player on that date; a rewarded ad doubles it.
- [ ] A bonus board and the loot chest unlock at later times of day; local notifications (no FCM) fire for midday content, chest-ready, and streak-guard moments.
- [ ] Out-of-moves / deadlock screens show a near-miss line and, where legal, the rewarded continue.
- [ ] Soft currency earned from completion/loot/ads is spendable on cosmetic tile themes.
- [ ] A Merge Almanac/collection and a player level visibly accumulate across days and surface on profile/leaderboard.
- [ ] A duel link makes a friend play the identical (date,tier) board and auto-compares both scores.
- [ ] A rival shows a persistent you-vs-them indicator plus a nudge when the rival passes the player.
- [ ] Share output is upgraded to a rendered image card via share_plus.
- [ ] First-run users get an interactive tutorial; a stats calendar shows history; tiles are distinguishable without color.
- [ ] No feature needs paid infrastructure; `flutter analyze` clean and `flutter test` passes with new seed/loot/economy tests.

## Scope Boundaries

### In Scope

**MVP (Phase 1)**
- Daily Loot Chest (seed-derived, once/UTC-day, variable currency + rare shard, rewarded-ad double).
- Soft-currency wallet primitive (Hive `PlayerProfile`).
- Golden tiles (deterministic bonus-currency drops; never scored).
- Staggered return moments + local notifications.
- Near-miss framing on out-of-moves/deadlock.

**Full (Phases 2 + 3 + 4)**
- Earned cosmetics economy (cosmetics_screen wired to currency).
- Merge Almanac / collection + mastery badges.
- Player level / XP, surfaced on profile + leaderboard.
- Additional rewarded-ad surfaces (streak freeze, hint, reveal-next-drop, double-coins).
- Richer rendered share card.
- Async duels (deep-link, same board, auto-compare).
- Rivalries (you-vs-them + pass nudge).
- Polish: first-run tutorial, undo last merge, stats calendar, colorblind-safe tiles.

**Stretch (Phase 5 — approved, gated)**
- Endless Climb — roguelike anytime mode with meta-progression, behind a human decision gate.

### Out of Scope

- Referral / invite-to-install rewards (install attribution hard at $0).
- FCM / managed push (violates $0 ceiling; local notifications suffice).
- Real-time / live multiplayer rivalries (async by design).
- Hard currency, season pass, IAP store (ads + earned cosmetics only).
- Aggressive FOMO mechanics (guilt timers, loss-aversion pressure) — tone locked to wholesome.

### Future Considerations

- Light IAP (remove-banner-ads, direct cosmetic purchase) once the earned economy is validated.
- Full F2P economy / season pass if the revenue ceiling needs raising.
- Referral rewards if an install-attribution path becomes affordable.
- Seasonal events and seasonal cosmetic rewards.

## Execution Plan

### Dependency Graph

```
Phase 1: Variable Reward & Return Moments        (blocking, low risk)
  ├── Phase 2: Meta-progression & Earned Cosmetics   (blocked by 1)   ┐ parallel
  └── Phase 3: Async Social: Duels & Rivalries       (blocked by 1)   ┘
Phase 4: Polish & Accessibility                  (independent, low risk — parallel anytime)
Phase 5: Endless Climb                           (GATED: blocked by 1–3 + metrics decision)
```

### Execution Steps

**Strategy**: Hybrid (Phase 1 first → Phases 2 ∥ 3 ∥ 4 → Phase 5 only if the gate clears)

1. **Phase 1** — Variable Reward & Return Moments _(blocking)_
   ```bash
   /ideation:execute-spec docs/ideation/engagement-retention-engine/spec-phase-1.md
   ```
2. **Phases 2, 3, 4** — parallel after Phase 1
   ```bash
   /ideation:execute-spec docs/ideation/engagement-retention-engine/spec-phase-2.md
   /ideation:execute-spec docs/ideation/engagement-retention-engine/spec-phase-3.md
   /ideation:execute-spec docs/ideation/engagement-retention-engine/spec-phase-4.md
   ```
3. **Phase 5** — only after the decision gate in spec-phase-5.md clears
   ```bash
   /ideation:execute-spec docs/ideation/engagement-retention-engine/spec-phase-5.md
   ```

Or run the whole graph automatically:

```bash
/ideation:autopilot
```

### Agent Team Prompt

```
After Phase 1 (Variable Reward & Return Moments) is merged, three independent
tracks can run in parallel.
Teammate A: implement Phase 2 (Meta-progression & Earned Cosmetics Economy) from
  docs/ideation/engagement-retention-engine/spec-phase-2.md.
Teammate B: implement Phase 3 (Async Social: Duels & Rivalries) from
  docs/ideation/engagement-retention-engine/spec-phase-3.md.
Teammate C: implement Phase 4 (Polish & Accessibility) from
  docs/ideation/engagement-retention-engine/spec-phase-4.md.
Phase 2 and Phase 3 depend only on Phase 1's wallet + chest, not on each other;
Phase 4 is independent of all of them. Do NOT start Phase 5 (Endless Climb) — it
is gated on post-launch retention metrics.
Coordinate on shared files (lib/main.dart, pubspec.yaml, lib/domain/constants.dart,
lib/infrastructure/storage_service.dart, and shared profile/leaderboard widgets) —
only one teammate should modify a shared file at a time.
```

---

_This contract was generated from a feature-ideation session and approved at Stretch scope._
