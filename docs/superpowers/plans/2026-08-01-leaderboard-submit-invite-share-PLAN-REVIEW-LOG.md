# Plan Review Log: Leaderboard silent-submit-failure fix + invite/share flow repair
Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.

Note: PLAN.md/PLAN-REVIEW-LOG.md previously held an unrelated, already-APPROVED,
uncommitted release-build smoke-test plan (Google login + ads). Confirmed stale/done
with the user and backed up to the session scratchpad before being overwritten by
this task's plan.

Reviewer model: gpt-5.6-sol (config-pinned) — codex-cli 0.144.4.

## Round 1 — Codex
Thread: 019fba62-076a-7762-82da-489f3902d98d

1. **Resume can submit a nonterminal board.** `snap.completed` is true whenever `board.status != playing`, which includes "out of moves but an ad continue still offerable" — resuming there and submitting early races the real post-continue submission.
2. **Concurrency race.** Fire-and-forget resume submission and `submitIfPending()` could both pass the `_submitted == false` check and invoke the hook concurrently.
3. **Server "keep best" is not atomic.** `submit-score/index.ts` reads-then-upserts; concurrent submissions can let a lower score overwrite a higher one. Plan incorrectly declared this "confirmed correct."
4. **Future completion treated as authoritative success.** `SubmitRun` returns `Future<void>` and `game_session_factory.dart` discards `SubmitResult.valid`; a normally-returned 422 rejection would still set `_submitted = true` under the proposed fix.
5. **Promised durable retry doesn't actually exist across UTC rollover** — resume only reloads today's snapshot, and the server rejects backfilled dates.
6. **`EXTRA_TEXT` doesn't guarantee Facebook actually publishes/displays the link** — composer may ignore accompanying text on an image `ACTION_SEND`.
7. **iOS handoff incomplete** — hosting AASA isn't sufficient; this repo has no Associated Domains entitlement at all.
8. **Caption contract ignores unavailable friend codes** — `_ensureFriendCode()` can return null; `inviteMessage` requires a code.
9. **Removing the Google gate affects more than `_isReady`** — it's a constructor dependency wired from `main.dart` and existing tests/harnesses.
10. **Silent submissions remain unobservable** — no attempt/success/rejection telemetry to notice a recurrence in production.

VERDICT: REVISE

### Claude's response
Verified every finding against actual code before deciding (not taken on faith):
- #1 confirmed by reading `game_cubit.dart:361` (`done = status != playing`) vs. the stricter `terminal` predicate at `:423-426` — these are genuinely different conditions and the plan's original wording conflated them.
- #4 confirmed decisively via `test/infrastructure/leaderboard_service_test.dart:48-61` ("maps a rejected (invalid) run response") — proves a 422 returns `SubmitResult(valid:false)` without throwing in this codebase's actual design, which invalidates the original plan's core throw-based retry mechanism for exactly the case it was meant to fix.
- #8 confirmed via `score_share_screen.dart:376-387` — `_textSummary()` already exists and is already null-safe; the fix is to plumb that existing helper through, not to build new null-handling.
- #3, #5, #7, #9 confirmed by reading the cited files directly.

**Incorporated (9 of 10):** #1 resume-retry now gates on the same `terminal` predicate as `_finishRun`, not raw `snap.completed`; #2 added a coalescing in-flight `Future<SubmitResult>?` in `_submit`; #3 added `upsert_best_score` as a new atomic-RPC migration + edge-function change + redeploy step, flagged prominently as a scope increase; #4 `SubmitRun`/`SubmitResult` now thread the real outcome through (`reason` field added), with three-way branching (success / transient-retryable / terminal-but-reported); #5 documented the UTC-rollover retry-window limit explicitly rather than implying unbounded durability, and explicitly rejected building cross-day persistence since the server would reject it anyway; #6 added a real-device verification acceptance criterion beyond the seam test; #7 sharpened Out-of-scope to name the missing iOS entitlement explicitly, separate from the website AASA-hosting spec; #8 wired the existing null-safe `_textSummary()` through instead of a raw `inviteMessage()` call; #9 broadened the RedeemCoordinator task to include its call site and existing tests, not just the internal gate.

