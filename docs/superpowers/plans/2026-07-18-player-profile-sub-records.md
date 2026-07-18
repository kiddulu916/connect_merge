# PlayerProfile Sub-records and Intent Writes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:test-driven-development` while implementing this plan task by
> task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Regroup the 23-field `PlayerProfile` into seven cohesive sub-records
and migrate multi-field writes to intent-named helpers without changing one
byte of its flat JSON representation or any behavior.

**Architecture:** Seven immutable records own related values while
`PlayerProfile` remains the persistence boundary and directly flattens them in
the existing key order. Pure profile transforms express write intent; cubits
retain validation, guards, synchronization, persistence, and emission.

**Tech stack:** Dart/Flutter, flutter_bloc Cubit, Hive, existing
`StorageService`, Flutter test.

## Global constraints

- Follow frozen root `PLAN.md` exactly; this document records rather than
  redesigns it.
- Do not run Git-mutating commands. The reviewer owns all Git state changes.
- Do not touch `lib/domain/**`, `supabase/**`, `lib/main.dart`, `pubspec.yaml`,
  `LifetimeStats`, `GameSnapshot`, or `DayResult`.
- Keep all 23 JSON keys flat, direct, and in the exact current order; never
  spread per-group maps into `PlayerProfile.toJson()`.
- Add no migration, storage key, schema, box, dependency, equality, or hash
  behavior.
- Prize helpers add awards, weekly awards append crowns, and all award helpers
  stamp guards for zero awards. They never guard, persist, or emit.
- `recordPurchase` assumes caller validation; `grantAdCosmetic` unions;
  `creditCoins` clamps at zero; setting and clearing rivals reset last-seen
  scores.
- Existing tests may receive accessor-path and constructor-fixture edits only;
  do not change any asserted value.
- Every new behavior begins with a focused failing test. The wire-format
  characterization test instead must pass against the pre-refactor class and
  stay byte-identical afterward.

---

### Task 1: Record the frozen design, plan, and call-site inventory

**Files:**

- Create: `docs/superpowers/specs/2026-07-18-player-profile-sub-records-design.md`
- Create: `docs/superpowers/plans/2026-07-18-player-profile-sub-records.md`

**Interfaces:**

- Consumes: frozen root `PLAN.md` and the current source tree.
- Produces: implementation order plus a compiler-checkable migration list.

- [ ] Write both dated documents before changing tests or production code.
- [ ] Run the inventory commands and reconcile their counts with the lists
  below:

```powershell
rg -n "(?:profile|p)\.copyWith\(" lib --glob "*.dart"
rg -n "PlayerProfile\s*\(" test --glob "*.dart"
```

- [ ] Confirm the production write inventory contains these 17 current
  `PlayerProfile.copyWith` sites:

```text
lib/application/rivalry_cubit.dart:91   set rival
lib/application/rivalry_cubit.dart:106  clear rival
lib/application/rivalry_cubit.dart:152  record last-seen rival score
lib/application/loot_cubit.dart:53      claim loot
lib/application/loot_cubit.dart:68      double loot reward
lib/application/engagement_cubit.dart:241 advance activity/progression
lib/application/engagement_cubit.dart:274 select cosmetic
lib/application/engagement_cubit.dart:284 grant ad cosmetic
lib/application/engagement_cubit.dart:318 record purchase
lib/application/engagement_cubit.dart:452 award daily prize
lib/application/engagement_cubit.dart:537 award weekly prize
lib/application/engagement_cubit.dart:604 award monthly prize
lib/application/engagement_cubit.dart:643 award challenge check
lib/presentation/screens/tier_select_screen.dart:402 enable notifications
lib/infrastructure/hive_storage_service.dart:94 add coins
lib/infrastructure/storage_service.dart:440 add coins
lib/presentation/screens/game_screen.dart:91 dismiss tutorial
```

- [ ] Confirm the test-fixture inventory contains these 30 constructor sites:

```text
test/presentation/profile_screen_test.dart:25
test/infrastructure/in_memory_storage_test.dart:105,129,136,143,165,177
test/infrastructure/hive_storage_test.dart:85
test/application/loot_cubit_test.dart:22,103
test/application/engagement_test.dart:135,143,152,177,196,219,263,272,288
test/application/economy_test.dart:20,34,41,59,74,84,98,109,132
test/application/daily_prize_test.dart:84
```

- [ ] Read-only review: run `git diff --check` and inspect the scoped diff;
  do not stage or commit.

### Task 2: Capture the current flat wire format

**Files:**

- Create: `test/infrastructure/profile_wire_format_test.dart`

