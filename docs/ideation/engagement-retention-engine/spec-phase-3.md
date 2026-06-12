# Implementation Spec: Engagement & Retention Engine - Phase 3

**Contract**: ./contract.md
**Estimated Effort**: L
**Prereq**: Phase 1 (wallet + return moments). Parallelizable with Phase 2.

## Technical Approach

Phase 3 converts the **passive** friends leaderboard into **active** competition using the property the game already has for free: every player on a given `(date, difficulty)` plays the byte-identical board. That makes 1v1 comparison trivially honest — "I scored 4096 on today's Hard, beat me" can be settled by the deterministic board plus the existing replay-verified leaderboard rows, with **zero new backend** ($0 pillar).

Three features, all built on existing infrastructure: **async duels** extend the already-built `DeepLinkService` (which currently parses `mergecount://invite/<code>`) with a duel link form; **rivalries** store a chosen rival on `PlayerProfile` and reuse `LeaderboardService`/friends rows to render "you vs them" and fire a local notification when passed; and the **richer share card** upgrades the existing `ScoreSharer` PNG pipeline into a screenshot-worthy rendered card.

The duel's challenge payload travels *in the link* (`date`, `difficulty`, challenger score + name). It is not trusted for ranking — the leaderboard remains the source of truth — so we don't need a server to store duels. The friend plays the same seeded board and the app compares the two scores locally, then offers a share-back. This keeps the whole social loop inside the free tier.

## Feedback Strategy

**Inner-loop command**: `flutter test test/infrastructure/deep_link_service_test.dart test/application/rivalry_test.dart`

**Playground**: Dart test suite for the pure parsers/comparators; the running app for share-card rendering and the deep-link round-trip.

**Why this approach**: The riskiest logic (link parse/encode round-trip, rival pass detection) is pure and string-based — fast to pin with unit tests; only the rendered card needs eyes.

## File Changes

### New Files

| File Path | Purpose |
| --------- | ------- |
| `lib/domain/models/duel_challenge.dart` | Immutable `{ date, difficulty, challengerName, challengerScore }` + pure encode/decode. |
| `lib/application/duel_cubit.dart` | Holds an incoming challenge, compares after the friend's run, offers share-back. |
| `lib/application/rivalry_cubit.dart` | Set/clear a rival; compute "you vs them" deltas from leaderboard/friends rows. |
| `lib/presentation/widgets/duel_banner.dart` | "You were challenged — play this board" call-to-action. |
| `lib/presentation/widgets/rival_indicator.dart` | Persistent you-vs-rival chip on the game/result screens. |
| `lib/presentation/widgets/share_card.dart` | The rendered result card widget (boundary-captured to PNG). |
| `lib/infrastructure/share_card_renderer.dart` | Widget→PNG via `RepaintBoundary`/`toImage` (seam-isolated, like `ScoreSharer`). |
| `test/infrastructure/deep_link_service_test.dart` (extend) | Duel link encode/decode round-trip + malformed inputs. |
| `test/application/rivalry_test.dart` | Pass detection, delta math, missing-rival cases. |
| `test/application/duel_cubit_test.dart` | Compare win/lose/tie; same-board guarantee. |

### Modified Files

| File Path | Changes |
| --------- | ------- |
| `lib/infrastructure/deep_link_service.dart` | Add `parseDuel(Uri)` for `mergecount://duel/<date>/<diff>/<score>/<name>` (+ https form); queue cold-start duels like invite codes. |
| `lib/infrastructure/storage_service.dart` | `PlayerProfile`: add `String? rivalId`, `String? rivalName`, `Map<String,int> lastSeenRivalScoreByTier` (migration-free). |
| `lib/infrastructure/notification_service.dart` | Add `kRivalPassedId` notification when a fetched rival score exceeds the player's on a tier. |
| `lib/presentation/screens/score_share_screen.dart` | Replace/augment the emoji share with the rendered `share_card`; add "Challenge a friend" (duel link) + "Set as rival". |
| `lib/presentation/screens/friends_screen.dart` | Add "Set rival" affordance per friend row; show rival highlight. |
| `lib/main.dart` | Wire `parseDuel` into the existing deep-link bootstrap + provide `DuelCubit`/`RivalryCubit`. |

## Implementation Details

### Async duels

**Pattern to follow**: `lib/infrastructure/deep_link_service.dart` (pure `parseInviteCode` + cold-start queue), `lib/infrastructure/leaderboard_service.dart` (source of ranking truth).

**Overview**: A duel link encodes the challenger's `(date, difficulty, score, name)`. The recipient opens it, plays the identical seeded board, and the app compares scores locally; ranking still flows through the verified leaderboard.

```dart
// duel_challenge.dart
class DuelChallenge {
  final String date; final Difficulty difficulty;
  final String challengerName; final int challengerScore;

  Uri toUri() => Uri.parse(
    'mergecount://duel/$date/${difficulty.name}/$challengerScore/${Uri.encodeComponent(challengerName)}');

  static DuelChallenge? fromUri(Uri uri) { /* validate scheme/host/segments */ }
}
```

**Key decisions**:
- Challenge data is **display-only**, never authoritative — the deterministic board + verified leaderboard prevent a forged-score link from polluting rankings. So no backend storage is needed ($0).
- Reuse the existing cold-start `pendingCode` queueing mechanism for duels opened before the app is ready.

