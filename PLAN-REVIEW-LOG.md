# Plan Review Log: first-launch onboarding tour (interactive tutorial + tip spotlights + skip)
Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.

(The prior task's log — top-5 leaderboard prizes — lives in git history at 0161973.)

## Round 1 — Codex

## Material findings

1. The plan never defines a navigation state machine; route back gestures, failed saves, or double-taps can bypass Skip and leave the unfinished tour over an interactive tier screen.
   Fix: Centralize phases in `TierSelectScreen`, block interaction while launching, use `PopScope`, serialize completion, and unwind routes only after persistence succeeds.

2. Persisting `tutorialSeen` with whole-profile `loadProfile`/`saveProfile` races the four unawaited startup prize writers in main.dart, allowing either tutorial completion or prizes to be overwritten.
   Fix: Introduce one serialized `updateProfile` path and route tutorial plus all concurrent startup profile mutations through it.

3. PLAN.md treats existing `Key(...)` values as `GlobalKey`s, but the current card and practice keys are ordinary keys.
   Fix: Preserve the test keys and attach separate owned `GlobalKey`s to target wrappers.

4. Waiting one frame does not make off-screen tier cards measurable; the cards live in a scrolling list and may have no mounted `RenderBox`.
   Fix: Add a `ScrollController`, scroll each target into view, wait for layout, then convert its rect into the overlay's coordinate space.

5. The interactive Step 1 spotlight can swallow the drag because a full-screen overlay sits above `BoardWidget`'s `GestureDetector`.
   Fix: Make the painted scrim `IgnorePointer` and place only the coachmark controls in hit-testing widgets outside the exposed board region.

6. Step 7 assumes online means all targets exist, but the Global/Friends toggle is absent when `friendsService == null`, and rows may be loading, empty, or failed.
   Fix: Conditionally skip missing controls and fall back to a static row explainer after empty/error/timeout states.

7. The drop script contradicts the API: `GameEngine.applyDrop` requires a `Prng` and chooses among empties; callers cannot specify a landing cell directly.
   Fix: Pin a concrete PRNG seed and expected landing sequence, or use explicit board snapshots and stop claiming the cells are selected through `applyDrop`.

8. The exact tutorial boards remain an "open question," so Step 1's collapse may destroy Step 4's example and Step 5 has no proven deadlock sequence.
   Fix: Specify immutable per-step board fixtures, transition/reset rules, PRNG seed, and asserted final `GameStatus.deadlocked` before implementation.

9. The coachmark has no accessibility contract for screen-reader focus, semantics, large text, reduced motion, or safe-area placement.
   Fix: Require semantic announcements and focus transfer, accessible Skip/Next labels, text-scale tests, safe-area layout, and reduced-motion behavior.

10. Auto-launching for the default `tutorialSeen == false` profile will break existing `TierSelectScreen` tests that construct fresh storage, while the proposed source-deletion test adds little value.
    Fix: Mark tutorial seen in all non-onboarding fixtures and replace source scanning with behavioral tests for back, off-screen targets, empty leaderboard, and persistence failure.

11. There is no onboarding observability despite an existing analytics seam, so completion, abandonment, and problematic steps cannot be measured.
    Fix: Log `tutorial_started`, `tutorial_skipped(step)`, and `tutorial_completed` through the existing optional `AnalyticsService`.

12. Spotlighting every difficulty card repeats one explanation and creates most of the scrolling/key complexity.
    Fix: Spotlight one representative tier card plus its Practice action, then summarize the difficulty progression in the coachmark copy.

13. This is still a design sketch, not the repository-required dated spec plus task-by-task red/green implementation plan, and it omits full verification.
    Fix: Publish the required spec and executable plan with exact files, failing tests, implementation steps, `flutter analyze`, and full `flutter test`.

VERDICT: REVISE

### Claude's response

Accepted and folded into PLAN.md (tasks renumbered, 0-9):
- #1 (nav state machine / PopScope) — added as an explicit phase machine owned by TierSelectScreen, PopScope on tour routes, persist-then-unwind ordering.
- #3 (GlobalKey vs existing Key) — plan now attaches dedicated GlobalKeys alongside existing test Keys, doesn't repurpose them.
- #4 (off-screen cards) — added Scrollable.ensureVisible before measuring.
- #5 (scrim swallows drag) — scrim is IgnorePointer over the exposed board region during the interactive step.
- #6 (step 7 partial availability) — expanded fallback beyond leaderboard==null to cover friendsService==null and loading/empty/error board states.
- #7 (applyDrop can't take an explicit landing cell) — fixed the mechanism: script exactly one empty index open per drop step so the PRNG draw is deterministic by construction, while still routing through the real engine call.
- #8 (board fixtures underspecified) — each step now gets its own immutable fixture with explicit transitions; step 5's fixture gets a dedicated test asserting GameStatus.deadlocked.
- #10 (existing tests break / low-value new test) — added explicit task to update existing TierSelectScreen fixtures to tutorialSeen: true; dropped the source-deletion test in favor of behavioral tests (back-gesture, off-screen target, leaderboard fallback states).
- #11 (observability) — added analytics events via the existing AnalyticsService seam.
- #13 (repo planning workflow) — added as approach step 0, referencing CLAUDE.md's required docs/superpowers spec+plan before Act 3 build.

Partially accepted:
- #2 (profile-write race) — real, but pre-existing and already explicitly out-of-scope in the prior shipped leaderboard-prizes plan (git 0161973), which documented the same race and deliberately deferred a serialized updateProfile fix. Recorded as an inherited risk, not fixed here; the tutorial's single boolean write follows the exact pattern the codebase's own _dismissTutorial already uses today, so it doesn't introduce a new failure mode.
- #9 (accessibility contract) — a full a11y contract (screen-reader focus, reduced motion, text-scale tests) would hold this one feature to a standard nothing else in lib/presentation meets (grep confirmed: zero Semantics/semanticLabel usage repo-wide). Scoped down to visible Skip/Next labels and reasonable tap targets, matching existing conventions; noted in Key decisions.

Rejected, with reason:
- #12 (spotlight one representative card instead of all) — contradicts an explicit, specific instruction from the user during the grill ("spotlights the difficulties one by one and gives a brief description of the differences"). This is a settled product decision, not a technical defect; logged as rejected rather than silently overridden.

## Round 2 — Codex

Most prior findings are addressed: phase/back handling, wrapper GlobalKeys, hit-testing, conditional leaderboard targets, analytics, test fixtures, and planning workflow.

Remaining blockers:

- The profile-write race remains material: this adds a writer during the exact startup window containing four unawaited prize writers, so `tutorialSeen` or prize data can be lost. Fix: serialize profile mutations through one storage-level update path, or delay prize checks until onboarding persistence finishes.
- New contradiction: with exactly one empty cell, the first `applyDrop` fills it and every subsequent call hits the empty-list assertion in game_engine.dart. Fix: use multiple empties with a fixed PRNG seed and pin every landing in the test.
- `Scrollable.ensureVisible(key.currentContext!)` cannot find a card that is sufficiently off-screen because lazy `ListView` children may be unmounted. Fix: scroll approximately by index with a `ScrollController`, then call `ensureVisible` once the target mounts.
- `TierSelectScreen` owns the phase machine, but the spotlight targets live inside a pushed `LeaderboardScreen`; the plan does not define how keys or overlay state cross that route boundary. Fix: explicitly pass the target keys/tour callbacks into `LeaderboardScreen`, or let that screen own Step 7 and return a result.
- Persistence failure and repeated Skip taps remain undefined; "only after the write resolves" does not handle a thrown write or concurrent completion calls. Fix: memoize one completion future, disable controls while saving, and show retry UI on failure.
- Rejecting accessibility is not sound: an `IgnorePointer` scrim can leave underlying controls exposed to screen readers while the visual UI is modal. Fix: exclude background semantics and give the coachmark a scoped semantic route, focus announcement, and accessible controls.

VERDICT: REVISE

### Claude's response

Accepted and folded into PLAN.md:
- New contradiction (one-empty-cell mechanism self-defeating) — this was a genuine bug in my own round-1 fix. Replaced with the actually-correct mechanism: Prng (Mulberry32) is fully deterministic for a fixed seed, so the initial board + drop-tier sequence + seed are authored, run once to discover the resulting landings, then pinned by a test asserting GameStatus.deadlocked. Landings are discovered, not dictated.
- Lazy ListView unmounted children — added two-phase measurement: approximate scroll-by-index via ScrollController first, then Scrollable.ensureVisible once the target's context is non-null.
- Route-boundary key crossing — LeaderboardScreen now owns step 7 directly via an optional tutorial-mode entry, reporting completion back through the same Navigator.push(...).then(...) pattern tier_select_screen.dart already uses for GameScreen, instead of TierSelectScreen reaching into a pushed route's internals.
- Repeated Skip taps — added a single _completing guard, same idiom as the deleted TutorialOverlay's _dismissed bool.
- Accessibility (narrow reading) — accepted the specific correctness claim: IgnorePointer only blocks touch hit-testing, not the semantics tree, so a screen reader could still reach a dimmed background control. Added ExcludeSemantics around dimmed background content during each spotlight step. The broader ask (focus announcements, reduced motion, text-scale tests) remains out of scope, for the same repo-consistency reason as round 1 (zero existing Semantics usage anywhere in lib/presentation) — round 2's finding was narrower and specific, so only that narrow slice was accepted.

Partially accepted (mitigated, not fully fixed, with reasoning strengthened):
- Profile-write race — Codex is right that this feature actively lands a writer inside the contested startup window, not merely inheriting a dormant risk. Still declining the full serialized-updateProfile refactor (explicitly out of scope in the prior shipped leaderboard-prizes plan, git 0161973, for the same reason: it's a project-wide fix bigger than any one feature). Added a concrete mitigation instead: sequence the tour's completion/skip write to fire after TierSelectScreen's own cubits' initial .load() calls settle, narrowing the collision window with the unawaited prize writers without taking on the full refactor.

Declined further, with reasoning: write-failure retry UI — the plan documents the fail-safe outcome (write throws → tutorialSeen stays false → tour simply reruns next launch) instead of building retry UI, because no other local-storage writer in this codebase (_rescheduleNotifications, _dismissTutorial, etc.) has retry UI either; a thrown Hive write is also not a realistic failure mode this app already treats as needing user-facing recovery anywhere.

## Round 3 — Codex

Round-two findings addressed: lazy-list targeting, leaderboard route ownership, duplicate completion, and background semantics now have credible solutions.

Remaining/new blockers:

- The profile-race mitigation is ineffective: all three cubit `.load()` methods are synchronous and finish before the unawaited prize checks even start at main.dart:135. Fix: retain a `Future.wait` for the four startup prize checks and await it before saving `tutorialSeen`, or serialize profile updates.
- A drop-only sequence cannot transition from mergeable to deadlocked: `applyDrop` adds a tile but never removes an existing legal adjacency, so a mergeable initial board stays mergeable; otherwise it begins deadlocked. Fix: define Step 5 as a post-collapse, no-merge board whose refill exhausts all empty cells without rescuing it, then call `evaluateStatus`.
- The Risks section still references the discarded "exactly one empty cell per drop" construction, contradicting the corrected approach. Fix: replace it with the fixed-seed, multiple-empty refill sequence.
- `ExcludeSemantics` makes the required drag unavailable to screen readers, while Skip only abandons the tutorial. Fix: add a semantic action/button that invokes the same highlighted merge transition.
- "Tile-by-tile" playback implies delayed callbacks that can survive Skip/navigation and mutate disposed state. Fix: use one cancellable timer/controller and cancel it on phase changes and `dispose`.

VERDICT: REVISE

### Claude's response

Accepted and folded into PLAN.md:
- Profile-race mitigation ineffective — verified directly against main.dart: the four `unawaited(engagement.check*Prizes(...))` calls fire before `runApp` even runs and are wholly unrelated to any cubit `.load()`. Replaced with a real fix: main.dart captures `Future.wait([...])` over those four calls and threads it down through ConnectMergeApp -> TierSelectScreen as a plain constructor parameter; the tour awaits it before persisting. Small and targeted, not the general serialized-updateProfile refactor (still out of scope).
- Step 5 engine-logic contradiction — this was a real bug in round 2's design, not just underspecified. Confirmed from game_engine.dart: applyDrop only fills empty cells, never removes tiles or touches existing adjacencies, so drops alone can never cause a deadlock (a board with a legal pair keeps it regardless of drops; a board with none is already deadlocked by definition, since hasMergeAvailable ignores empty cells). Redesigned step 5: fixture has exactly one legal merge remaining, player performs it (same interactive mechanic as step 1), the resulting refill (seed discovered/pinned as before) is chosen to create no new adjacency, evaluateStatus then confirms GameStatus.deadlocked. Also narratively better — the player's own move causes the lock.
- Stale Risks reference to the discarded "one empty cell" construction — fixed, now describes the actual post-collapse-refill mechanism.
- Tile-by-tile playback outliving the widget — added an explicit requirement: one cancellable Timer/AnimationController owned by the tour screen, canceled on dispose and on any phase change (Skip, navigation).

Partially accepted:
- ExcludeSemantics blocking the required drag from screen readers — clarified scope: ExcludeSemantics applies only to the dimmed *background* outside the spotlight cutout, never to the actively-taught foreground board, so it was never blocking the drag itself. Declined the broader ask (a semantic merge-action button as an alternative input path) as out of scope for the tutorial specifically: BoardWidget's real gameplay interaction is the same raw drag with the same lack of a semantic alternative, so this would be retrofitting accessibility onto a core mechanic the shipped game doesn't support either. Logged honestly as an inherited, unclosed gap in Risks rather than silently dropped.

## Round 4 — Codex

Round-three deadlock logic and delayed-playback cancellation are now correctly addressed.

Remaining/new blockers:

- Awaiting `prizeChecksReady` makes Skip/completion depend on four network-backed prize checks; a slow request can freeze onboarding, and an unexpected future error prevents the tutorial save entirely. Fix: serialize the prize and tutorial profile mutations instead of putting network futures on the onboarding critical path.
- The inaccessible drag remains explicitly rejected, so screen-reader users cannot complete Steps 1 or 5 except by abandoning the tour. Fix: add a tutorial-only semantic "Merge highlighted tiles" action invoking the same chain handler.
- `ExcludeSemantics` works on widget subtrees, not the pixels outside a painted cutout, so the proposed "everything outside the spotlight" exclusion is not generically implementable. Fix: exclude the entire underlying screen and expose the target description/action through the coachmark's own `Semantics`.
- The Risks section still claims sequencing waits for cubit loads, contradicting the new `prizeChecksReady` design. Fix: update it and add a controlled-future test covering prize completion/error behavior before tutorial persistence.

VERDICT: REVISE

### Claude's response

Accepted and folded into PLAN.md, all four:
- Network futures on the Skip critical path — verified EngagementCubit already has exactly the right primitive (`_serializedPrizeCommit` / `_prizeCommit`, engagement_cubit.dart:444) that serializes the four prize writers against each other AND swallows their errors internally. Routed the tutorial's write through that same queue instead of an independent saveProfile call or an awaited Future.wait. Crucially also stopped awaiting it from the UI at all — Skip/finish dismiss the tour immediately (matching existing fire-and-forget writes like _rescheduleNotifications), the queue guarantees correctness in the background. This is simpler than round 3's fix (no futures threaded through main.dart/constructors) and fully resolves both the freeze risk and the unhandled-error risk.
- Inaccessible drag rejected too broadly — re-scoped: Codex's round 4 ask was specifically a "tutorial-only" semantic action, which is exactly the right boundary (the tutorial fixture already knows the one correct path in advance, unlike real gameplay). Accepted as stated.
- ExcludeSemantics not generically implementable over "everything outside a cutout" — correct, a semantics exclusion can't follow an arbitrary painted shape. Fixed: exclude the entire underlying screen instead, and make the coachmark itself the sole semantic surface (description + the tutorial-only merge action for steps 1/5).
- Stale Risks reference — swept the whole file for leftover references to discarded mechanisms (found three: task 6's "await before unwinding" body text, the Key Decisions step-5 blurb still describing "watch drops lock it," and the profile-race Risks bullet still describing the round-1 "sequence after cubit loads" mitigation). All rewritten to match the final design. Added the requested test: concurrent prize-check + tutorial-completion commits through the shared queue, asserting neither write is lost and a prize-check error doesn't block the tutorial's write.

## Round 5 — Codex

Round-four accessibility, semantics scoping, stale risk text, and shared serialization are addressed.

New blockers:

- Fire-and-forget persistence contradicts the core guarantee: after Skip the UI reports completion before `tutorialSeen` is durable, so an immediate app kill shows the tour again. Fix: await the queued local commit before dismissing; prize network calls occur before queue insertion, so this only waits on short storage writes.
- A queued tutorial write can execute after account deletion wipes Hive, recreating an otherwise-deleted profile with `tutorialSeen: true`. Fix: finish the queued write before re-enabling navigation, preventing it from outliving onboarding.
- Adding `@visibleForTesting` to `_serializedPrizeCommit` does not make a private method callable from `TierSelectScreen`. Fix: keep the queue private and expose one intent-specific `Future<bool> markTutorialSeen()` method.
- The tests verify queue ordering but not the new durability boundary. Fix: assert the tour remains active until `markTutorialSeen` succeeds and no write remains after dismissal.

VERDICT: REVISE

### Claude's response

All four accepted — this was a tight, correct round with no overreach to push back on:
- Fire-and-forget contradicted durability — round 4's over-correction went too far chasing round 3's "don't block on network" feedback. Restored awaiting the write, but specifically the *queued local commit* (normally fast, since it's local Hive I/O), not the raw network prize checks directly — the tour now stays visible until markTutorialSeen() resolves, then unwinds.
- Account-deletion race — a genuinely sharp catch: fire-and-forget meant a queued write could land after Hive was wiped by account deletion, reviving a stale tutorialSeen: true into a fresh profile. Fixed by the same change as the durability fix above — navigation (including the path to Profile -> delete-my-data) doesn't re-enable until the write is confirmed done, so no write can outlive the tour.
- @visibleForTesting doesn't grant cross-library access to a private method — correct Dart semantics catch on my own sloppy round-4 phrasing. Replaced with a single dedicated public method, EngagementCubit.markTutorialSeen(), which internally uses the existing private queue.
- Missing durability test — added: tour blocks dismissal until markTutorialSeen() resolves, and no write remains outstanding once the tour has visually closed.

## Round 6 — Codex (over MAX_ROUNDS=5 — process error, see Resolution)

Round-five durability, account-deletion ordering, public API, and queue-ordering tests are addressed.

Remaining/new issues:

- `markTutorialSeen()` returns `bool`, but the `false` branch is undefined; the UI can remain permanently stuck in `_completing` with a spinner. Fix: on `false`, clear `_completing`, keep the tour open, show a retry message, and log completion only after `true`.
- The plan says the queue may wait behind an in-flight network prize check, but network fetching happens before commits enter `_serializedPrizeCommit`; only local profile writes occupy that queue. Fix: correct the description and avoid designing timeout behavior for a nonexistent queue state.
- The new failure and accessibility paths lack checks. Fix: test a failed-then-successful `markTutorialSeen()` retry and invoke the semantic merge action in Steps 1 and 5.

VERDICT: REVISE

### Claude's response

Process note: this round should not have fired — MAX_ROUNDS=5 was set at the start and round 5 (the fourth resume) already consumed the budget. Firing this resume was a bookkeeping error. All three findings were nonetheless legitimate (verified finding #2 directly against checkDailyPrizes/etc. in engagement_cubit.dart: the network fetchRanks call is awaited *before* the loop that enters _serializedPrizeCommit, so only local writes ever occupy that queue — my round 5 "narrow wait behind network" framing was factually wrong), so all three are folded into PLAN.md as Claude's own final-arbiter judgment rather than firing a seventh Codex call:
- markTutorialSeen() false branch was undefined — fixed: clear _completing, keep the tour open with a retry affordance, only log completion on true.
- "wait behind network" claim was wrong — corrected the description to state plainly that the queue only ever contains local Hive writes, verified against the real prize-checker implementations.
- Added the two requested tests (failed-then-successful retry; invoking the semantic merge action directly).

Per the skill's deadlock-resolution rule ("do NOT fake convergence... hand it to the user"): this closes as a **process deadlock at round 6/MAX_ROUNDS=5**, not a clean APPROVED. The plan itself converged in substance (round 6's findings were narrow refinements of round 5's design, not new categories of problems), but round 6 was never independently re-reviewed by Codex after these fixes because the round budget was already spent. Flagged to the user for sign-off with that caveat.

## Round 7 — Codex (extra round, outside original MAX_ROUNDS=5 budget, requested by user to clear the round-6 process error)

All round-six findings are addressed. The persistence queue is correctly scoped and awaited, failure is retryable, semantics are implementable, and the new durability/accessibility tests cover the critical paths. No new material blockers found.

VERDICT: APPROVED

### Resolution

Converged. 7 rounds total (5 planned + 1 process-error round + 1 user-requested extra round to clear it). PLAN.md is final.
