# First-launch Onboarding Tour Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the static game overlay with the frozen continuous seven-step
first-launch tour and make completion durable before normal navigation resumes.

**Architecture:** `TierSelectScreen` owns one explicit phase machine across a
scripted mechanics route, local tier coachmarks, and a tutorial-mode leaderboard
route. A reusable spotlight measures dedicated wrapper keys after layout, while
`EngagementCubit` serializes and verifies the one existing profile flag.

**Tech Stack:** Dart 3, Flutter, flutter_bloc, Hive-backed `StorageService`,
Flutter test.

## Global Constraints

- Follow frozen root `PLAN.md` exactly; this document records rather than redesigns it.
- Do not modify `lib/domain/engine/game_engine.dart`, `canFollow`, scoring, `lib/domain/constants.dart`, `supabase/functions/_shared/`, or `kLeaderboardSeason`.
- Do not add dependencies or persisted fields; reuse `tutorialSeen` only.
- Keep `_serializedPrizeCommit` private; expose only `Future<bool> markTutorialSeen()`.
- Scripted tutorial boards never use `DailySeeder`, submit, real moves, or leaderboard scoring.
- Existing plain widget-test keys remain unchanged; spotlight keys wrap them separately.
- During tour phases, exclude the whole underlying screen from semantics and expose only coachmark semantics.
- Steps 1 and 5 expose the tutorial-only semantic merge action.
- Every behavior change starts with a focused failing test and receives the minimum implementation.
- Final proof is a fresh `flutter analyze` followed by a full `flutter test`.

---

### Task 0: Record the approved design and execution plan

**Files:**

- Create: `docs/superpowers/specs/2026-07-20-onboarding-tour-design.md`
- Create: `docs/superpowers/plans/2026-07-20-onboarding-tour.md`

**Interfaces:**

- Consumes: frozen root `PLAN.md` and the established dated-doc convention.
- Produces: the component, persistence, navigation, accessibility, and proof contracts used below.

- [ ] Write both dated documents before production changes.
- [ ] Map every root Approach item 0–9 to the numbered tasks below.
- [ ] Run `git diff --check` and inspect both documents.
- [ ] Commit the two planning documents.

### Task 1: Remove the game-route tutorial owner

**Files:**

- Delete: `lib/presentation/screens/tutorial_overlay.dart`
- Modify: `lib/presentation/screens/game_screen.dart`
- Check: `test/presentation/game_session_route_test.dart`
- Check: `test/infrastructure/profile_wire_format_test.dart`

**Interfaces:**

- Removes: `_showTutorial`, `_dismissTutorial`, and `TutorialOverlay` wiring.
- Preserves: `GameScreen` storage use for every non-tutorial feature.

- [ ] Add or update route assertions so a pushed `GameScreen` is never covered by the old overlay.
- [ ] Run the focused route test and confirm it fails against the old gate where applicable.
- [ ] Remove only the tutorial import, state, persistence method, and overlay stack child; delete the file.
- [ ] Rerun the focused route and profile wire-format tests and require green.
- [ ] Commit the removal of the game-route tutorial owner.

### Task 2: Add scripted interactive mechanics and deadlock fixtures

**Files:**

- Create: `test/presentation/tutorial_tour_screen_test.dart`
- Create: `lib/presentation/screens/tutorial_tour_screen.dart`

**Interfaces:**

- Produces: `TutorialTourScreen` for steps 1–5 and a route result indicating continuation or Skip.
- Consumes: `BoardWidget`, `MovesCounter`, and existing `GameEngine` methods without changing them.

- [ ] Add failing tests that drag the highlighted pair, invoke both semantic merge actions, and directly assert the pinned step-5 result is deadlocked with no merge available.
- [ ] Run `flutter test test/presentation/tutorial_tour_screen_test.dart` and confirm missing-screen/behavior failures.
- [ ] Add independent immutable 4×4 fixtures for steps 1, 4, and 5; hand-pin the one-merge deadlock refill.
- [ ] Implement steps 1–5, real `onChain` validation/collapse, one cancellable refill timer, and phase-safe disposal.
- [ ] Rerun the focused tutorial test and require green.
- [ ] Commit the scripted mechanics screen and deadlock fixtures.

### Task 3: Add the reusable spotlight coachmark

**Files:**

- Create: `lib/presentation/widgets/tutorial_spotlight.dart`
- Modify: `lib/presentation/screens/tutorial_tour_screen.dart`
- Test: `test/presentation/tutorial_tour_screen_test.dart`

**Interfaces:**

- Produces: a coachmark accepting target `Rect`, title/body, Next/Skip callbacks, waiting/retry state, and optional semantic merge callback.
- Preserves: pointer delivery to the exposed scripted board and existing target keys.

- [ ] Add failing assertions for visible Skip/Next, cutout geometry, blocked background semantics, and the named merge semantic action.
- [ ] Run the focused tutorial test and confirm failures.
- [ ] Implement the minimum `Stack`/`CustomPainter` coachmark and dedicated post-layout target measurement.
- [ ] Rerun the focused tutorial test and require green.
- [ ] Commit the reusable spotlight coachmark.

### Task 4: Teach the exact seven-step content

**Files:**

- Modify: `lib/presentation/screens/tutorial_tour_screen.dart`
- Modify: `test/presentation/tutorial_tour_screen_test.dart`

**Interfaces:**

- Step 1 advances only after its exact merge.
- Step 4 states equal-or-+1, never down or skip, matching `GameEngine.canFollow`.
- Step 5 advances only after merge, pinned refill playback, and deadlock evaluation.

