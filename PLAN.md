# Plan: First-launch onboarding tour (interactive tutorial + tip spotlights + skip)
_Locked via grill — by Claude + kiddulu916_

## Goal

Replace the existing static 3-step `TutorialOverlay` with a single continuous
7-step first-launch tour that teaches the real mechanics (chain-merge drag,
move budget, drop-tier progression, the ascend-or-equal chain rule, deadlock)
on a dedicated scripted board, then walks the player through the tier-select
screen's difficulty cards and the leaderboard screen, before handing control
back for real play. The tour is skippable at any point and, once completed or
skipped, never shows again (single `tutorialSeen` flag, same as today).

## Approach

0. **Repo planning workflow**: per `CLAUDE.md`, nontrivial features here go
   through a dated design doc under `docs/superpowers/specs/` and a
   task-by-task red/green plan under `docs/superpowers/plans/`. This
   grill-locked `PLAN.md` is the design brief that feeds those, produced
   before Act 3 (build) starts, matching how the prior leaderboard-prizes
   feature was sequenced.

1. **Delete `lib/presentation/screens/tutorial_overlay.dart`** and its wiring
   in `game_screen.dart` (`_showTutorial`, `_dismissTutorial`, the import).
   `GameScreen` no longer gates anything on `tutorialSeen`.

