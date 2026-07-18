# Plan Review Log: PlayerProfile sub-records (candidate #5)

Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.

(Candidate #1's log lives in git history at b06017f; #2's at 28a539e; #3's at e70490e.)

Grill decisions: API shape = sub-records + intent-named write helpers (user picked over plain nested copyWith, which is MORE verbose than flat, and over helpers-only, which leaves the 23-field quadruplet). Settled from code: wire format stays byte-identical flat JSON (repo-wide "migration-free default" convention; pinned by a new wire-format test); 7 groups by co-access; no == overrides (repo precedent); PlayerProfile stays in storage_service.dart (moving it is candidate-#4 territory).

## Round 1 — Codex

## Material findings

1. **“Byte-identical” is not pinned.** Group-by-group map spreading will reorder today’s interleaved keys, and `jsonEncode` preserves insertion order; asserting map keys/shapes will not detect changed stored bytes.  
   **Fix:** Assert one exact `jsonEncode(profile.toJson())` golden string and keep key ordering centralized in `PlayerProfile.toJson()`.

2. **The proposed unchanged characterization test conflicts with the constructor refactor.** A test using today’s 23 named constructor arguments cannot compile after `PlayerProfile` becomes seven fields; direct round-trip equality also fails without `==`.  
   **Fix:** Construct through an exact legacy JSON fixture and compare the re-encoded JSON, not `PlayerProfile` instances.

3. **Legacy-default compatibility is under-tested.** A fully populated fixture cannot detect broken defaults when older profiles omit later keys.  
   **Fix:** Add an empty/partial legacy JSON fixture asserting every missing field retains its current default.

4. **Prize helper coin semantics are ambiguous and can break candidate #3.** Current prize-local `coins` means an award delta, while loot-local `coins` means the resulting balance; replacement instead of addition would lose concurrent payouts.  
   **Fix:** Name parameters `awardCoins`/`rewardCoins` and specify that helpers add them to the freshly reloaded profile balance.

5. **Candidate #3’s transaction boundary is insufficiently specified.** Each prize helper must run only after the serialized reload and lexical-≥ recheck; weekly must append crowns, zero-payout checks must still persist guards, and helpers must not emit or evaluate guards.  
   **Fix:** Record those four requirements explicitly in each helper contract and pin them with the existing concurrency, zero-payout, and write-then-throw tests.

6. **Nullable `copyWith` semantics remain undefined.** Ordinary nullable parameters cannot distinguish “omitted” from “clear to null,” which is precisely why the five current flags exist.  
   **Fix:** Specify sentinel-based nullable `copyWith`, or retain only dedicated clear operations actually used and delete the four unused prize-clear capabilities.

7. **Rival helpers omit required behavior.** Both current `setRival` and `clearRival` reset `lastSeenRivalScoreByTier`; preserving only IDs/names would produce stale overtake suppression.  
   **Fix:** Define and test both helpers as resetting IDs/names and the last-seen score map atomically.

8. **`purchase` is underspecified.** The current flow is idempotent, rejects insufficient funds, unions ownership, and debits exactly once; a helper that merely subtracts `price` does not own the behavior its name promises.  
   **Fix:** Either encode those invariants in `purchase`, or rename it `recordValidatedPurchase` and explicitly retain all guards in `EngagementCubit`.

9. **The call-site inventory is wrong.** There are 17 production `PlayerProfile.copyWith` sites, not 14, and constructor-only tests such as [profile_screen_test.dart](C:/Users/dat1k/Projects/connect_merge/test/presentation/profile_screen_test.dart:25) are excluded by “tests that read profile fields.”  
   **Fix:** Replace estimates with an explicit `rg`-derived checklist covering all production writes and every `PlayerProfile(...)` test fixture.

10. **The claimed “co-access” grouping does not match the code.** Activity and progression are committed together, while the four prize guards are never committed together; nearly every important transaction still crosses groups through `Wallet`.  
    **Fix:** Justify groups by domain ownership instead of co-access, or regroup according to actual atomic writes.

11. **The restructure does not eliminate the stated four-place maintenance cost.** Every field still appears in a sub-record declaration, constructor, `copyWith`, serializer, and decoder, while adding seven public types and roughly 150 edits.  
    **Fix:** Prefer flat `PlayerProfile` plus the genuinely multi-field intent helpers unless sub-record navigation is itself a firm requirement.

12. **The repository’s required planning workflow is absent.** [PLAN.md](C:/Users/dat1k/Projects/connect_merge/PLAN.md:9) is coarse and does not create the required dated design and task-by-task red-green plan under `docs/superpowers/`.  
    **Fix:** Add the dated spec and implementation plan, with characterization test, API tests, implementation, focused verification, and commit checkpoints.

VERDICT: REVISE
### Claude's response

Verified before revising: setRival AND clearRival both reset lastSeenRivalScoreByTier (rivalry_cubit.dart:86-114 — finding 7 confirmed); the four prize clear* copyWith flags have zero callers (finding 6 confirmed — dead capability); clearRival is the only live clear flag.

Accepted (11/12): wire pin becomes an exact jsonEncode golden STRING with centralized key order (1), constructed from raw JSON fixtures so it compiles across the constructor change (2), plus empty/partial legacy-default fixtures (3); prize helpers renamed award* with awardCoins params and an explicit add-not-replace / append-not-replace / stamp-even-at-zero / no-guard-no-emit-no-storage contract pinned by the candidate-#3 tests (4, 5); dead prize clear* flags deleted, clearRival survives as the helper (6); setRival/clearRival helpers reset the last-seen map (7); purchase renamed recordPurchase with validation explicitly left in the cubit (8); step-0 rg-derived call-site checklist replaces estimates, constructor fixtures included (9); grouping rationale corrected to domain ownership (10); docs/superpowers spec + red-green plan added as step 0 (12).

Rejected (1/12): finding 11 (drop the regroup, keep flat + helpers). That exact option was presented at the grill with the same tradeoff Codex names (grouping distributes rather than eliminates the 4-place cost) and the user chose the regroup. Not re-litigating a user decision made with full information; the honest caveat now lives in the Goal.

## Round 2 — Codex

All prior material findings are addressed; the regroup decision is treated as fixed.

Minor cleanup before implementation:

- `bestRank update` has no current production write site. Fix: remove that example to avoid accidental scope expansion.
- `grantAdCosmetic` should explicitly union existing unlocks, and `claimLoot` should explicitly add `awardCoins`. Fix: state both contracts in step 3.
- “Delegating per group” could still invite reordered map spreading. Fix: require `PlayerProfile.toJson()` to enumerate all 23 keys directly in golden order.

These are non-blocking; the golden and existing behavioral tests should catch incorrect implementations.

VERDICT: APPROVED
### Claude's response

All three non-blocking cleanups folded into the plan: bestRank example removed from the single-field list (no production write site — avoids scope creep); grantAdCosmetic contract states union-not-replace and claimLoot states add-plus-stamp; toJson required to enumerate all 23 keys directly in golden order (no per-group spreading). Plan final.
