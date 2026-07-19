# Leaderboard Prizes and Friends Period Boards — Design

Date: 2026-07-18
Status: Approved (frozen by root `PLAN.md` after four adversarial reviews)

## Summary

The leaderboard read path is repaired without widening `players` RLS. Global
and friends display RPCs become bounded, tightly projected `SECURITY DEFINER`
functions, while prize checks use two `SECURITY INVOKER` caller-rank RPCs that
rank the world-readable `scores` table before selecting the caller. Daily,
weekly, and monthly rewards extend to ranks 1–5; Challenge keeps ranks 1–10
with the new broad-and-shallow table.

Friends boards mirror daily, weekly, monthly, and all-time global views. The
Challenge board remains daily-only in both scopes and may display up to 100
rows while showing prize markers only for ranks 1–10.

## Database read boundary

`leaderboard`, `leaderboard_period`, `friends_leaderboard`, and the new
`friends_leaderboard_period` expose only rank, display name, score/total, and
the caller flag. Each pins `search_path`, clamps a nullable or attacker-chosen
limit to 1–100, and receives an explicit revoke-before-grant ACL. The two
friends functions remain authenticated-only; the two global boards remain
available to anon and authenticated callers.

`my_daily_ranks` and `my_period_ranks` never join `players`. They remain
`SECURITY INVOKER`, rank all season/range competitors in an inner query, and
filter to `auth.uid()` only in the outer query. Daily spans are at most seven
days and period spans at most 31 days; reversed and future ranges are rejected.
Period totals remain `bigint` end to end.

The reverse friendship index supports both canonical edge directions. A local
smoke script, kept outside migrations, verifies visibility, ranking, ties,
limits, guards, ACLs, and diagnostic index plans.

## Service contracts

`LeaderboardService.myDailyRanks({from, to})` maps RPC rows into
`Map<String, Map<Difficulty, int>>`, keyed first by UTC date. This lets the
daily and Challenge prize checkers each fetch their entire bounded catch-up
window in one call. `myPeriodRanks({from, to})` returns
`Map<Difficulty, int>` for one summed period.

`FriendsService.friendsLeaderboardPeriod({difficulty, from, to})` maps the
RPC `total` column onto `LeaderboardEntry.score`, matching the existing global
period service and row widget.

## Prize catch-up

Daily and Challenge inspect at most seven closed days. Weekly inspects at most
four closed Monday–Sunday weeks, and monthly at most two closed calendar
months. A null guard checks only the most recent closed period. Otherwise each
checker starts with the oldest unclaimed period inside its lookback, processes
oldest-first, and stops at the first failed fetch or uncommitted period. Guards
therefore advance only through a contiguous successful prefix.

Each closed period pays once using the best qualifying rank across tiers.
Weekly crowns are still recorded for every qualifying non-Challenge tier.
Prize commits retain the shipped serialized reload/check/save behavior.

## Presentation behavior

Period controls are visible in both Global and Friends scopes for ordinary
tiers. Friends period selections call the friends-period RPC with the same UTC
ranges as global boards. `_load` computes an effective daily period for
Challenge before routing either scope, so switching from a selected weekly or
monthly ordinary tier cannot load a Challenge period aggregation.

Challenge rendering defensively takes at most 100 rows. Trophy markers remain
on ranks 1–3 and star markers on ranks 4–10. Weekly ranks 4–5 use the medal
fallback already used by the crown-history section.

## Proof strategy

Service tests pin both new RPC payloads and response mappings. Application
tests pin payout boundaries, cross-tier best-rank semantics, every lookback
bound, null-guard behavior, oldest-first processing, and halt/retry behavior.
Widget tests pin friends period routing, Challenge daily coercion, 100-row
Challenge display, top-10 markers, and rank-4/5 crowns. The SQL smoke script
covers the database trust boundary. Completion requires fresh clean
`flutter analyze` and full `flutter test` runs.

## Out of scope

- Server-side wallets, scheduled payouts, snapshots, or cron.
- Friends-board prizes or cross-tier combined boards.
- Engine, replay validator, season, or golden-vector changes.
- Retroactive re-evaluation of claimed periods or versioned payout tables.
- Storage-wide profile-write serialization or an offline submit queue.

