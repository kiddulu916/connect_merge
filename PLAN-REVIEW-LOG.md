# Plan Review Log: Diagonal chain adjacency + sum-based merge value
Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.

Reviewer model: gpt-5.6-sol (config-pinned) — codex-cli 0.144.4.

## Round 1 — Codex
Thread: 019fe217-dd37-7071-a002-bd6a5fdd26d5

1. **Board generation does change.** `DailySeeder.generate()` uses `hasChainOfLength` to accept/re-roll placements; an 8-neighbor predicate changes the accepted board and PRNG position (`daily_seeder.dart:102`). A simulation changed 35 of 1,825 committed board-vector cases, contradicting the plan's original "out of scope" claim.
2. **"Uncapped" legality remained capped in three live paths.** Dart `_pairMergeable`, DFS termination, TS `pairMergeable`, and `BoardWidget._canExtend` all still reject `kMaxTier` (`game_engine.dart:121`, `constants.ts:100`, `board_widget.dart:55`); TS `pairMergeable` is live, not vestigial.
3. **Existing snapshots become unreplayable.** Version-N snapshots resume unchanged while fresh generation/collapse arithmetic differs (`game_cubit.dart:254`, `constants.dart:138`).
4. **Scoring was off by 2×.** `comboScore(tier, n) = 2^(tier+1) × multiplier`; passing the new result tier directly (as originally drafted) would score a value-4 result tile as base-8 instead of base-4 (`game_engine.dart:227`).
5. **No numeric/storage contract for uncapped tiers.** TS power calculations use 32-bit signed shifts (`engine.ts:100,134`); Postgres stores `score`/`highest_tier` as `int` (`0001_players_scores.sql:22-23`).
6. **Golden regeneration still searches orthogonally.** `_firstLegalChain` hardcodes `areOrthogonallyAdjacent` (`golden_vectors_test.dart:426`), so regenerated fixtures could miss diagonal-only boards.
7. **Tutorial's deadlock lesson likely breaks.** Its fixture/edge-counter only considers east/south edges (`tutorial_tour_screen_test.dart:74`).
8. **UI task assumed a connector that doesn't exist.** `BoardWidget` only applies a per-cell `BoxShadow` highlight (`board_widget.dart:~164`) — no line-connector painter to update.
9. **Rollout incompatible with installed old clients during deploy skew** — old-rule client submissions could fail replay against a new-rule server mid-rollout (`submit-score/index.ts:67`).
10. **Production parity failures poorly attributable** — submission analytics lack an engine/rule dimension (`game_cubit.dart:~644`).
11. **Docs/test scope incomplete** — README and `ChainEvent` still describe the old rule; test scope named only two files (`README.md:10`, `move.dart:54`).

VERDICT: REVISE