**Incorporated as documentation only (not code):** #10 — added `score_submit_attempt`/`score_submit_result` analytics events via the already-existing `onAnalyticsEvent` hook (cheap, reuses existing plumbing per the repo's own pattern for `run_completed`).

**Rejected:** none — every finding was code-grounded and material; all 10 acted on in some form.

## Round 2 — Codex (same thread, resumed)
Most Round 1 findings addressed; several material gaps remained:

1. **Submission state still not persisted/payload-aware.** A failed main-menu submission from a continue-eligible board is skipped by the Round-1 terminal-only resume check (`submitIfPending()` has no terminal gate by design), while `_submitted` is memory-only so nothing survives a fresh cubit anyway.
2. **Atomic-upsert SQL mishandles seasons.** The proposed `ON CONFLICT (player_id, utc_date, difficulty)` omits `season`, matching the *current* under-scoped unique constraint — an old-season row would conflict and the update would leave its old season, making the new score invisible.
3. **New RPC lacks an explicit security contract.** Accepts arbitrary `p_player_id`; default grants or `SECURITY DEFINER` would expose a score-forging endpoint reachable by any authenticated client.
4. **Rejected responses not exhaustively handled.** `valid == false` with an unknown/null `reason` is possible (the production wrapper returns `{'valid': false}` for a malformed response shape) but the plan only branched on two known reason strings.
5. **`SubmitResult` creates the wrong dependency direction.** Returning an infrastructure type from a `GameCubit` hook couples the application layer to `supabase_flutter`, breaking its plugin-free callback boundary.
6. **Facebook failure has no planned fallback.** The real-device check might reveal Facebook drops the caption even while reporting launch success (skipping the `shareToSheet` fallback entirely) — plan didn't say what ships in that case.
7. **iOS finding acknowledged but not resolved into an explicit scope boundary** — needed either the entitlement or an explicit Android-only narrowing.

Minor: boot method is `ensureSignedIn()`, not `ensureAnonymousSession()`; the cited seam test proves this app's own design contract, not the live Supabase SDK's actual HTTP 422 handling (branching on both thrown and returned-rejection is still the correct hedge either way).

VERDICT: REVISE

### Claude's response
Verified every finding against the actual code before deciding:
- #1 confirmed by re-reading `submitIfPending()` (`game_cubit.dart:562-565`) — genuinely has no terminal gate, confirming the scenario is real, not hypothetical.
- #2 confirmed against this session's own earlier research output (which had already flagged the season-less unique constraint as a latent bug) — the new RPC as drafted would have reproduced it verbatim.
- #5 and #7 confirmed by re-reading the relevant files; #4 confirmed via `leaderboard_service.dart:49-54`'s fallback-shape branch.

**Incorporated (all 7):** #1 added a persisted `GameSnapshot.submitAttempted` flag (bumps `kSnapshotVersion`) and replaced the single terminal-only resume gate with a three-way resume rule (already-attempted retries unconditionally; never-attempted-but-terminal retries; never-attempted-and-non-terminal stays silent); #2 widened the unique constraint to include `season` in the same migration, both matching the `ON CONFLICT` target; #3 added an explicit `SECURITY INVOKER` + revoke-from-`PUBLIC`/`anon`/`authenticated` + grant-only-`service_role` contract; #4 added an explicit default arm (unrecognized/missing reason → retryable, reported); #5 introduced an app-owned `SubmitOutcome` type, with `GameSessionFactory` doing the `SubmitResult`→`SubmitOutcome` mapping so `game_cubit.dart` stays infra-free; #6 predefined the fallback (drop the Facebook-targeted native intent, route through the already-proven OS share sheet) as a plan decision, not an open question; #7 the Goal statement now explicitly scopes "link opens app" acceptance to Android, with the iOS entitlement gap named as a specific Out-of-scope item.

**Also fixed:** the `ensureAnonymousSession`/`ensureSignedIn` naming error.

**Rejected:** none.

## Round 3 — Codex (same thread, resumed)
Layering, unknown-outcome handling, season-scoped conflict keys, RPC grants, Android scope, referral cleanup all confirmed addressed. Five remaining:

