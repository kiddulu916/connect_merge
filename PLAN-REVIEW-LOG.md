# Plan Review Log: Fix "Long Chains Only" Challenge soft-lock
Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.
Reviewer model: gpt-5.6-sol (config-pinned, reasoning effort high) — codex-cli 0.144.4.

## Round 1 — Codex
Thread: 019f95e0-1811-7ff0-9af9-9eccb14e9d22

1. Default `minChainLength` of 1 makes the search vacuously false for any board with a tile, breaking deadlock detection for every other rule/difficulty.
2. `_finishRun`'s terminal check (`game_cubit.dart:404-406`) still uses the raw rule-unaware `hasMergeAvailable`, can withhold submission incorrectly.
3. `canOfferAd` permits Challenge continues client-side while `verifyRunChallenge` rejects every `ContinueEvent` server-side — pre-existing cross-check mismatch.
4. Existing snapshots become unverifiable; plan doesn't bump `kSnapshotVersion`.
5. Season bump doesn't solve rollout compatibility (client/server deploy-order mismatch during rollout).
6. TS ownership: `engine.ts` imports `seeder.ts`; putting the new chain-search in `engine.ts` and calling it from `seeder.ts` creates an import cycle.
7. `kMaxDrops` (39) bounds `goldenDropIndices`; rule-aware refill may consume drops well past that index.
8. Proposed tests don't cover directionality, visited-state, tier-cap endpoints, standard-rule regression, or TS parity; existing Challenge tests may have vacuous assertions.
9. Golden-vector regeneration should be mandatory, not conditional, given the fill change.
10. No runtime tripwire/telemetry to distinguish rollout drift from cheating/malformed input in `submit-score`.
11. Repo's `CLAUDE.md` planning workflow requires a `docs/superpowers/` spec + task plan for nontrivial changes; this PLAN.md alone doesn't satisfy it.

VERDICT: REVISE

### Claude's response
Verified each against the actual code before deciding.

**Incorporated:**
- #1 — confirmed by reading `game_engine.dart`/`game_cubit.dart`: default changed to 2 (the existing baseline everywhere else), `longChainsOnly` overrides to 3, reject <2.
- #2 — confirmed at `game_cubit.dart:404-406`: the third OR-clause is indeed the raw rule-unaware predicate. Now threaded through the same rule-aware search.
- #3 — confirmed by reading `engine.ts:391-393` (blanket Challenge `ContinueEvent` rejection) and `game_cubit.dart:574-580` (`canOfferAd` is difficulty-unaware). This is a real pre-existing bug across all Challenge rules, not introduced by this plan, but fixing only the terminal-check (#2) without this would make the inconsistency worse specifically for `longChainsOnly`. Added: gate `canOfferAd` to false for `Difficulty.challenge` outright, matching the server exactly. Flagged in the plan as broader-than-`longChainsOnly` scope.
- #6 — confirmed via `grep '^import'` on both files: `engine.ts` imports `seeder.ts`; `constants.ts` has zero imports. Moved the TS chain-search to `constants.ts` (already the shared leaf module for `canFollow`/`pairMergeable`).
- #8, #9 — tightened the test list and made golden-vector regen non-conditional.
- #11 — added a step to produce the `docs/superpowers/` spec + plan before implementation.

**Rejected, with reasons:**
- #4 (bump `kSnapshotVersion`) — read `storage_service.dart:16-18`: that constant guards the local Hive snapshot *schema*, unrelated to server-side seed regeneration during a deploy window. Wrong mechanism for the actual risk.
- #5 (version replay rules / stamp submissions to a matching season) — real risk (confirmed: any `DailySeeder.generate()`/`seeder.ts` change has a deploy-ordering hazard), but the proposed fix is a new versioning subsystem, disproportionate to a one-rule bug fix. This repo's established mitigation is `kLeaderboardSeason` + deploying the edge function together with the client change (already documented in this session's memory as a recurring gotcha) — added as an explicit deploy-ordering step/risk instead of new infra.
- #7 (goldenDropIndices rework) — confirmed cosmetic-only (golden never affects score/replay on either side); a `longChainsOnly` run outrunning the 39-index golden precompute just means very late drops don't flash golden. Documented as an accepted, known ceiling rather than rearchitected.
- #10 (rejection telemetry) — legitimate but separate observability gap (ties to existing "GameCubit swallows submit result" gap), not required for this fix's correctness. Left as an out-of-scope follow-up.

## Round 2 — Codex
Same thread, resumed.

