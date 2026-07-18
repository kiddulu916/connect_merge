# PlayerProfile Sub-records and Intent Writes — Design

Date: 2026-07-18
Status: Approved (frozen by root `PLAN.md` after two adversarial reviews)

## Summary

`PlayerProfile` is regrouped from 23 public fields into seven immutable
sub-records: `ActivityStreak`, `Progression`, `CosmeticsInventory`,
`PlayerSettings`, `Wallet`, `Rivalry`, and `PrizeLedger`. Multi-field profile
transactions become intent-named pure methods on `PlayerProfile`; single-field
writes use the owning sub-record's `copyWith`.

This is a Dart API refactor only. `PlayerProfile.toJson()` continues to emit
all 23 keys directly, flat, and in the current insertion order. A generated
encoded-string characterization golden pins that byte sequence before the
refactor and remains untouched afterward, while empty and partial raw-map
fixtures pin legacy defaults.

## Sub-record ownership

- `ActivityStreak`: `dailyActiveStreak`, `lastActiveDate`.
- `Progression`: `unlockedAchievements`, `bestRankByDifficulty`, `lifetimeXp`,
  `almanacCounts`.
- `CosmeticsInventory`: `selectedCosmetic`, `adUnlockedCosmetics`,
  `purchasedCosmetics`.
- `PlayerSettings`: `notificationsEnabled`, `reminderMinutes`, `tutorialSeen`,
  `colorblindMode`.
- `Wallet`: `coins`, `lastLootClaimDate`.
- `Rivalry`: `rivalId`, `rivalName`, `lastSeenRivalScoreByTier`.
- `PrizeLedger`: `lastDailyPrizeDate`, `lastWeeklyPrizeDate`,
  `lastMonthlyPrizeMonth`, `lastChallengeCheckDate`, `weeklyPrizes`.

Every class has a const constructor and a minimal `copyWith`. There are no
value-equality overrides and no speculative clear sentinels. `PlayerProfile`
itself has seven fields and a seven-argument `copyWith`.

## Wire compatibility

`fromJson` reads the existing flat schema and supplies the same defaults as the
current implementation. `toJson` does not delegate to group serializers or
spread maps: it lists the existing keys directly in this exact order:

1. `dailyActiveStreak`
2. `lastActiveDate`
3. `unlockedAchievements`
4. `selectedCosmetic`
5. `adUnlockedCosmetics`
6. `notificationsEnabled`
7. `reminderMinutes`
8. `bestRankByDifficulty`
9. `coins`
10. `lastLootClaimDate`
11. `purchasedCosmetics`
12. `lifetimeXp`
13. `almanacCounts`
14. `rivalId`
15. `rivalName`
16. `lastSeenRivalScoreByTier`
17. `tutorialSeen`
18. `colorblindMode`
19. `lastWeeklyPrizeDate`
20. `weeklyPrizes`
21. `lastChallengeCheckDate`
22. `lastDailyPrizeDate`
23. `lastMonthlyPrizeMonth`

The full fixture begins as a raw `Map<String, dynamic>`, is decoded through
the current `PlayerProfile.fromJson`, and records the current
`jsonEncode(profile.toJson())` output as one literal string. It therefore
captures both field spelling and insertion order from running code rather than
from a hand-transcribed expectation.

## Intent write contracts

The prize methods `awardDailyPrize`, `awardWeeklyPrize`, `awardMonthlyPrize`,
and `awardChallengeCheck` add `awardCoins` to the current balance and stamp the
guard even when the award is zero. Weekly awards append crowns. They do not
evaluate period guards, touch storage, or emit; cubit mutex, lexical recheck,
single save, and emit-if-changed behavior remains in `EngagementCubit`.

`advanceActivity` updates the streak and progression transaction together.
`recordPurchase` debits a caller-validated price and unions the cosmetic;
idempotency, unlock-kind, and funds validation remain in `EngagementCubit`.
`grantAdCosmetic` unions its name, `selectCosmetic` replaces the selection,
`claimLoot` adds coins and stamps its date, and `creditCoins` adds with a zero
floor. `setRival` and `clearRival` both reset the last-seen score map;
recording one rival score remains a single `Rivalry.copyWith`.

The four never-used prize clear flags are deleted. Rival clearing exists only
as the intent method.

## Persistence and proof

Both storage implementations route `addCoins` through `creditCoins`. Hive
keeps its existing one awaited `saveProfile`, which keeps the single box put.
No schema, key, box, or migration changes are introduced.

Existing tests may change only constructor fixtures and accessor/copy paths;
their asserted values remain unchanged. Proof is the unchanged wire golden,
focused infrastructure/application/presentation tests, a clean
`flutter analyze`, and the full green `flutter test` suite.

## Out of scope

- Domain and Supabase changes, including TypeScript mirrors and season bumps.
- Moving `PlayerProfile` out of `infrastructure/`.
- Storage schema, key, Hive box, or migration work.
- Changes to `LifetimeStats`, `GameSnapshot`, or `DayResult`.
- New dependencies or `pubspec.yaml` changes.