**Interfaces:**

- Consumes: existing `PlayerProfile.fromJson` and `toJson`.
- Produces: one exact encoded-string golden plus empty/partial legacy fixtures
  that compile unchanged across the API refactor.

- [ ] Add a temporary test that builds a raw map containing all 23 fields,
  calls `jsonEncode(PlayerProfile.fromJson(fixture).toJson())`, and prints the
  result.
- [ ] Run
  `flutter test test/infrastructure/profile_wire_format_test.dart --plain-name "capture current full profile wire format"`
  and copy the generated output into the final literal expectation.
- [ ] Replace the temporary capture with an exact `expect(encoded, golden)`;
  add empty-map and early-phase partial-map assertions for every current
  default.
- [ ] Run `flutter test test/infrastructure/profile_wire_format_test.dart` and
  record the pre-refactor passing output. Do not edit this file again.

### Task 3: Specify and implement sub-records and pure write helpers

**Files:**

- Create: `test/infrastructure/profile_write_helpers_test.dart`
- Modify: `lib/infrastructure/storage_service.dart`

**Interfaces:**

- Produces: `ActivityStreak`, `Progression`, `CosmeticsInventory`,
  `PlayerSettings`, `Wallet`, `Rivalry`, `PrizeLedger`, and the frozen helper
  signatures from root `PLAN.md`.

- [ ] Add focused tests for nested `copyWith`, all award add/append/stamp
  contracts (including zero awards), activity advancement, validated purchase
  recording, ad union, selection, loot claim, clamped coin credit, and both
  rival-reset methods.
- [ ] Run `flutter test test/infrastructure/profile_write_helpers_test.dart` and
  verify compilation/failures identify the missing records and helpers.
- [ ] Implement only the seven immutable classes, seven-field
  `PlayerProfile`, direct flat `toJson`, regrouping `fromJson`, and named pure
  transforms required by those tests. Delete the four dead prize-clear flags
  and the profile-level rival clear flag.
- [ ] Run `flutter test test/infrastructure/profile_write_helpers_test.dart`
  and verify green; re-run the untouched wire file separately and compare its
  golden text.

### Task 4: Migrate production writes and reads

**Files:**

- Modify: `lib/application/engagement_cubit.dart`
- Modify: `lib/application/loot_cubit.dart`
- Modify: `lib/application/rivalry_cubit.dart`
- Modify: `lib/infrastructure/storage_service.dart`
- Modify: `lib/infrastructure/hive_storage_service.dart`
- Modify: `lib/presentation/screens/game_screen.dart`
- Modify: `lib/presentation/screens/tier_select_screen.dart`

**Interfaces:**

- Consumes: the Task 3 record fields and pure helper methods.
- Preserves: prize mutex/lexical guards/single-save/emit-if-changed behavior,
  purchase validation, loot emission values, and Hive's one awaited put path.

- [ ] Replace all direct reads with their owning group path.
- [ ] Replace the 17 inventoried writes with the required intent helper or one
  owning-group `copyWith`; use `creditCoins` in both `addCoins` methods.
- [ ] Run focused application and presentation tests, then `flutter analyze`;
  use compiler diagnostics to find any missed production accessor.

### Task 5: Migrate test accessors and fixtures without changing expectations

**Files:**

- Modify: every test reported by
  `rg -l "PlayerProfile|loadProfile" test --glob "*.dart"`, except the frozen
  `test/infrastructure/profile_wire_format_test.dart`.

**Interfaces:**

- Consumes: seven-record constructor and accessor paths.
- Preserves: every existing asserted value and all 18 prize assertions.

- [ ] Convert each inventoried constructor to the minimum relevant sub-record
  fixture and each direct profile read/copy to its new group path.
- [ ] Review the diff for assertion-line value changes; revert any such change.
- [ ] Run all affected test files, then use `rg` and analyzer output to prove no
  old field path or flat fixture remains.

### Task 6: Final verification and frozen-plan audit

**Files:**

- Verify all changed files; make no unrelated edits.

- [ ] Run `dart format` only on changed Dart files.
- [ ] Run the untouched wire-format test and the focused profile/helper tests.
- [ ] Run fresh `flutter analyze` and capture its full tail.
- [ ] Run fresh full `flutter test` and capture its full tail.
- [ ] Re-read root `PLAN.md` line by line; verify every helper contract, all
  seven groups, the 23-key order, call-site checklist, forbidden-path list,
  and existing-test restriction against the read-only diff.
- [ ] Run `git diff --check` and inspect `git status --short`; do not stage,
  commit, branch, checkout, or stash.
