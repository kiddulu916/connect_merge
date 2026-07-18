# Plan: Regroup PlayerProfile into sub-records with intent-named writes

_Locked via grill — by Claude + kiddulu916. Revised after Codex round 1._

## Goal

`PlayerProfile` (`lib/infrastructure/storage_service.dart:105-359`) is a 23-field flat bag: constructor, `copyWith` (with 5 ad-hoc `clear*` flags, 4 of which are dead — never called anywhere), `toJson`, and `fromJson` each enumerate all 23, and nothing tells a reader which fields belong together or which multi-field writes are transactions. Regroup the fields into 7 cohesive sub-records AND give `PlayerProfile` intent-named write methods for the multi-field transactions the call sites actually perform (grill decision) — write sites get shorter than today instead of drowning in nested `copyWith`. The on-disk format stays the exact flat JSON it is today — pinned by an encoded-string golden, not a key-set check — so there is zero migration and old builds stay compatible; the change is purely a Dart-API restructure.

## Approach

0. **Repo planning workflow first**: dated design doc under `docs/superpowers/specs/` and task-by-task red-green plan under `docs/superpowers/plans/` (per CLAUDE.md/AGENTS.md, same as candidates #1–#3), including an explicit `rg`-derived call-site checklist of every production `PlayerProfile` write and every `PlayerProfile(...)` test fixture (Codex counted 17 production `copyWith` sites, and constructor-fixture tests like `profile_screen_test.dart` are in scope too — no estimates, an enumerated list).
1. **Wire-format golden tests first** (`test/infrastructure/profile_wire_format_test.dart`, NEW) — written to survive the refactor unchanged, so they are constructed from raw JSON fixtures, never from the Dart constructor:
   - **Full fixture**: a raw `Map` literal exercising all 23 keys → `PlayerProfile.fromJson` → `toJson` → assert `jsonEncode(...)` equals one exact golden STRING (key order included — `jsonEncode` preserves insertion order, so `toJson` must centrally emit today's key order even after grouping).
   - **Legacy-defaults fixture**: an empty map and a partial map (early-phase keys only) → `fromJson` → assert every missing field gets today's default (the migration-free guarantee older installs rely on).
   Both must pass against the CURRENT class before the refactor starts, then keep passing untouched.
2. **Sub-records** (same file, small immutable classes, repo style — const constructors, `copyWith`, no `==` override), grouped by domain ownership (which system owns the fields — co-commit patterns cross groups via coins by design and don't define them):
   - `ActivityStreak` — `dailyActiveStreak`, `lastActiveDate` (headline streak system)
   - `Progression` — `unlockedAchievements`, `bestRankByDifficulty`, `lifetimeXp`, `almanacCounts` (meta-progression)
   - `CosmeticsInventory` — `selectedCosmetic`, `adUnlockedCosmetics`, `purchasedCosmetics`
   - `PlayerSettings` — `notificationsEnabled`, `reminderMinutes`, `tutorialSeen`, `colorblindMode`
   - `Wallet` — `coins`, `lastLootClaimDate`
   - `Rivalry` — `rivalId`, `rivalName`, `lastSeenRivalScoreByTier`
   - `PrizeLedger` — `lastDailyPrizeDate`, `lastWeeklyPrizeDate`, `lastMonthlyPrizeMonth`, `lastChallengeCheckDate`, `weeklyPrizes`
   `PlayerProfile` becomes 7 fields; `toJson` enumerates all 23 flat keys DIRECTLY in today's golden order (no per-group map spreading — reordering is exactly what the string golden exists to catch), and `fromJson` regroups.
3. **Intent-named write methods on `PlayerProfile`** — each a pure profile→profile transform with an explicit contract; none evaluates guards, touches storage, or emits (that stays in the cubits, exactly as candidate #3 left it):
   - `awardDailyPrize(String date, {required int awardCoins})`, `awardWeeklyPrize(String weekFrom, {required int awardCoins, required List<WeeklyPrize> crowns})`, `awardMonthlyPrize(String monthKey, {required int awardCoins})`, `awardChallengeCheck(String date, {required int awardCoins})` — contract: ADD `awardCoins` to the receiver's (freshly reloaded, mutex-held) balance, never replace; APPEND crowns, never replace; stamp the guard even when `awardCoins == 0`; caller owns the lexical-≥ guard recheck, the serialized commit, and emit-iff-changed. Pinned by the 18 existing candidate-#3 tests (concurrency, zero-payout, write-then-throw) which must pass with only accessor-path edits.
   - `advanceActivity({required int streak, required String date, required Set<String> achievements, required int lifetimeXp, required Map<String, int> almanacCounts})` — the onTierCompleted commit (spans ActivityStreak + Progression, which is fine: helpers are transactions over groups).
   - `recordPurchase(String cosmeticName, {required int price})` — records a caller-VALIDATED purchase (debits price, unions the name); idempotency and funds checks stay in `EngagementCubit.purchaseCosmetic` where they live today, and the doc comment says so (named `recordPurchase`, not `purchase`, so the name doesn't promise validation it doesn't do).
   - `grantAdCosmetic(String name)` — UNIONS into the existing ad-unlocked set (never replaces); `selectCosmetic(String name)`.
   - `claimLoot(String date, {required int awardCoins})` — ADDS `awardCoins` to the balance and stamps the claim date atomically (loot_cubit's write); `creditCoins(int delta)` clamped at 0 (single-sources the clamp now duplicated in both `addCoins` impls).
   - `setRival(String id, String name)` / `clearRival()` — BOTH reset `lastSeenRivalScoreByTier` to empty, mirroring today's spurious-nudge protection in `rivalry_cubit.dart:86-114`; plus `recordRivalScore`-style last-seen update stays a plain group copyWith (single-field).
   - Single-field writes (tutorialSeen, notification prefs) use group copyWith: `profile.copyWith(settings: profile.settings.copyWith(tutorialSeen: true))`.
4. **Clear semantics**: the four never-called prize `clear*` flags are DELETED (dead capability; the wire pin doesn't care). `clearRival` survives as the `clearRival()` helper. Sub-record `copyWith`s keep the repo's existing flag pattern only where a real caller needs clearing (currently: none besides rival) — no sentinel cleverness.
5. **Migrate call sites** from the step-0 checklist (~17 production `copyWith` sites + reads across `engagement_cubit.dart`, `loot_cubit.dart`, `rivalry_cubit.dart`, `hive_storage_service.dart`, `storage_service.dart`, `game_screen.dart`, `tier_select_screen.dart`; ~90 test accesses + constructor fixtures). The compiler catches every miss — field moves are breaking by design.
6. **Prove**: both wire goldens unchanged and green; `flutter analyze` clean; full `flutter test` green with only accessor-path/fixture edits to existing tests (no assertion-value changes anywhere — behavior is untouched).

## Key decisions & tradeoffs

- **Flat wire format pinned as an encoded string, not a key set** (Codex round 1): `jsonEncode` preserves insertion order, so only an exact-string golden catches accidental reordering; fixture-driven construction keeps the pin compiling across the constructor change.
- **Sub-records + intent helpers over plain nested copyWith** (grill decision): plain nesting makes every write site MORE verbose (Dart has no lenses); the helpers are what pay for the churn. **Codex proposed dropping the regroup entirely (flat + helpers only); rejected**: that exact option was on the table at the grill with its tradeoff stated, and the user chose the regroup. The honest version of Codex's point stands in the goal: grouping distributes rather than eliminates the per-field 4-place cost — but each place becomes a small cohesive class, which is the candidate's actual aim.
- **Groups justified by domain ownership, not co-access** (Codex round 1, accepted): the prize guards are never stamped together and `advanceActivity` spans two groups — co-access was the wrong rationale; ownership (which system reads/writes the fields) is the real one, and transactions legitimately cross groups via helpers.
- **Helpers are transactions with explicit contracts**: add-vs-replace named in parameters (`awardCoins`), append-vs-replace stated for crowns, guard/emit/storage responsibilities explicitly left with the cubits — so candidate-#3 semantics cannot silently shift.
- **`recordPurchase` keeps validation in the cubit** — moving idempotency/funds checks into the profile would change where failures surface (return values, emits) for zero gain; the name is scoped to what it does.
- **Dead clear-flags deleted** rather than ported — capability nobody calls is complexity smuggled forward.
- **No `==`/`hashCode`** — repo precedent; nothing compares profiles by value (the wire goldens compare strings).
- **`PlayerProfile` stays in `storage_service.dart`** — moving it to domain is candidate-#4 territory.

## Risks / open questions

- Largest mechanical churn of the candidates (~150 sites); mitigated by compiler-enforced breaks, the enumerated checklist, and zero permitted assertion-value changes.
- The golden string must match Dart's `jsonEncode` of today's `toJson` exactly — the build's first task captures it from the CURRENT code before any restructuring, so the pin is generated, not hand-typed.
- `addCoins` in two storage impls routes through `creditCoins` — watch that Hive's awaited save path stays identical (same single put).

## Out of scope

- No storage schema/key changes, no Hive box changes, no migration code.
- No move of `PlayerProfile` out of `infrastructure/` (candidate #4).
- No behavior changes; existing tests may only change accessor paths/fixtures, never asserted values.
- No TS mirror, no season bump (client-only).
- `LifetimeStats`, `GameSnapshot`, `DayResult` untouched.