1. With `canOfferAd` now hard-`false` for Challenge, an out-of-moves Challenge board that still has a legal chain leaves `_finishRun.terminal == false` forever — none of the three OR-clauses fire, so `_submit` never runs.
2. `kSnapshotVersion` should still be bumped — an old-version Challenge snapshot resuming under new rules produces an unreplayable move log.
3. "Deploy together" isn't a real compatibility strategy given asynchronous app-store rollout; some legitimate clients will always be on the opposite ruleset from the server during rollout.
4. The full-board-deadlock risk has no planned measurement — add a deterministic multi-date sweep.
5. Minor: plan says boards are "at most 6x6," but Easy/Medium are 8x8/7x7.

VERDICT: REVISE

### Claude's response
Verified each against the actual code again.

**Incorporated:**
- #1 — confirmed: Challenge never grants continues once `canOfferAd` is hard-`false`, so `adContinuesUsed` never grows and the rule-aware predicate being `false` (a legal chain still exists) leaves nothing to make `terminal` true. Made `terminal` unconditionally `true` for `_difficulty == Difficulty.challenge` — Challenge has no continue path, so any non-`playing` status is terminal by construction.
- #2 — re-examined and reversed my round-1 rejection. Codex's stated mechanism (server can't replay it) is still wrong — the server never reads `kSnapshotVersion` — but traced a real, different bug: `_targetFill` is recomputed from the rule-fill switch on *every* `init()` regardless of whether the persisted snapshot's board is reused as-is (`game_cubit.dart:213-237` runs before the snapshot check). Once `longChainsOnly` gets a fill override, an old same-day snapshot would resume on an 8-fill board while `refill` targets 14 — an internally-inconsistent play history. Bumping `kSnapshotVersion` (its own doc comment: "starts the day fresh under current rules") is the correct, already-established tool for exactly this. Incorporated with the corrected reasoning, not Codex's.
- #4 — added a deterministic multi-date sweep test measuring actual full-board-deadlock rate instead of asserting it's rare by reasoning alone.
- #5 — confirmed via `difficulty.dart:6-10` (Easy 8x8, Medium 7x7, Hard/Legendary/Challenge 6x6). Corrected the chain-search description to work generically up to 8x8 since `GameEngine` is shared across all difficulties.

**Rejected, with reasons:**
- #3 — the underlying point (async rollout means "deploy together" is aspirational) is correct and now stated honestly in the plan rather than glossed over. But the proposed remedies (require no released clients exist, force a minimum client version, or version replay rules during migration) are new infrastructure this repo has never built for any prior gameplay change (ascending-chain-merge, golden vectors, etc.) — all of which carried the identical hazard and shipped on `kLeaderboardSeason` + prompt edge-function deploy alone. Holding this one PR to a higher bar than the repo's own precedent is disproportionate; noted as an accepted risk category with a minimum-version gate flagged as a legitimate but separate future initiative.

## Round 3 — Codex (failed run, not a plan defect)
Attempted to resume the same thread after incorporating all of Round 2's findings. The turn failed outright with `"You've hit your usage limit... try again at Jul 28th, 2026 6:04 PM."` — no critique was produced (the file at `/tmp/codex-verdict.txt` was stale output left over from Round 2, not a new response; discarded per the skill's rule to treat a failed run as failed, not to retry blind or fake a result). An unrelated Supabase-MCP auth warning appeared in the same stderr stream but is cosmetic (the terminating failure is the usage-limit error, confirmed by `"type":"turn.failed"`).

No further Codex rounds are possible until the quota resets. Round 2's four findings (terminal-check-for-Challenge, `kSnapshotVersion`, deploy-ordering honesty, full-board sweep test, 6x6→8x8 correction) were all incorporated into `PLAN.md` before this attempt — see the Round 2 response above — so the plan reflects everything Codex has flagged so far, but the loop cannot reach a third confirmed `APPROVED`/`REVISE` verdict right now. Per the skill's resolution rules, this is logged as an honest incomplete state, not a false convergence.

Confirmed the cap is account/plan-level, not model-specific: a throwaway one-off call with `-c model="o3"` returned `"The 'o3' model is not supported when using Codex with a ChatGPT account"` (400, not a usage-limit error) — and the original Round 3 failure already named a specific reset time and an "Upgrade to Pro" remedy, both account-level signals. No model swap works around it.

## Resolution
Two rounds of adversarial review completed and fully incorporated (not a false "approved," but not a raw unreviewed plan either — every finding from both completed rounds was independently verified against the actual code before being accepted or rejected). Round 3 is blocked externally until 2026-07-28, not by any known remaining defect. User decision: implement now per `PLAN.md`; a confirmatory Round 3 can still run later against the finished diff if desired.
