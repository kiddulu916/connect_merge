# First-launch Onboarding Tour — Design

Date: 2026-07-20
Status: Approved (frozen by root `PLAN.md` after grill and seven adversarial reviews)

## Summary

Replace the game-route-owned static three-page overlay with one continuous,
fully skippable seven-step first-launch tour. Steps 1–5 teach mechanics on a
dedicated deterministic board, step 6 walks every tier and its practice action,
and step 7 explains whichever leaderboard controls and rows exist in the
current session. The existing `tutorialSeen` profile setting remains the only
persistent state.

`TierSelectScreen` owns the tour phase machine and blocks ordinary navigation
while it runs. It launches the scripted board route, resumes with tier-card
spotlights, pushes the leaderboard in tutorial mode when available, and only
returns to normal interaction after `EngagementCubit.markTutorialSeen()` has
verified the queued profile write.

## Scripted mechanics board

`TutorialTourScreen` uses explicit immutable 4×4 `BoardState` fixtures rather
than a real `Difficulty`, daily seed, practice seed, move log, or submission
path. Each mechanic owns its fixture so an earlier merge cannot destroy a later
example. The screen reads the shipped `GameEngine` API but changes no rule or
dual-engine parity surface.

Step 1 requires a real two-tile drag over an obvious equal pair. Step 2 points
to a real `MovesCounter` and explains the fixed daily budget. Step 3 explains
that merges refill empty cells and that later drops may include wider tiers.
Step 4 teaches the exact `canFollow` rule: equal or exactly one tier higher,
never lower and never skipping.

Step 5 begins with exactly one legal merge. Performing it calls the normal
collapse operation, then replays a pinned sequence of `applyDrop` refills. The
refill does not create a new legal adjacency, so `evaluateStatus` returns
`GameStatus.deadlocked`. One cancellable timer owns the tile-by-tile playback
and is canceled on phase changes and disposal.

## Spotlight and accessibility boundary

One reusable coachmark renders a dim scrim, rectangular cutout, copy, and
Next/Skip controls. Dedicated `GlobalKey` wrappers measure targets after
layout; existing plain test keys remain unchanged. The same primitive serves
the moves counter, ascending chain, tier cards, practice actions, and
leaderboard controls or rows.

While a tour phase is active, `ExcludeSemantics` wraps the entire underlying
screen. The coachmark becomes the sole semantic surface. Interactive steps 1
and 5 expose a tutorial-only “Merge highlighted tiles” action that invokes the
same known fixture path as the drag callback. Real `BoardWidget` accessibility
is unchanged.

## Tier and leaderboard continuation

Tier cards live in a lazy `ListView`, so step 6 first scrolls approximately to
the target index, waits for mounting, uses `Scrollable.ensureVisible`, and only
then reads the target `RenderBox`. Every regular difficulty card receives its
own explanation, including the counterintuitive relationship between smaller
boards/fewer starting tiles and less planning room. Practice is explicitly
described as off-leaderboard, replayable, and move-budget-free.

`LeaderboardScreen(tutorialMode: true)` measures and renders its own step-7
targets, then returns a route result to `TierSelectScreen`. Friends scope is
omitted when `friendsService` is absent. A missing, loading, empty, or errored
row becomes a text explanation instead of a spotlight. When no leaderboard
service is configured, tier select shows a static offline explainer rather
than pushing the real screen.

## Trigger, skip, and durable completion

Tier select checks `profile.settings.tutorialSeen` once during initialization.
False starts the phase machine before real controls can be used. Skip is
visible on every phase, and protected tour routes use `PopScope` so system back
cannot bypass the same durable-completion path.

Natural finish and Skip share one guarded completion method. It logs the skip
position when applicable, awaits `EngagementCubit.markTutorialSeen()`, and
keeps the modal UI and navigation lock visible until the method returns true.
The new cubit method schedules the write through the existing private
`_serializedPrizeCommit` queue and verifies the persisted setting because the
queue deliberately swallows writer exceptions. False restores a retry action;
only true dismisses, logs `tutorial_completed`, and re-enables navigation.

Analytics use the existing optional seam: `tutorial_started`,
`tutorial_skipped` with a step parameter, and `tutorial_completed`.

## Proof strategy

Widget tests drive the real step-1 drag, semantic actions for steps 1 and 5,
the exact deadlock fixture, off-screen tier target measurement, auto-launch,
Skip, back interception, durability wait, retry, and conditional leaderboard
targets. Application tests drive tutorial writes concurrently with prize
commits, including injected errors, and verify no write is lost. Existing tier
fixtures opt out with `tutorialSeen: true`. Completion requires fresh clean
`flutter analyze` and full `flutter test` runs.

## Out of scope

- Game-engine rules, scoring, constants, TypeScript replay, season, or goldens.
- Practice or real daily-board behavior.
- New profile fields, dependencies, localization, or broad accessibility work.
- A general serialization refactor for non-tutorial profile writers.
- A semantic replacement for real gameplay drag gestures.