1. **`submitAttempted` (boolean) is insufficient.** Causes successful/terminally-rejected submissions to retry after every relaunch (can't distinguish "settled" from "needs retry"); offline exits may never get it persisted before the process dies.
2. **Bumping `kSnapshotVersion` would discard existing games fleet-wide at deploy** — `init()` rejects any version mismatch and silently regenerates a fresh board, erasing same-day progress and re-unlocking completed tiers.
3. **The in-flight future covers too little** — reusing it only around the hook call still lets two callers independently persist state and emit telemetry twice.
4. **Schema/Edge deployment isn't backward-compatible as ordered** — dropping the 3-column constraint before the new Edge Function deploys breaks the *currently deployed* function's `onConflict`; deploying Edge first calls an RPC that doesn't exist yet.
5. **The Facebook fallback may still fail** — an OS-sheet share with both image and text may drop the caption for the same reason the native intent did; the fallback needs a lighter option, not just a different Android API surface for the same payload shape.

Minor: seam test still doesn't prove real SDK HTTP-422 handling (acknowledged, unchanged — the branching already safely covers both cases either way).

VERDICT: REVISE

### Claude's response
Verified #2 specifically before accepting it, since it was the highest-severity claim (a plan meant to *fix* silent data loss almost *causing* a much bigger one): re-read `game_cubit.dart:250-252` and confirmed `init()`'s resume branch is gated on `snap.version == kSnapshotVersion`, with no fallback path — a mismatch falls through to "fresh day for this tier," discarding the existing board/completion entirely. Also verified `GameSnapshot.fromJson` (`lib/infrastructure/storage/game_snapshot.dart:32-39`) already uses the exact backward-compatible-optional-field pattern needed (`(j['v'] as int?) ?? 1`), confirming the fix is both correct and already idiomatic for this codebase.

**Incorporated (all 5):** #1 replaced the boolean with a persisted tri-state `submitStatus` (`none | pending | settled`) with a fully specified transition table; #2 dropped the `kSnapshotVersion` bump entirely, decoding the new field backward-compatibly instead (legacy/missing → `pending`, one safe retry sweep); #3 widened the in-flight coalescing to wrap the *entire* submission sequence (persist-pending → call → branch → persist-final → analytics), not just the hook call, so a second caller does nothing but await; #4 replaced the single-migration approach with an explicit 3-phase deploy (add new constraint+RPC alongside the old one → deploy+verify the edge function → only then drop the old constraint), so the live function is never pointed at a nonexistent constraint/RPC mid-rollout; #5 refined the Facebook fallback into a ladder (OS sheet with image+text, then text-only/copy-link if Facebook still drops the caption specifically), naming the real reason the first fallback might not be sufficient rather than assuming a different API surface alone fixes it.

**Rejected:** none.

## Round 4 — Codex (same thread, resumed)
Prior 5 confirmed sound (RPC security + phased rollout explicitly called out as good). Four new:

1. **Submission-status writes can overwrite a continued game.** A resumed `pending` retry resolving *after* `grantAdReward()` persists a newer playing board can write `settled` back onto the old completed board/move-log, clobbering the continued run.
2. **Legacy snapshots defaulting to `pending` force-finalizes undecided runs.** Every legacy continue-eligible completed board would auto-submit on first resume; the improved post-continue result would then be suppressed by the settled guard.
3. **Persisted status was never wired to the in-memory guard.** A resumed `settled` run could still reach `submitIfPending()` (guard starts `false` on a fresh cubit) and re-attempt a network call.
4. **Offline/no-hook path underspecified** — unless `pending` is persisted before any early return, an offline explicit exit might never become retryable on a later online relaunch.

VERDICT: REVISE

### Claude's response
#1 was the most serious finding of the whole review — a data-loss bug introduced by draft 2's own design (embedding submit status inside the mutable `GameSnapshot`), not a pre-existing issue. Verified by re-tracing the actual write paths: `_applyUndo` (`game_cubit.dart:511`) and the post-continue save both call `saveSnapshot` wholesale, which would race a background retry's completion write.

**Incorporated (all 4):** #1 moved submit status out of `GameSnapshot` entirely into its own `StorageService` entry (`loadSubmitStatus`/`saveSubmitStatus`, mirroring the existing `loadStats`/`saveStats` pattern) — decoupled from the board snapshot, so it structurally cannot race `saveSnapshot` calls elsewhere; #2 changed the missing/legacy default from `pending` to `none`, with the tradeoff made explicit (a genuine pre-release failed-finalize needs one manual Main Menu retry instead of an automatic one); #3 `init()`'s resume branch now seeds `_submitted` from the persisted status before emitting `GameOverShowScore`; #4 specified `_submit()`'s ordering explicitly — persist `pending` as the first side-effecting step, strictly before the network call, so a kill mid-attempt (including immediately after an offline exit) still leaves a retryable `pending` on disk.

**Rejected:** none.

## Round 5 — Codex (same thread, resumed) — MAX_ROUNDS reached
Prior 4 confirmed addressed. Three new (this is the 5th and final round per MAX_ROUNDS=5 — the loop terminates here regardless of verdict):

1. **Decoupled status still gets clobbered across a continuation.** A `pending` retry for the pre-continue board can resolve and write `settled` *after* the player has already continued to a better board under the same `(date, difficulty)` key, permanently suppressing the improved score's own submission.
2. **The new status key needs explicit account-scoping.** An old cubit's fire-and-forget completion could write `settled` after an account switch and suppress the new account's same-day tier; use the existing storage ownership guard (`_installKeys`) rather than inventing a new one.
3. **The RPC omits this repo's standard pinned `search_path`.** This repo already has a dedicated migration retrofitting this onto every function that lacked it after a Supabase advisor finding; a new function skipping it reopens that exact finding.

VERDICT: REVISE

### Claude's response
Verified #2 and #3 against actual code before accepting (not taken on faith, since #2 in particular cited a specific mechanism name that needed confirming): `HiveStorageService._installKeys` (`hive_storage_service.dart:25`) and `wipeAccountData()` (`:361-366`) exist exactly as described — an allowlist of keys that *survive* an account wipe, everything else deleted. `grep`-confirmed `set search_path = public` appears in every migration since a dedicated retrofit (`0005_pin_function_search_path.sql`), including every function added after it (`0006`, `0010`) — a real, consistently-enforced repo convention I should have applied to the new RPC without needing it pointed out.

**Incorporated (all 3):** #1 — the most severe finding of the whole review, a *new* lifecycle bug introduced by draft 3's own fix rather than a pre-existing one — closed with a generation-guarded write: `_submit()` captures the current `submitGeneration` at attempt-start (bumped every time a *new* terminal state is reached, including post-continue), and only applies/persists an outcome if that generation still matches at resolution; a superseded attempt's result is discarded, never written, so it cannot suppress a newer attempt's own submission. #2 the new key is simply excluded from `_installKeys` (the default/correct behavior — verified with an explicit account-switch test) rather than requiring new mechanism. #3 added `set search_path = public` to `upsert_best_score`, matching the existing convention exactly, plus a post-migration security-advisor check.

**Rejected:** none.

## Resolution — MAX_ROUNDS reached without APPROVED (deadlock, per skill: not faked as convergence)
Five rounds, every one substantive, none rejected — 27 distinct findings across five REVISE verdicts, each independently verified against the actual code before being accepted (constraint definitions, snapshot version-discard behavior, `_installKeys`, `search_path` convention, `_finishRun`'s terminal predicate, the leaderboard-service test suite's proof that a 422 doesn't throw). The plan changed substantially in response — most notably, the mechanism for retrying a failed score submission was redesigned four times (raw-throw guard → terminal-predicate resume check → boolean-flag-in-snapshot → tri-state-flag-in-snapshot → generation-guarded status in its own decoupled, account-scoped storage entry) as each draft's own fix revealed a new, real lifecycle bug the previous draft hadn't considered. That trajectory is itself the strongest argument for not skipping this act: several of the deepest bugs (the board-clobbering race, the cross-continuation suppression race, the version-bump fleet-wide-wipe risk) were not present in the original ask or the first draft — they were introduced by earlier fix attempts and only surfaces by continued adversarial pressure.

Round 5's three findings are incorporated into `PLAN.md` above (Claude is final arbiter; nothing here was rejected). No 6th round was run — `MAX_ROUNDS=5` is a hard cap per the skill, exhausted by this round. Whether the plan as it now stands is safe to build is **not re-verified by Codex past this point**; it reflects Claude's synthesis of five rounds of real findings, not a machine-confirmed "no more bugs." Handing to the user for sign-off with that caveat stated plainly, per the skill's deadlock rule (a flagged disagreement/uncertainty beats a false "approved").

## Act 3 — Build (Codex builds, Claude verifies)
Built in an isolated worktree (`.claude/worktrees/codex-build-leaderboard-invite`,
branch `fix/leaderboard-submit-invite-share`) since the primary working tree had
unrelated uncommitted release-prep changes (version bump, repo rename) that
needed to stay untouched and unmerged with this diff.

### Round 1 — Codex build
First launch hit the Bash tool's 10-minute foreground ceiling mid-build (real
progress, not a crash — Track A files were already correctly underway). Backgrounded
via shell job control (`nohup ... &`, disowned) and resumed with a fresh session
told to inspect `git status`/`git diff` first and continue rather than redo
completed work. Total build time ~18 minutes. Full report in
`/tmp/codex-build.txt` at build time; summary below.

Files changed: `game_cubit.dart` (outcome-aware retry, persisted tri-state
status, generation guard, coalescing, analytics), `game_session_factory.dart`
(SubmitResult→SubmitOutcome mapping), `storage_service.dart` +
`hive_storage_service.dart` (submit-status storage, account-scoped),
`leaderboard_service.dart` (reason parsing), `redeem_coordinator.dart` + `main.dart`
(guest install-referrer redemption, dead `hasGoogleIdentity` param removed),
`score_sharer.dart` + `score_share_screen.dart` + `MainActivity.kt` (caption
plumbed through both share paths), `submit-score/index.ts` + new
`best_score.ts`/`best_score.test.ts` (atomic RPC call), new migration
`0014_atomic_score_upsert.sql`, extended `supabase/tests/leaderboard_smoke.sql`
(found and reused an existing SQL smoke-test file rather than creating a
parallel one), plus matching test updates across the board. `deno.lock`
downgraded format 6→5 (deviation, explained below).

Proof (Codex's report): `flutter analyze` clean, `flutter test` 743/743,
`deno test --frozen supabase/functions/` 58/58.

Deviations reported: `deno.lock` format downgrade (local stable Deno rejects
format 6 — needed to run the mandated frozen suite at all, not a dependency
content change); Facebook-caption fallback ladder not activated (correctly —
it's conditional on a real-device observation Codex has no way to make);
Phase 2/3 deploy, live verification, and security advisors not run (explicitly
out of scope per the brief — no live Supabase project was touched).

### Claude's verdict
Read the full diff file-by-file (not just Codex's summary) and independently
reran all three proof commands myself rather than trusting the pasted output —
all confirmed passing. Traced the generation-guard logic by hand against the
exact race Round 5 of Act 2 found (a stale pre-continue submission clobbering a
post-continue one) — correctly handled, and directly exercised by a real test
(`continued board invalidates a stale result and its improved run submits`).
Verified `_installKeys` exclusion, `search_path` pinning, and the RPC grant
lockdown (`SECURITY INVOKER`, `REVOKE ALL FROM PUBLIC/anon/authenticated`,
`GRANT ... TO service_role`) both in the migration and in dedicated assertions
Codex added to the existing `leaderboard_smoke.sql`.

Found one residual gap one layer deeper than what Act 2 review reached:
`_settleSubmission` re-checked the generation guard at its call site but not
immediately before its own `saveSubmitStatus` write — a narrower window where
a stale settle-write could still land after a newer generation's reset,
during the write's own async gap. Fixed directly (one guard line + comment)
rather than resuming Codex, matching the skill's guidance not to round-trip
trivial single-line fixes through delegation. Re-ran `flutter analyze` and the
full `flutter test` suite after the fix — all 743 tests still pass.

No fix-loop round was needed against Codex itself (`MAX_FIX_ROUNDS` unused;
Claude fixed the one finding directly).