2. **Build a dedicated tutorial-tour screen** (new file, sibling to
   `practice_screen.dart`, e.g. `lib/presentation/screens/tutorial_tour_screen.dart`)
   hosting steps 1-5 on a small hand-scripted board (4x4 or 5x5, NOT any real
   `Difficulty`). It reuses `BoardWidget`/`GameEngine` directly (`isValidChain`,
   `collapseChain`, `applyDrop`, `evaluateStatus`) against a hand-authored
   `BoardState` — no `DailySeeder`, no submit path, no move-budget or
   leaderboard interaction, so it never touches the dual-engine invariant or
   `kMovesPerDay`. Each step uses its own explicit, immutable board fixture
   with a defined transition into the next (step 1's collapse must not
   destroy step 4's ascending-chain example — they get independent fixtures,
   not a single mutating board threaded through all five steps). Steps:
   - **Step 1 — Merge anywhere (interactive):** board starts with an obvious
     adjacent equal-tier pair. A dimmed backdrop with a cutout spotlights
     those exact cells; advancing requires the player to actually perform
     that drag (real `onChain` callback), not tap "Next". The dim/scrim
     layer is `IgnorePointer` over the exposed board region — only the
     Skip/Next chrome outside that region is hit-testable — so it never
     swallows the drag before `BoardWidget`'s own `GestureDetector` sees it.
   - **Step 2 — Moves budget:** spotlight cutout anchored to the real
     `MovesCounter` widget (via a dedicated `GlobalKey` attached alongside
     its existing key — see task 3 — → `RenderBox` rect), text explains the
     fixed per-day budget.
   - **Step 3 — Drop mechanics:** explains new tiles fill empty cells after
     each merge, and that the drop-tier band widens as the game progresses
     (mirrors `dropCap(n) = min(6, 2 + n/6)` in `lib/domain/constants.dart` —
     described qualitatively, not as a formula).
   - **Step 4 — Chain rule (corrected):** teaches the actual rule — a chain
     step may stay level or go up exactly one tier, never down, never
     skipping (`GameEngine.canFollow`). Spotlights a 3-tile ascending example
     on its own fixture board.
   - **Step 5 — Deadlock (interactive, post-collapse refill):** corrected
     twice now. Round 1's "one empty cell per drop" broke `applyDrop`'s own
     precondition after the first call. Round 2's fix ("drop tiles onto a
     board with several empties, deterministic via a fixed seed") was
     *engine-logic-wrong*, not just underspecified: `applyDrop` only adds
     tiles into empty cells — it never removes a tile or touches an existing
     adjacency. So a board that starts with a legal merge available keeps
     that same legal pair sitting there no matter what drops happen around
     it; drops alone can never *cause* a deadlock. A board with zero legal
     pairs among its placed tiles is already deadlocked by definition
     (`GameEngine.hasMergeAvailable` only inspects filled-cell adjacencies —
     empty cells don't matter to it), so "watch drops lock it" was never a
     real transition, just an already-locked board with padding filling in.
     The only way a board actually *enters* deadlock is losing its last
     legal pair to a **merge**, whose refill then fails to rescue it — which
     is exactly how real runs end. Step 5 is therefore: its own fixture
     board has **exactly one legal merge remaining**; the player performs it
     (same real `onChain` interaction as step 1, spotlighted); the resulting
     refill (via `GameEngine.applyDrop`, tiers/seed hand-authored and
     discovered/pinned the same way as before) is chosen so none of the
     newly dropped tiles create a new adjacency; `GameEngine.evaluateStatus`
     then reports `GameStatus.deadlocked`, asserted by a dedicated test.
     Narratively stronger too — the player's own last move is what locks the
     board, not passive weather. The refill plays back tile-by-tile with
     brief delays for legibility — driven by **one** cancellable
     `Timer`/`AnimationController` owned by the tour screen's state, canceled
     on `dispose` and on any phase change (Skip, navigation away), so a
     delayed callback can never fire `setState` after the widget is gone or
     after the player has already left the step.

3. **Spotlight/coachmark primitive**: one small reusable widget (dimmed
   backdrop + rectangular cutout around a target rect, with title/body text
   and Next/Skip) used by steps 2, 4, 6, and 7. Target rects come from
   **dedicated `GlobalKey`s attached to wrapper widgets around each spotlight
   target** — the existing `Key('tier-${d.name}')` / `Key('practice-${d.name}')`
   / `MovesCounter` keys are plain `Key`s used by existing widget tests and
   are left untouched; the tour adds its own `GlobalKey`s alongside them,
   read via `RenderBox` once a frame after layout. Not a new package — built
   on `Stack`/`CustomPainter` or `ColorFiltered` + `ClipPath`, consistent with
   the existing overlay's `Material`/dark-scrim style.

4. **Step 6 — Tier-select spotlight**: after step 5, pop back to
   `TierSelectScreen` (already the app's `home`). `TierSelectScreen` owns the
   tour's continuation as an explicit phase in its state (see task 6):
   spotlight each `Difficulty` card in turn, explaining what grid size /
   starting-tile count mean for difficulty (smaller grid + fewer starting
   tiles = less room to plan = harder, despite the numbers going down), and
   explicitly call out the practice button ("off-leaderboard, replay anytime,
   no move budget"). Cards live in a scrollable `ListView`, which is lazy —
   a card far enough off-screen has no mounted element, so its `GlobalKey`'s
   `currentContext` can be null. Two-phase measurement: first scroll
   approximately to the target's index via a `ScrollController`
   (`animateTo`/`jumpTo` from an estimated per-card extent), then, once its
   context is non-null, call `Scrollable.ensureVisible` for the precise
   final position before reading its `RenderBox`.

5. **Step 7 — Leaderboard walkthrough**: `LeaderboardScreen` gains an
   optional tutorial-mode entry (e.g. a constructor flag) rather than
   `TierSelectScreen` reaching into a pushed route's internals — the phase
   machine lives in `TierSelectScreen`, but step 7's spotlight targets
   (Global/Friends toggle, period tabs, a row) live inside `LeaderboardScreen`
   itself, so that screen owns rendering its own coachmark step and reports
   completion back the same way `_startTier`'s pushed `GameScreen` already
   does — via the `Navigator.push(...).then((result) => ...)` pattern already
   used elsewhere in `tier_select_screen.dart` — so `TierSelectScreen` learns
   when to finish/persist the tour without owning cross-route widget state.
   Spotlights only the controls that actually exist for this session:
   - `widget.leaderboard == null` (offline / not configured): skip the real
     screen entirely, show a static explainer slide instead.
   - `friendsService == null` (online, friends disabled): open the real
     screen but skip the Global/Friends toggle spotlight (it isn't rendered).
   - Board still loading / empty / errored when its step is reached: skip
     the row spotlight and fall back to explaining rows in text, rather than
     pointing at a spinner or an empty-state message.

6. **Trigger + persistence**: the tour is one explicit phase machine owned by
   `TierSelectScreen`'s state (not implicit navigation), covering: fixed
   board (steps 1-5) → tier-select spotlight (step 6) → leaderboard spotlight
   (step 7) → done. `TierSelectScreen` checks `profile.settings.tutorialSeen`
   once in `initState` (same field, same semantics as today — no new storage
   fields, no per-step progress); if false, the phase machine starts before
   the player can interact with real tier cards, and normal tier-card/menu
   interaction is blocked for the duration. A `PopScope` on the tour's pushed
   routes prevents an Android back-gesture from silently exiting the tour
   without triggering the same completion path Skip uses. `tutorialSeen` is
   persisted `true` the moment the tour ends, whether by finishing step 7 or
   by tapping Skip at any point — **the tour stays visible (e.g. a brief
   spinner state on its final frame) until that write is confirmed durable**,
   only then unwinding back to plain `TierSelectScreen` and re-enabling
   normal navigation (see the persistence design below). An interrupted
   (app-killed) tour before that point simply restarts from step 1 next
   launch.
   **Real fix for the startup profile-write race** (corrected three times
   now — see the review log). Round 1's "wait for cubit `.load()`" was
   unrelated to the actual race. Round 3's "`await Future.wait([...four
   prize checks])` before saving" put four network-backed calls on the Skip
   button's critical path. Round 4's over-correction — fire-and-forget the
   write entirely, never await it — broke a real invariant instead: the tour
   would report itself complete (and re-enable navigation, including the
   path to Profile → delete-my-data) before `tutorialSeen` was actually
   durable, so an app kill or an immediate account deletion right after Skip
   could either re-show the tour needlessly or — worse — let the queued
   write land *after* an account deletion wipes Hive, silently reviving a
   `tutorialSeen: true` field into what should be a fresh, deleted profile.
   The actual fix: `EngagementCubit` gains one new public method,
   `Future<bool> markTutorialSeen()` (its private `_serializedPrizeCommit`
   queue, `lib/application/engagement_cubit.dart:444`, stays private — a
   method-visibility annotation can't make a `_`-prefixed method callable
   from another library; the fix is a dedicated public entry point, not
   relaxed visibility on the private one). It enqueues the `tutorialSeen`
   write onto the *same* queue the four prize-check writers already
   serialize through — so it's correctly ordered against them regardless of
   arrival order — and resolves once that queued commit actually finishes
   (verified against the persisted profile, since the queue's internal error
   handling already swallows writer exceptions rather than rethrowing them).
   **The tour's UI awaits this call** before dismissing and re-enabling
   navigation. This is always fast: verified directly against
   `checkDailyPrizes`/`checkWeeklyPrizes`/etc. that each prize checker
   `await`s its network `fetchRanks` call *before* entering
   `_serializedPrizeCommit` — only the resulting local `storage.saveProfile`
   write happens inside the queue, so nothing queued there ever blocks on
   network. `markTutorialSeen()`'s wait is bounded by local Hive I/O only.
   **Completion is idempotent, guarded, and handles failure**: a single
   `bool _completing` (same guard idiom the old `TutorialOverlay._dismissed`
   used) ensures a double Skip-tap or a race between Skip and the natural
   step-7-finish path only calls `markTutorialSeen()` once at a time, and the
   tour's UI shows a brief waiting state on its final frame while that call
   is in flight. **On `markTutorialSeen()` returning `false`** (the queued
   write didn't verify as landed): clear `_completing`, keep the tour open
   rather than getting stuck showing a spinner forever, and surface a brief
   retry affordance — completion (and the analytics `tutorial_completed`
   event) is only logged after a `true` result.

7. **Skip**: a visible "Skip" affordance present on every step across all 7
   (fixed board, tier-select spotlight, leaderboard spotlight), wired through
   the same phase machine and persistence path as task 6.

8. **Analytics**: log `tutorial_started`, `tutorial_skipped(step)`, and
   `tutorial_completed` through the existing optional `AnalyticsService` seam
   (already threaded into `TierSelectScreen` and `EngagementCubit` via
   `onAnalyticsEvent`) — cheap, and otherwise there's no way to tell if the
   tour is helping or people bail on step 2.

9. **Tests**:
   - Tutorial-tour screen: step 1's real drag advances the tour; step 5's
     exact scripted fixture reaches `GameStatus.deadlocked`
     (`hasMergeAvailable == false`) asserted directly, not just "some slide
     shown."
   - `TierSelectScreen`: tour auto-launches when `tutorialSeen` is false;
     Skip at an arbitrary step persists completion and returns to plain
     tier-select; a spotlight target scrolled off-screen is still correctly
     measured/highlighted; back-gesture during the tour does not exit it
     without persisting.
   - `LeaderboardScreen` step: friendsService-null hides the toggle
     spotlight; empty/error board state falls back to the text explainer
     instead of pointing at nothing.
   - **Existing fixtures**: every current `TierSelectScreen` test that
     constructs fresh storage must set `tutorialSeen: true` in its fixture
     profile, or the auto-launching tour will intercept those tests' taps on
     real tier cards.
   - `EngagementCubit`: a test driving a prize-check commit and
     `markTutorialSeen()` through the shared queue concurrently, asserting
     both writes land (neither is lost) regardless of which is enqueued
     first, and that an injected prize-check error doesn't prevent
     `markTutorialSeen()` from landing.
   - **Durability boundary**: a widget test asserting the tour stays visible
     (blocks Skip/finish from actually dismissing) until `markTutorialSeen()`
     resolves, and that no queued write remains outstanding once the tour
     has visually dismissed — i.e. an account-deletion flow immediately
     after the tour closes can never race a still-pending tutorial write.
   - **Failure/retry**: a test where `markTutorialSeen()` first resolves
     `false` then `true` on a second attempt — the tour must stay open and
     retryable after the first failure, not stuck spinning forever.
   - **Accessibility**: a test invoking the tutorial-only semantic merge
     action directly on steps 1 and 5 (bypassing the raw drag) and asserting
     it advances the tour exactly like the real gesture would.

## Key decisions & tradeoffs

- **Fixed scripted board, not the real daily board or `PracticeSeeder`.**
  Chosen so exact tile positions are known in advance (required to spotlight
  specific cells) and so the tour never spends a real move, never risks
  desyncing `movesRemaining`/`moveLog`, and never touches the
  Dart/TS-engine-parity surface (`CLAUDE.md`'s dual-engine invariant) — it
  reads `GameEngine` but produces no submitted run.
- **Corrected step 4**: the original ask said chains "can decrease tiers,"
  which contradicts `GameEngine.canFollow` (equal-or-+1 only, never
  descending/skipping). The plan teaches the real rule instead of the
  as-requested wrong one.
- **Step 5 is an interactive merge-then-refill**, not passive drops (chosen
  over jumping straight to a pre-built deadlocked `BoardState`, and corrected
  in round 3 from an earlier drops-only design that turned out to be
  engine-logic-impossible — see task 2). More scripting work, but the player
  causes the lock with their own last legal move rather than being told
  about it.
- **Single continuous first-launch flow**, not gated behind tapping a real
  tier. Chosen because steps 6-7 need `TierSelectScreen`/`LeaderboardScreen`
  themselves as the teaching surface, so splitting the trigger across two
  different first-time moments would be more state to track for no benefit.
- **One shared spotlight/coachmark widget** reused for steps 2, 4, 6, 7 —
  justified reuse (4+ call sites), not a speculative abstraction.
- **No per-step resume**: single `tutorialSeen` bool, matching the existing
  field exactly. An interrupted tour restarts from step 1 rather than
  resuming mid-tour — least state, and restarting a first-launch tour once in
  a rare app-kill is a non-issue.
- **Old `TutorialOverlay` deleted outright**, not kept as a fallback — its
  entire teaching content (merge/moves/deadlock) is a strict subset of the
  new tour.
- **Every difficulty card gets its own spotlight** (kept as explicitly
  requested), even though Codex's review suggested spotlighting one
  representative card plus a text summary to cut scroll/`GlobalKey`
  complexity. Rejected: the user specifically asked for each difficulty to
  be spotlighted individually with its own description — this is a product
  choice already settled in the grill, not a technical defect to fix.
- **No broad accessibility contract** (screen-reader focus announcements,
  reduced motion, text-scale testing) beyond what the rest of
  `lib/presentation` already does — a repo-wide grep found zero existing
  `Semantics`/`semanticLabel` usage anywhere in `lib/presentation`, so
  holding only this feature to a standard nothing else in the codebase meets
  would be scope creep, not consistency. Visible Skip/Next labels and
  reasonable tap targets (matching existing button patterns) are the bar.
  **One narrow exception, accepted in round 2**: `IgnorePointer` on the scrim
  only blocks touch hit-testing, not the semantics tree — a screen reader
  could still reach and activate a dimmed-but-technically-present background
  control (e.g. a real tier card) while the tour's modal is visually over it.
  This is a correctness gap, not a polish one.
  **Corrected in round 4**: `ExcludeSemantics` excludes a whole widget
  subtree, not an arbitrary painted region — "everything outside the
  spotlight cutout" isn't a semantics boundary Flutter can express, so
  round 2/3's "wrap the dimmed background" framing wasn't actually
  implementable as stated. The real approach: wrap the **entire underlying
  screen** in `ExcludeSemantics` while any tour step is active (not just the
  part outside a cutout), and let the coachmark widget itself be the sole
  semantic surface — it describes the target and, for steps 1 and 5, exposes
  a **tutorial-only semantic action** ("Merge highlighted tiles") that
  invokes the exact same `onChain(path)` handler the real drag would call,
  using the path the fixture already knows in advance. This is narrower than
  retrofitting `BoardWidget`'s real gameplay interaction (still out of
  scope, see Risks) — it only works because the tutorial's fixture already
  knows the one correct path ahead of time, which real gameplay never does.

## Risks / open questions

- Exact copy/wording for each step's title/body is not scripted here — write
  it during implementation, keeping the tone of the existing overlay's copy.
- The step-5 fixture (one legal merge remaining, refill that doesn't rescue
  it) needs hand-tuning against the chosen 4x4 or 5x5 board and a fixed
  `Prng` seed to reliably land on a true deadlock; fully deterministic once
  authored, so it's verified once and pinned by test.
- Spotlight rect computation via `GlobalKey`→`RenderBox` needs the target
  widget already laid out; on `TierSelectScreen`/`LeaderboardScreen` this
  means waiting a frame (`addPostFrameCallback`) before showing each
  spotlight step, consistent with existing patterns in this codebase (e.g.
  `WidgetsBinding.instance.addPostFrameCallback` already used in
  `tier_select_screen.dart`).
- **The tutorial itself is screen-reader-completable** (steps 1 and 5 expose
  a tutorial-only semantic merge action, see Key decisions), but **real
  gameplay is not** — `BoardWidget`'s chain-drag gesture still has no
  semantic alternative anywhere outside the tutorial. This feature closes
  the gap for itself only; closing it for the shipped game is a separate,
  larger `BoardWidget` change and stays out of scope here.
- **Startup profile-write race — fixed for this feature's write, not
  project-wide** (four rounds of back-and-forth on this, see the review
  log — including catching a real account-deletion-vs-queued-write race
  introduced by an earlier over-correction): `tutorialSeen` shares the same
  startup window as four unawaited prize-catch-up writers in `main.dart`.
  The final design (task 6) routes the tour's write through a new
  `EngagementCubit.markTutorialSeen()`, which enqueues onto the *same*
  internal queue the four prize writers already serialize through, and the
  tour's UI awaits it — blocking dismissal/navigation until it's durable —
  rather than either racing it or fire-and-forgetting it. This genuinely
  fixes the specific collision this feature is exposed to, without the
  general serialized-`updateProfile` refactor for *every* profile writer in
  the app, which remains out of scope exactly as it was in the prior
  leaderboard-prizes plan (git `0161973`).

## Out of scope

- No changes to `GameEngine`, `canFollow`, scoring, or any dual-engine
  surface — this is presentation-only.
- No new persisted fields beyond reusing existing `tutorialSeen`.
- No changes to `PracticeScreen` or the real daily-board flow.
- No localization of the new copy (matches existing hardcoded English strings
  throughout the app).