**Implementation steps**:
1. `DuelChallenge` encode/decode (pure).
2. `DeepLinkService.parseDuel` + queue.
3. `DuelCubit`: store incoming challenge; on the recipient completing that `(date,diff)` board, compare and emit win/lose/tie.
4. `duel_banner` CTA → routes to the challenged board.
5. Share-back builds a fresh duel link from the recipient's result.

**Feedback loop**:
- **Playground**: extend `test/infrastructure/deep_link_service_test.dart`.
- **Experiment**: `fromUri(toUri(x)) == x` for many `x`; malformed/legacy links return null; names with `/` and unicode survive round-trip.
- **Check command**: `flutter test test/infrastructure/deep_link_service_test.dart`

### Rivalries

**Pattern to follow**: `engagement_cubit.dart` (profile-backed state), `leaderboard_service.dart fetch` (rival score source).

**Overview**: Pick a rival; the app shows a persistent you-vs-them delta and fires a local "your rival passed you" nudge when a fetch shows the rival ahead on a tier the player hasn't beaten today.

```dart
// rivalry_cubit.dart
bool rivalPassedMe({required int myScore, required int rivalScore,
                    required int lastSeenRivalScore}) =>
    rivalScore > myScore && rivalScore > lastSeenRivalScore;
```

**Key decisions**:
- Pass detection compares against `lastSeenRivalScoreByTier` so the nudge fires once per pass, not every fetch (wholesome — no spam).
- Rival data comes from already-fetched friends/leaderboard rows; no new query type, no new cost.

**Feedback loop**:
- **Experiment**: rival overtakes once ⇒ one nudge; repeated fetches with no change ⇒ no nudge.
- **Check command**: `flutter test test/application/rivalry_test.dart`

### Richer share card

**Pattern to follow**: `lib/infrastructure/score_sharer.dart` (PNG → Facebook/share-sheet seams already exist).

**Overview**: Render a polished card (final board art, score, highest tile, streak flex, rank badge, level) to PNG and feed the existing `ScoreSharer`. Broad-reach growth surface.

**Key decisions**: Render via `RepaintBoundary` + `RenderRepaintBoundary.toImage`; isolate the capture in `share_card_renderer` so the widget stays testable-by-eye and the pipeline stays mockable, matching the `ScoreSharer` abstraction.

**Feedback loop**:
- **Playground**: running app — share to the OS sheet, inspect the image.
- **Experiment**: render with min board (all empty), a jackpot board, long display name — no overflow/clipping.
- **Check command**: `flutter run` then trigger share on the result screen.

## Data Model

### State Shape (PlayerProfile additions)

```dart
final String? rivalId;
final String? rivalName;
final Map<String,int> lastSeenRivalScoreByTier; // default {}
```

## Testing Requirements

### Unit Tests

| Test File | Coverage |
| --------- | -------- |
| `test/infrastructure/deep_link_service_test.dart` | Duel encode/decode round-trip; malformed + legacy-invite coexistence. |
| `test/application/rivalry_test.dart` | Pass detection once-per-pass; delta math; null rival. |
| `test/application/duel_cubit_test.dart` | Win/lose/tie compare; recipient plays the SAME `(date,diff)` board. |

**Key test cases**:
- Duel link with a unicode / slash-containing name round-trips intact.
- A forged high score in a duel link does NOT change any leaderboard row (display-only).
- Rival pass fires exactly one notification per overtake.

### Manual Testing

- [ ] Generate a duel link, open on a second device, play the same board, see auto-comparison.
- [ ] Set a rival, see the you-vs-them chip, get a nudge after they pass you.
- [ ] Share card renders cleanly for short and long names and extreme boards.

## Error Handling

| Error Scenario | Handling Strategy |
| -------------- | ----------------- |
| Duel link for a past date | Show "this challenge has expired" (board no longer today); offer today's tier instead. |
| Rival fetch fails (offline) | Degrade gracefully — show last-known delta, no nudge. |
| Share render fails | Fall back to the existing emoji/text share. |

## Failure Modes

| Component | Failure Mode | Trigger | Impact | Mitigation |
| --------- | ------------ | ------- | ------ | ---------- |
| Duel link | Forged score | Hand-edited link | Recipient sees fake target | Display-only; ranking via verified leaderboard; label as "their claim". |
| Duel link | Cold-start loss | Opened before app ready | Challenge dropped | Reuse `pendingCode` queue + replay after boot. |
| Rivalry | Nudge spam | Fetch loop re-detects same pass | Annoyance, churn | Compare to `lastSeenRivalScoreByTier`; update on send. |
| Share card | Layout overflow | Long name / extreme board | Clipped/ugly card | Constrain + ellipsize; test extremes before ship. |

## Validation Commands

```bash
flutter analyze
flutter test test/infrastructure/deep_link_service_test.dart
flutter test test/application/
flutter test
```

## Rollout Considerations

- **Feature flag**: none required; duel/rival are opt-in surfaces.
- **Monitoring**: duel link generation + open rate (viral K-factor proxy); rival-set rate.
- **Rollback plan**: additive; deep-link parser keeps invite handling intact if duel parsing is reverted.

## Open Items

- [ ] Duel link host for the https form (reuse `mergecount.app/invite` host pattern → `/duel`).
- [ ] Whether duels award a small coin bonus on win (ties into Phase 2 economy; recommend a tiny win bonus, capped daily).

---

_This spec is ready for implementation. Follow the patterns and validate at each step._
