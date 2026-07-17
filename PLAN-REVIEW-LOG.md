# Plan Review Log: Deepen GameEngine (refill + canFollow)

Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.

(Candidate #1's log lives in git history at b06017f.)

Grill decisions: merge() removal DEFERRED to its own PR (26 test references + undo entanglement; MergeEvent/canMerge must survive for the golden-vector sentinel regardless) — this PR is refill + canFollow + grantAdReward guard only. Settled from code: tierAt-callback signature keeps GameEngine seeder-free; TS refillBoard stays private; golden flag is Dart-only by design; proof = committed fixture byte-identical under regeneration.

## Round 1 — Codex

1. "Single owner" claim false: canFollow would coexist with canMerge, Dart/TS pairMergeable, and seeder.ts's copy. Fix: route them all through canFollow; parity-test the unavoidable seeder mirror.
2. TS refill helper's terminal branch untested (no full-board deadlock vector in fixture). Fix: direct refillBoard tests mirroring Dart's.
3. Golden proof biased: generator still filters ascend-only boards via the stale _hasAdjacentSameTier workaround (drift was fixed in 69420db). Fix: remove filter, add ascend-only parity coverage.
4. "Proves every scored run" unsupported. Fix: call it regression evidence + branch-parity tests.
5. Ad guard test omits the no-merge-available predicate. Fix: test each predicate independently.
6. grantAdReward racy under concurrent reward callbacks. Fix: in-flight guard + concurrent test.
7. Deploy verification not executable (no command/owner/smoke/rollback). Fix: concrete checklist.
8. Repo requires the dated docs/superpowers task plan BEFORE implementation. Fix: write it first.

VERDICT: REVISE

### Claude's response

ACCEPTED all 8, two in modified form:
- #1 modified: TS canFollow + pairMergeable move to constants.ts (rule functions already live there) — the only placement seeder.ts can share without an import cycle, physically de-duplicating the exact predicate that drifted in prod. Dart routes canMerge/pairMergeable/isValidChain/widget through GameEngine.canFollow.
- #2: refillBoard EXPORTED (reversing the grill's "private" lean) for direct unit tests mirroring the Dart refill vectors.
- #3 modified into a two-phase structure: Phase A pure refactor with byte-identical fixture (the proof), Phase B separate commit removing the stale workaround + UPDATE_GOLDENS_FORCE regeneration (vectors legitimately change — wallMaze back to 2026-07-17, ascend-only boards now reachable). Collapsing the phases would destroy the proof.
- #4: proof language reworded to regression evidence + branch-parity unit tests.
- #5: four independent no-op guard tests incl. no-merge-available.
- #6: _grantingAd in-flight flag with try/finally + concurrent-double-call test; guard added to grantAdReward only (SDK-driven), no speculative reentrancy elsewhere.
- #7: concrete release checklist (deploy command, project, owner, bundle-content verification via mcp get_edge_function, rollback path).
- #8: dated docs/superpowers spec + TDD task plan written first, before production tasks.

## Round 2 — Codex

1. Ascend-only coverage still optional in Phase B ("may include"). Fix: require a named vector whose start board has an ascend pair but no same-tier pair.
2. Deploy/rollback commands don't bind the project. Fix: --project-ref on every command.
3. Bundle verification checks source, not runtime. Fix: authenticated production smoke invocation.
4. Proposed seeder parity test has no accessible seam (hasAdjacentMergeablePair private). Fix: export it, or shared-predicate cases + guaranteed ascend-only vector.
5. pairMergeable's constants.ts signature unspecified — Tile params would reintroduce the engine dependency. Fix: tier-number params.

VERDICT: REVISE

### Claude's response

ACCEPTED #1, #2, #4 (alternative branch), #5; #3 PARTIALLY:
- #1: generator now ASSERTS ≥1 vector's initial board is ascend-only (fails loudly otherwise); 2026-07-17 challenge is known to satisfy it.
- #2: --project-ref nnoqqchqprfikhabrrjt added to deploy and rollback commands.
- #3 partial: boot smoke added (unauthenticated POST must 401, not 5xx — proves bundle imports and serves). Full authenticated replay smoke REJECTED for this PR: needs a real user JWT plus a current-day legal run; logic verification is carried by the Deno suite. Logged as a known, accepted gap.
- #4: took Codex's alternative — hasAdjacentMergeablePair stays private; parity carried by shared-predicate unit cases + the now-required ascend-only vector; unimplementable constructed-board comparison dropped.
- #5: canFollow(prevTier, nextTier) / pairMergeable(aTier, bTier) — numbers only, constants.ts stays dependency-free; Dart's private pair check mirrors the tier-based shape.

## Round 3 — Codex

1. 401 smoke proves only the gateway (verify_jwt rejects before invocation). Fix: authenticated malformed request → function-generated 422.
2. MCP bundle verification lacks explicit project_id/function_slug args.

VERDICT: REVISE

### Claude's response

ACCEPTED both, #1 in modified form: the anon key is itself a valid JWT, so Bearer <anon key> passes the verify_jwt gateway and reaches function code, where auth.getUser() fails — the smoke now requires the function's OWN body {"error":"unauthorized"} (not a gateway error shape, not 5xx), which is function-generated proof the bundle imports and serves, without needing a user JWT for a 422. #2: MCP call fully specified with project_id + function_slug.

## Round 4 — Codex

The smoke request still uses the wrong credential type: the repo defaults to an sb_publishable_ key (supabase_client.dart:17), which is not a JWT and is rejected before function execution when sent as Bearer. Fix: test-user JWT in Authorization, publishable key in apikey, malformed JSON → require function-generated 422.

VERDICT: REVISE

### Claude's response

ACCEPTED — and made it self-contained instead of requiring a stored test account: config.toml has signup enabled with email confirmations off, so the smoke (a) mints a throwaway user via POST /auth/v1/signup with the publishable apikey (returns access_token immediately), (b) POSTs a malformed body to submit-score with that Bearer token → requires the function-generated 422 {"valid":false,"reason":"invalid_run"}, (c) cleans up via the repo's own delete-account function with the same JWT. If prod signup settings diverge, the smoke fails loudly at step (a).

## Round 5 — Codex

Minor release caveat: delete-account (index.ts:72) ignores deletion errors, so smoke cleanup can silently leave a throwaway user. Fix: verify the user no longer exists; treat failure as a release-check failure.

VERDICT: APPROVED

### Claude's response

Accepted: smoke now verifies deletion by requiring a repeat sign-in with the same credentials to fail; a surviving throwaway user is a release-check failure. Plan converged in 5 rounds.

## Act 3 — Build

### Round 1 — Codex build

Codex (gpt-5.6-sol, thread 019f6cb6-6fcb-74a0-a028-76556227e968, ~22 min, both phases): canFollow single-sourced (Dart GameEngine; TS constants.ts shared by engine.ts + seeder.ts), refill moved into GameEngine / exported refillBoard replacing both TS inline copies, grantAdReward canOfferAd + in-flight guards, docs-first TDD plan under docs/superpowers/, Phase A proof gate captured (fixture regen EXIT=0, byte-identical) BEFORE Phase B (stale filter removed, ascend-only requirement enforced, force regeneration — wallMaze back to 2026-07-17). NO git mutations this time. Reported deviations: none.

### Claude's verdict

Verified independently:
- Full diff read: every routing is expression-equivalent (canFollow(lower,higher) ⇔ |Δ|≤1 in _pairMergeable; canMerge/isValidChain/widget/TS mirrors exact); both TS inline refill copies deleted; changed files exactly match the contract's allowed set; prng.ts/index.ts/golden_vectors.test.ts untouched.
- flutter analyze clean; flutter test 503/503; deno test --frozen 45/45.
- Fixture regeneration deterministic (identical SHA-256 across repeated regens: 00D54BDD...4DCD) and assert-mode green; the 120-line fixture diff vs HEAD is Phase B's intended change (wallMaze 2026-08-02 → 2026-07-17, ascend-only start now covered).
- Phase A's byte-identical gate was captured in Codex's report before Phase B; post-hoc parity carried by the regenerated fixture passing both suites + the new branch-parity unit tests.

Build ACCEPTED, round 1, no fix rounds used. Held for human gate.

### Post-gate execution (user approved commit + push + deploy + smoke)

- f58f7b0 (Phase A): refactor landed — canFollow + refill/refillBoard single-sourced, grantAdReward guards; fixture byte-identical under regeneration on this commit.
- 2f550e9 (Phase B): stale generator workaround removed, ascend-only coverage now REQUIRED, fixture force-regenerated (wallMaze → 2026-07-17).
- Pushed; CI run 29594974425 SUCCESS (1m28s) — Flutter + Deno both green as required checks.
- submit-score deployed with --project-ref (now version 8); bundle contents verified via get_edge_function (refillBoard in engine.ts, canFollow/pairMergeable in constants.ts, seeder using shared predicate).
- Runtime smoke passed end-to-end: throwaway signup → function-generated 422 {"valid":false,"reason":"invalid_run"} on malformed body → delete-account {"ok":true} → deletion verified (re-sign-in rejected). No stored secrets, no residue.