- [ ] Add failing copy/phase tests for moves, qualitative drop widening, corrected chain rule, and deadlock completion.
- [ ] Run the focused test and confirm the missing phases fail.
- [ ] Add only the frozen instructional copy and transitions.
- [ ] Rerun the focused test and require green.
- [ ] Commit the complete steps 1–5 instructional sequence.

### Task 5: Add tutorial-mode leaderboard ownership

**Files:**

- Modify: `test/presentation/leaderboard_screen_test.dart`
- Modify: `lib/presentation/screens/leaderboard_screen.dart`

**Interfaces:**

- Produces: optional tutorial-mode entry, local target measurement/rendering, Skip, and a completion route result.
- Conditional targets: omit Friends without `friendsService`; explain rows in text while missing/loading/empty/errored.

- [ ] Add failing widget tests for missing Friends toggle and empty/error row fallback.
- [ ] Run `flutter test test/presentation/leaderboard_screen_test.dart` and confirm failures.
- [ ] Wrap existing controls/rows with dedicated target keys and render the coachmark only in tutorial mode.
- [ ] Protect the tutorial route with `PopScope` and return completion/Skip through `Navigator.pop`.
- [ ] Rerun leaderboard screen and period-range tests and require green.
- [ ] Commit tutorial-mode leaderboard ownership.

### Task 6: Serialize and verify tutorial persistence

**Files:**

- Modify: `test/application/engagement_test.dart`
- Modify: `lib/application/engagement_cubit.dart`

**Interfaces:**

- Produces: `Future<bool> EngagementCubit.markTutorialSeen()`.
- Uses: private `_serializedPrizeCommit` queue and persisted-profile verification.

- [ ] Add failing tests for both tutorial/prize enqueue orders, injected prize error recovery, swallowed tutorial save error returning false, and successful retry.
- [ ] Run `flutter test test/application/engagement_test.dart` and confirm missing-method failures.
- [ ] Implement the public wrapper without changing queue visibility or error semantics.
- [ ] Rerun the focused engagement test and require green.
- [ ] Commit serialized, verified tutorial persistence.

### Task 7: Own the continuous phase machine in tier select

**Files:**

- Modify: `test/presentation/tier_select_screen_test.dart`
- Modify: `test/presentation/tier_select_overflow_probe_test.dart`
- Modify: `lib/presentation/screens/tier_select_screen.dart`

**Interfaces:**

- Consumes: `TutorialTourScreen`, tutorial-mode `LeaderboardScreen`, and `markTutorialSeen()`.
- Produces: auto-launch, step-6 card/practice sequence, offline step-7 explainer, guarded durable finish, and ordinary unlocked tier select.

- [ ] Mark every existing fresh-storage tier fixture `tutorialSeen: true`.
- [ ] Add failing tests for auto-launch, arbitrary Skip, off-screen target measurement, back interception, persistence wait, and false-then-true retry.
- [ ] Run both tier-select test files and confirm failures come from the missing phase machine.
- [ ] Add init-time gating, route continuation, dedicated card/practice keys, two-phase scroll/ensure-visible measurement, `ExcludeSemantics`, and navigation blocking.
- [ ] Await one guarded completion call before dismissing or re-enabling navigation.
- [ ] Rerun both tier-select test files and require green.
- [ ] Commit the tier-select-owned tour phase machine.

### Task 8: Wire Skip and analytics across every phase

**Files:**

- Modify: `lib/presentation/screens/tutorial_tour_screen.dart`
- Modify: `lib/presentation/screens/tier_select_screen.dart`
- Modify: `lib/presentation/screens/leaderboard_screen.dart`
- Modify: corresponding presentation tests.

**Interfaces:**

- Emits: `tutorial_started`, `tutorial_skipped` with `step`, and `tutorial_completed` through the existing optional analytics seam.
- Preserves: one durable completion path for natural finish and every Skip.

- [ ] Add failing tests that find Skip on each route owner and capture the three analytics event shapes.
- [ ] Run focused presentation tests and confirm failures.
- [ ] Thread the smallest callback/result values needed to identify the current global step.
- [ ] Rerun focused presentation tests and require green.
- [ ] Commit cross-phase Skip and analytics wiring.

### Task 9: Verify durability, regression coverage, and full repository health

**Files:**

- Review every file changed by Tasks 0–8.

**Interfaces:**

- Consumes: every frozen `PLAN.md` requirement and non-goal.
- Produces: analyzer/test proof and a scoped change report.

- [ ] Run `dart format` on changed Dart files only.
- [ ] Run tutorial, tier-select, leaderboard, engagement, route, and profile focused suites.
- [ ] Re-read root `PLAN.md` line by line and remove scope creep.
- [ ] Confirm forbidden engine, TypeScript, constants, season, dependencies, and goldens are untouched.
- [ ] Run `flutter analyze` and require `No issues found!`.
- [ ] Run `flutter test` and require `All tests passed!`.
- [ ] Run `git diff --check`, inspect `git diff --stat`, and inspect `git status --short`.
- [ ] Report one line per changed file, both dated docs, exact proof output, and every deviation with its reason.
- [ ] Commit the final verified onboarding-tour change set.

## Out of Scope

- Any engine, scoring, replay, season, or seeded daily-board change.
- Practice or real daily-run changes.
- New persistence, dependencies, localization, or broad accessibility work.
- Storage-wide writer serialization or real-gameplay semantic drag support.