### Claude's response
Verified the highest-severity findings directly against the code before accepting: read `daily_seeder.dart:85-114` (confirms #1 — the re-roll loop calls `GameEngine.hasChainOfLength`, same predicate step 2 changes); read `game_engine.dart:1-150` (confirms #2 — `_pairMergeable` independently hardcodes `higher < kMaxTier` and orthogonal-only "east and south" geometry, separate from `isValidChain`'s check; confirms #4 — the existing test-pinned example calls `comboScore(3, 5)` for a chain peaking at tier 3, i.e. `comboScore` takes the pre-merge peak tier and adds 1 internally, so passing a raw new result tier would double the score); read `game_cubit.dart:245-264` (confirms #3 — resume gates only on `snap.version == kSnapshotVersion`); read `submit-score/index.ts:50-79` (context for #9); grepped `engine.ts` for `1 <<` (confirms #5 — both `comboScore`/`collapseChain` use 32-bit bitwise shift) and read `0001_players_scores.sql` (confirms `score`/`highest_tier` are `int`, not `bigint`); grepped `board_widget.dart` (confirms #8 — only `BoxShadow`, no connector/line painter).

**Incorporated (all 11):** #1 moved `DailySeeder`/board generation from Out-of-scope into Approach as an explicitly in-scope seeder change requiring `board_vectors.json` regen; #2 broadened the adjacency/cap removal to all four call sites (`_pairMergeable`, `hasMergeAvailable`, `hasChainOfLength` DFS, TS `pairMergeable`, `BoardWidget._canExtend`), not just `isValidChain`; #3 added an explicit Approach step requiring in-progress same-day snapshots not silently resume under new rules, mechanism deferred to implementation; #4 fixed the scoring call to `comboScore(resultTier - 1, chainLength)` with a pinned numeric regression test, documented precisely as a Key decision; #5 added double-based (`2 ** n`) exponentiation replacing `1 << n` in TS, a `bigint` migration for `scores.score`/`highest_tier`, and a generous technical (not gameplay) safety ceiling (~tier 45) distinct from the removed `kMaxTier` cap; #6 added updating `_firstLegalChain`'s adjacency rule and requiring a diagonal-only fixture case; #7 added rebuilding the tutorial deadlock fixture under 8-directional adjacency; #8 corrected the UI task's false premise (no connector exists) and replaced it with a widget test proving the existing per-cell highlight already generalizes, rather than assumed rendering work; #9 added as an explicit named Risk (bounded-window client/server skew, accepted tradeoff, no new mechanism); #10 added a season/rule dimension to existing submission analytics; #11 added a docs/analytics sweep step covering README and `ChainEvent`/`move.dart`, and broadened test scope beyond the original two files.

**Rejected:** none — every finding was code-grounded and material.

## Round 2 — Codex (same thread, resumed)
Confirmed addressed: board-generation drift, off-by-one scoring, both vector fixtures, golden-vector search, tutorial, diagonal widget testing, docs, nonexistent-connector premise. Ten new/sharper:

1. **Snapshot invalidation still deferred, should be decisive.** Every played old snapshot embeds old collapse arithmetic even when generation didn't change.
2. **Rollout window called "bounded" isn't, for clients that never update** — a fairness-contract concern, not just a documentation gap.
3. **Tier-45 ceiling is unjustified.** `2**45` is representable but score accumulation (multiplier × bonuses) can exceed JS's safe-integer range regardless; the real bound should be derived from game constants, not invented.
4. **`Math.clz32` truncates to 32 bits** — incompatible with any ceiling anywhere near 2^45; only valid if the real bound is proven under 2^31.
5. **Migrating `score`/`highest_tier` alone breaks RPC contracts** — `upsert_best_score` (`0014_atomic_score_upsert.sql`) already exists live with `int` params/returns; `leaderboard()` and the friends-leaderboard RPC also return `score int`.
6. **Recreating the upsert RPC risks reopening score forgery** if its existing `SECURITY INVOKER`/pinned-`search_path`/revoked-grants contract isn't explicitly re-asserted (grants don't survive a drop+recreate).
7. **Adjacency call-site map was factually wrong.** DFS (`_searchChain`/`searchChain`) has its own independent neighbor list and terminal cap check — doesn't call `_pairMergeable`/`pairMergeable` at all. TS geometry for the pair-scan lives in `hasAnyMergeablePair`, not a function named `pairMergeable` alone.
8. **`pairMergeable`/`_pairMergeable` mischaracterized as fossils** — they're the live length-2 deadlock predicate; only `GameEngine.canMerge` (and its literal counterpart) is genuinely vestigial.
9. **Observability still client-only** — server has no structured rejection-stage logging distinguishing why an `invalid_run` happened.
10. **Verification scope incomplete** — plan named two test files, not the full `flutter analyze`/`flutter test`/both vector suites/`deno test --frozen`.

VERDICT: REVISE

### Claude's response
Verified before accepting: grepped `constants.ts` for the cited function names (confirms #7/#8 — `hasAnyMergeablePair`+`pairMergeable` is the pair-scan pair, `searchChain` is separate and doesn't call either); read `game_engine.dart:148-193` (confirms `_searchChain`'s own hardcoded 4-directional neighbor list and independent `tier < kMaxTier` check at line 151, entirely unconnected to `_pairMergeable`); read `constants.dart` in full to sanity-check the tier-ceiling question myself rather than accept either my own "45" or Codex's specific "17" uncritically (confirmed `kMaxDrops=39`, `dropCap` caps at 6, `kCellCount=25` — enough to know a real derivation is tractable and neither guess should ship unverified); read `0014_atomic_score_upsert.sql` directly (confirms #5/#6 — the function already exists, live, with the exact security contract that must be re-asserted verbatim on any signature change) and grepped `0013_friends_leaderboard_player_id.sql` (confirms `score int` return type also needs updating).

**Incorporated (8 of 10):** #1 committed decisively to bumping `kSnapshotVersion`, citing its own doc comment as established precedent for exactly this scenario (Long Chains Only precedent), dropping the "defer to implementation" hedge; #3 replaced the invented "tier 45" with a requirement to derive and prove the real ceiling from `kMaxDrops`/`dropCap`/`kCellCount`/chain-length limits, pinned with a doc-comment derivation and an invariant test; #4 made the floor-log2 technique choice conditional on that proven bound — `Math.clz32` only if confirmed under 2^31, otherwise a non-32-bit-limited technique; #5 added the `upsert_best_score`-already-exists correction and the `leaderboard()`/friends-leaderboard RPC return-type fallout as an explicit sub-step (7a); #6 required the exact existing security contract be re-asserted verbatim on recreation; #7 and #8 corrected the adjacency call-site map to the real function names/structure (2 independent scans per language, 5 call sites total including UI) and narrowed the "fossil" claim to `GameEngine.canMerge` only; #9 added server-side structured rejection logging as a distinct requirement from client analytics; #10 added an explicit full-verification step (analyzer + full test suite + both vector suites + deno).

**Incorporated with a partial rejection (#2):** language sharpened to explicitly say the rollout window is *not* fully bounded for never-updating clients (accepting the substance of the pushback), but the proposed fix — building dual-verifier routing or minimum-client-version enforcement — is rejected as new scope: no such mechanism exists anywhere in this codebase today, every prior gameplay-rule change here has shipped with only a `kLeaderboardSeason` bump per `CLAUDE.md`, and the user never asked for rollout infrastructure. Documented as an honest, accepted limitation rather than solved.

**Rejected:** none outright — #2 was partially accepted (language) and partially rejected (proposed mechanism), with reasoning recorded above.

## Round 3 — Codex (same thread, resumed)
Confirmed the rollout partial rejection as reasonable, citing actual repo precedent (`docs/superpowers/specs/2026-07-24-long-chains-only-deadlock-fix-design.md:119`) — would not block on it. Most prior findings otherwise addressed. Seven new:

1. **Proposed bound derivation used two false premises.** `kCellCount == 25` isn't a real upper bound (Easy has 64 cells, `difficulty.dart:6`); `kMaxDrops == 39` isn't a real drop ceiling (refill is explicitly unbounded per `daily_seeder.dart:190`'s own comment).
2. **The correct conservative bound can be resolved now.** Derived: 62 non-wall Easy cells, 39 max moves, ≤61 refill drops/move, max drop value 64 → total mass ≤152,416 → tier ≤17. Pin it now, don't defer.
3. **Plan still contained rejected "tier 45" language** in two places, plus an incorrect "Dart arbitrary-precision int" claim, plus an unsupported "safe through n=53" leap for accumulated scores.
4. **bigint migration still misses period-RPC fallout** — `leaderboard_period`/friends-period already declare `total bigint`, but `sum(bigint)` returns `numeric`, a type mismatch without an explicit cast.
5. **Migration should recreate from *current* RPC definitions**, not `0001`-era ones — current `leaderboard()` is `0010`'s bounded `security definer` version, friends-leaderboard is `0013`'s `player_id`-inclusive version.
6. **Rollout wording internally inconsistent** — Approach step 11 said "not actually bounded" but Out of Scope still said "bounded-window tradeoff."
7. **Server logging promised an app-build dimension the client never sends** (`leaderboard_service.dart:77` — payload has no build field).

VERDICT: REVISE

### Claude's response
Verified before accepting, since two of these directly contradicted numbers I'd put in the plan: read `difficulty.dart` in full (confirms #1 — `Difficulty.easy` is `gridSize: 8` → 64 cells, not `kCellCount`'s 25; `kCellCount`/`kGridSize` are unused-for-this-purpose legacy constants) and `daily_seeder.dart:186-196` (confirms #1's second half — `dropTierPrng()`'s own doc comment says refills are "decoupled from board placement so refills can be unbounded"). Re-derived the mass bound myself from verified constants before accepting #2's specific numbers rather than trusting them blind: `wallCountFor(easy)=2` → 62 non-wall cells; `kMovesPerDay(30) + kMaxAdContinuesPerDay(3)×kAdMoveReward(3) = 39` max moves; each move refills at most 61 cells (62 minus the surviving endpoint); `dropCap` saturates at value 64; initial mass `40×4=160` (Easy `startingFill` × `dropCap(0)`-derived max value 4) — independently arrived at the same `39×61×64+160=152,416`, `floor(log2(152416))=17` result. Read `0010_leaderboard_read_rpcs.sql:40-64` (confirms #4 and #5 — `leaderboard_period` already declares `total bigint` over a `sum()`, and the live `leaderboard()`/period definitions are `0010`'s, not `0001`'s) and `leaderboard_service.dart:60-84` (confirms #7 — the `submitRun` payload sends only `date`/`difficulty`/`moveLog`/`season`, no build identifier).

**Incorporated (all 7):** #1/#2 replaced the "derive during implementation" hedge with the actual verified derivation, pinning tier 17 as a named constant with its full derivation as a doc comment, and resolving the previously-conditional `Math.clz32` question (safe, now that 17 is proven under 2^31); #3 purged every remaining "tier 45" reference, corrected the Dart-int factual error (fixed 64-bit, not arbitrary precision), and replaced the unsupported "safe through n=53" framing with a concrete magnitude comparison (cumulative day score plausibly in the low billions — exceeds `int4`, comfortably fits `bigint`); #4/#5 rewrote the RPC-fallout sub-step (7a) to cover four functions (not two), require recreating from each one's *current* migration-latest definition with every existing clause preserved, and add the `sum(s.score)::bigint` cast for both period RPCs; #6 fixed the remaining "bounded-window tradeoff" phrase in Out of Scope to match step 11's "not fully bounded" language; #7 removed the app-build logging dimension, scoped server-side logging to season/rejection-stage/difficulty (what's actually sent today), and noted build-identifier plumbing as a separate out-of-scope addition.

**Rejected:** none — every finding was code-grounded and material; the rollout partial-rejection from Round 2 was itself independently confirmed reasonable by the reviewer this round, not walked back.

## Round 4 — Codex (same thread, resumed)
Confirmed: rollout rejection reasonable/consistent with precedent; numeric, snapshot, migration-definition, observability, and wording findings substantially addressed. Five new:

1. **The scoring fix would bypass Combo Rush.** `comboScore()` hardcodes the default `comboMultiplier`, but `collapseChain` deliberately uses an overridable `comboMultiplierFn` for the Combo Rush rule (`game_engine.dart:230` vs `:264`) — routing through `comboScore()` as instructed would silently break Combo Rush scoring.
2. **The migration affects five functions, not four** — plan correctly listed `upsert_best_score` + two daily RPCs + two period RPCs but kept calling it four.
3. **The existing SQL smoke suite will break, and wasn't in verification scope.** It hardcodes the old `integer` signature in a `has_function_privilege` check and has no assertion above `int4`'s range (`supabase/tests/leaderboard_smoke.sql:263,314`).
4. **Tier 17 is a physical invariant, not a new legality cap** — enforcing it in `isValidChain` would contradict step 6's "every structurally valid chain always collapses" claim.
5. **Doc sweep still leaves false domain contracts** — `Tile`/`TileGlyph`/`constants.dart:9` all describe `kMaxTier` as the live-tile ceiling; `kMaxDrops`'s own comment still wrongly claims to bound all daily drops.

VERDICT: REVISE

### Claude's response
Verified before accepting, since #1 meant a previous round's own "fix" was itself wrong: read `game_engine.dart:228-271` directly — confirmed `collapseChain` never calls the standalone `comboScore()` helper at all; it inlines the same formula with an overridable `fn = comboMultiplierFn ?? comboMultiplier` (line 264), so instructing a caller to invoke `comboScore()` (which only ever uses the default multiplier) would genuinely have broken Combo Rush. Read `leaderboard_smoke.sql:255-325` (confirms #3 — a literal old-signature string in a `has_function_privilege` check, no above-`int4` assertion). Grepped for `create function` in `0013`/`0010` (confirms #2 and named all five: `upsert_best_score`, `leaderboard`, `leaderboard_period`, `friends_leaderboard`, `friends_leaderboard_period`; also found `my_daily_ranks`/`my_period_ranks` as adjacent functions to verify, not assumed safe). Read `tile.dart` in full (confirms #5 — `Tile.value => 1 << tier` with a doc comment claiming `tier` is `1..kMaxTier`).

**Incorporated (all 5):** #1 replaced the `comboScore()`-based fix with the correct one — modify `collapseChain`'s own inline formula directly (`resultTier` replaces `mergedTier + 1` for both the placed tile and the score exponent `1 << resultTier`), leaving `* fn(path.length) + ascendTotal` untouched so `comboMultiplierFn`/Combo Rush keeps working unmodified; added a paired regression test (default multiplier + Combo Rush) rather than one; #2 corrected the count to five and named all five explicitly, plus flagged `my_daily_ranks`/`my_period_ranks` as needing verification rather than assumed-safe; #3 added the SQL smoke suite as an explicit required update (signature string, an above-`int4` assertion) and verification step, run after `supabase db reset`; #4 added an explicit statement that tier 17 must never be wired into `isValidChain`/`collapseChain` as a runtime rejection condition — only for type-sizing, floor-log2 technique choice, and a seeded-generation-specific debug/test invariant; #5 broadened the documentation sweep to `Tile`/`TileGlyph`/`constants.dart:9`'s `kMaxTier` comment and flagged (and included fixing) the pre-existing, independently-wrong `kMaxDrops` doc comment surfaced by this plan's own derivation.

**Rejected:** none — every finding was code-grounded and material.

## Round 5 — Codex (same thread, resumed) — MAX_ROUNDS reached
Confirmed addressed: migration, SQL verification, Combo Rush formula fix, snapshot invalidation, derived bound, documentation, accepted rollout tradeoff. Three new (final round per MAX_ROUNDS=5):

1. **Two stale remnants of the rejected `comboScore(resultTier - 1)` approach survived Round 4's edit** — step 12 (Dart test-suite description) and the Key Decisions bullet still referenced it, contradicting step 5's actual (corrected) fix.
2. **`Math.clz32` conflicts with the plan's own "constructed boards may exceed tier 17" allowance** — silently wrong for any input ≥2^32, so it can't be declared safe just because *real seeded gameplay* stays under it.
3. **`comboScore()` becomes a dead, misleading helper** post-fix — confirmed via repo search to have no production callers in either language.

VERDICT: REVISE

### Claude's response
Verified before accepting: grepped `resultTier - 1`/`comboScore(2, 4)` directly in the plan file (confirms #1 — two literal leftover references in step 12 and Key Decisions); grepped `comboScore` across `lib/` (zero hits besides its own definition) and `supabase/functions/_shared/` (confirms #3 — `engine.ts:99`'s export used only in `engine.test.ts`, multiple assertion call sites there).

**Incorporated (all 3):** #1 fixed both stale references to describe `collapseChain`'s actual corrected inline formula; #2 replaced the `Math.clz32`-based approach with a caller-agnostic integer-division loop for TS `mergedTierFromSum`, so the helper stays correct for any input including deliberately-constructed test boards exceeding the seeded-gameplay bound, not just real gameplay; #3 added explicit deletion of `comboScore()` (Dart) and its TS mirror/export, plus their dedicated unit tests, with the many other test assertions that used it as an "expected score" shorthand rewritten to compute the value directly against `collapseChain`'s real formula.

**Rejected:** none.

## Resolution — MAX_ROUNDS reached without a formal APPROVED (skill rule: not faked as convergence)
Five rounds, every one substantive, none rejected outright — several partial-accepts with recorded reasoning (Round 2/3's rollout-window pushback: language sharpened, proposed new infrastructure rejected as out-of-scope, independently reconfirmed reasonable by the reviewer in Round 3). The plan changed substantially and for the better: the scoring fix alone was redesigned twice (first an off-by-2× bug caught in Round 1, then Round 4 caught that the *fix* itself would have silently broken Combo Rush by routing through the wrong function) — each round's own correction introduced a new, real, verified bug the previous round hadn't surfaced, the same trajectory noted as a strong argument for not skipping this act in the earlier (parked) leaderboard/invite plan's review log. Two of the plan's original scope claims were flatly wrong and caught only by direct code-reading, not intuition: "board generation is out of scope" (false — the seeder's re-roll loop shares the exact predicate being changed) and the initial "tier 45" ceiling (unfounded guess; replaced with a derived-and-independently-reverified tier 17 from real game constants).

Round 5's three findings are incorporated into `PLAN-diagonal-merge.md` above. No 6th round was run — `MAX_ROUNDS=5` is a hard cap per the skill, exhausted by this round. The plan's remaining open items (Risks section) are genuinely open, not swept under: the exact `kSnapshotVersion` bump mechanics, `GameEngine.canMerge`'s fate, and the `BoardWidget` highlight needing only a confirming test (not new rendering) are all explicitly flagged as implementation-time work, not resolved here. Handing to the user for sign-off with that caveat stated plainly, per the skill's deadlock rule.

## Round 6 — Codex (same thread, resumed)
Confirmed prior substantive findings addressed (scoring fix, comboScore removal, TS floor-log2). Four new — all internal-consistency leftovers from earlier rounds' edits, not new design issues:

1. **Two spots still endorsed `clz32`/leading-zero arithmetic**, contradicting the integer-division-loop mandate from Round 5's own fix: the Approach step 4 helper description ("bit-length/leading-zero-count arithmetic") and a stale Risks bullet ("`Math.clz32` is confirmed safe in TS") that Round 5's `Math.clz32` reversal never propagated to.
2. **Goal paragraph says `comboScore` is "preserved"** while Approach step 5 and Key Decisions both delete it — the *formula* is preserved (inlined), the named helper is not.
3. **`areOrthogonallyAdjacent` never gets renamed** despite becoming 8-directional — a false, misleading name left in both engines and their call sites.
4. **"Safety ceiling... is required" wording (Key Decisions) reads as a runtime-enforced cap**, conflicting with Approach step 7's explicit rule that tier 17 is never wired into `isValidChain`/`collapseChain` as a legality check.

VERDICT: REVISE

### Claude's response
Verified each directly against PLAN.md before accepting: grepped `clz32|leading-zero|bit-length` (confirmed #1 — step 4 said "bit-length/leading-zero-count," the Risks bullet still said "Math.clz32 is confirmed safe," both contradicting step 7's actual `Math.clz32`-rejection); grepped `comboScore` (confirmed #2 — Goal literally names `comboScore` as preserved, while step 5/Key Decisions delete it); grepped `areOrthogonallyAdjacent` (confirmed #3 — named in step 1 and step 15, never renamed despite the geometry change); grepped `safety ceiling` (confirmed #4 — Key Decisions bullet's "is required" phrasing, unqualified, next to step 7's "never wired in as a cap" rule).

**Incorporated (all 4):** #1 reworded step 4 to say Dart may use `bitLength`-based arithmetic (safe at 64-bit) while TS must use the integer-division loop, and fixed the stale Risks bullet to reference the actual adopted TS technique; #2 reworded the Goal paragraph to name the preserved *formula* (`2^tier × length-multiplier + ascendBonus`) plus `ascendBonus`, not the deleted `comboScore` helper by name; #3 added an explicit rename instruction (`areOrthogonallyAdjacent` → `areAdjacent`, Dart + TS, all call sites) to step 1, and updated step 15's reference to match; #4 reworded the Key Decisions bullet to "derived production bound... required for numeric type sizing and test assertions (not runtime enforcement)" and cross-referenced step 7's prohibition explicitly.

**Rejected:** none — all four were real, code-grounded (well, plan-text-grounded) internal contradictions.

## Round 7 — Codex (same thread, resumed)
Confirmed all four Round 6 findings addressed. Two new — both material, not wording:

1. **Season isolation isn't actually enforced.** The client already sends `season` in the submit-score body (`leaderboard_service.dart:104`), but `validate_request.ts` discards it and `index.ts` always stamps the server's own current `kLeaderboardSeason` when writing. PLAN.md:34 (step 11) assumed a stale client's move log gets cleanly `rejected`, but nothing actually validates the client's claimed season — a stale log that happens to replay cleanly (not guaranteed to fail, only likely to) would silently land in the new season under a server-recomputed score.
2. **Rejection-stage logging (step 20) isn't implementable as scoped.** Every failure branch in `verifyRun`/`verifyRunChallenge` returns the same shared `REJECT` singleton — `index.ts` has no signal to log *which* check failed.

VERDICT: REVISE

### Claude's response
Verified both directly: read `leaderboard_service.dart:104` (confirms the client already sends `'season': kLeaderboardSeason` in the request body) and `validate_request.ts` in full (confirms it never reads `season` at all — only `date`/`difficulty`/`moveLog`); grepped `REJECT` in `engine.ts` (confirms ~14 `return REJECT` sites across `verifyRun`/`verifyRunChallenge`, all returning the identical singleton with no distinguishing field).

**Incorporated (both):** #1 added step 10a requiring `validateSubmitRequest` to explicitly check the client-supplied `season` against `kLeaderboardSeason` and reject a mismatch as a new `stale_season` reason, before replay runs — explicit defense-in-depth rather than relying on replay divergence as an accidental filter; softened step 11's "rejected as invalid_run" claim into "with step 10a's explicit check, this is now a deterministic rejection" rather than an assumed one. #2 added step 20a requiring `verifyRun`/`verifyRunChallenge` to carry an internal (never client-facing) rejection-stage tag replacing the shared `REJECT` singleton, so `index.ts` can log which check failed while the external response contract (`{valid:false, reason:"invalid_run"}`) stays unchanged; noted this is TS-only with no Dart-mirror obligation, since the Dart engine has no replay-verifier counterpart.

**Rejected:** none — both were real, code-grounded gaps in the season-isolation and observability mechanisms this plan itself introduces/relies on.

## Round 8 — Codex (same thread, resumed)
Confirmed both Round 7 findings addressed. One new — a real bug in Round 7's own fix:

1. **Step 10a's new `stale_season` reason breaks client retry semantics.** `GameSessionFactory._submitRun` (`game_session_factory.dart:70`) maps only `reason == 'invalid_run'` to `SubmitOutcome.terminalRejection`; every other reason falls through to `retryableFailure`. A stale client — exactly the client that would receive `stale_season` — can never learn the new classification (it would need an app update to know about it) and would retry indefinitely on every resume. Fix: log `stale_season` internally only; return the existing `invalid_run` reason externally.

VERDICT: REVISE

### Claude's response
Verified directly: read `game_session_factory.dart:58-73` — confirmed `_submitRun` treats literally only the string `'invalid_run'` as terminal; any other reason (including a hypothetical `stale_season`) becomes `retryableFailure`, and a stale client's `kLeaderboardSeason` build-time constant can never self-correct without an update, so this would have been a genuine infinite-retry bug shipped by my own Round 7 fix.

**Incorporated:** rewrote step 10a so the season-mismatch rejection returns the existing `invalid_run` reason externally (unchanged client contract, correct terminal-rejection handling) and is tagged `stale_season` only in the internal server-side logging added by step 20a; updated step 20a to include this pre-replay `validate_request.ts` code path in its internal-stage taxonomy (a separate path from the `REJECT`-singleton replay failures, logged through the same mechanism); corrected step 11's language, which had prematurely described `stale_season` as an externally-visible, client-parseable rejection.

**Rejected:** none — Codex caught a real regression introduced by my own prior round's fix, not a pre-existing plan gap.

## Round 9 — Codex (same thread, resumed)
Confirmed the stale-client retry fix addressed. No new material problems. Two editorial cross-reference fixes:

1. Step 7b points its "run after `supabase db reset`" verification note at step 20, but full verification is step 21 (step 20 is Analytics/observability).
2. The Risks section's server-side-logging bullet points at step 19 (Documentation sweep, wrong) and mentions a `rule` dimension that step 20's actual text never defines.

VERDICT: APPROVED

### Claude's response
Verified both directly: step 7b's stale reference (confirmed step 20 is Analytics, step 21 is Full verification) and the Risks bullet's stale reference (confirmed step 19 is the Documentation sweep, not logging; confirmed step 20's actual scope is "rejection stage, supplied season, and difficulty" — no `rule` dimension exists anywhere else in the plan).

**Incorporated (both):** fixed step 7b's cross-reference to step 21; fixed the Risks bullet's cross-reference to step 20/20a and dropped the undefined `rule` dimension to match step 20's actual scope (season/difficulty/rejection-stage).

**Rejected:** none.

## Resolution — VERDICT: APPROVED (Round 9)
Nine rounds total (5 in the original grill session, 4 more in this continuation at the user's request to keep reviewing rather than move to build). Every round's findings were code-grounded and material or, in the final two rounds, genuine editorial cross-reference cleanup. Two rounds (7-8) surfaced a real chain of bugs in the plan's own season-isolation and observability additions: Round 7 found season validation was entirely absent (client sends it, server discards it); the first fix (Round 7's own edit) introduced a new client-visible `stale_season` reason string that Round 8 caught as breaking `GameSessionFactory`'s terminal-vs-retryable classification for exactly the stale clients it was meant to reject — the same "each round's fix introduces a new verified bug" trajectory noted in the original 5-round log for the scoring formula. Codex confirms no material problems remain. Plan is locked and approved; ready for Act 3 (build) sign-off with the user.
