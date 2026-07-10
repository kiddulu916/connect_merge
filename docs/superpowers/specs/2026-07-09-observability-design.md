# Observability (Crash Reporting + Analytics) — Design

Date: 2026-07-09
Status: Approved (pending spec self-review)

## Summary

Connect Merge currently has zero visibility into what happens on real
devices: no crash/error reporting and no analytics anywhere in `lib/`.
Failures are either invisible (uncaught exceptions) or silently swallowed
(`catch (_) {}` blocks around Supabase, ads, and friend-invite flows in
`main.dart` and several `infrastructure/` services). This spec adds crash
reporting and a small, deliberately narrow analytics event set, using
Firebase (Crashlytics + Analytics) on the free tier, wired the same way the
app already handles optional backend services: gracefully absent when
unconfigured, never blocking gameplay.

Priority order, per stakeholder input: crash/error visibility first,
analytics riding along on the same integration since Crashlytics and
Analytics are natively linked (Crashlytics attaches recent Analytics events
as breadcrumbs leading up to a crash).

## Why Firebase

Three options were considered: Firebase (Crashlytics + Analytics, one
vendor), Sentry alone (strong on errors, weak on funnel/analytics), and a
Sentry + PostHog split (best-of-breed but two SDKs, two dashboards, two
consent surfaces). Firebase was chosen because it satisfies the actual
constraints: free at unlimited volume, single SDK family, and the
crash↔analytics linkage directly buys "what was the user doing right before
this broke" without extra wiring. Setup cost is a Firebase project plus
`google-services.json` (Android) / `GoogleService-Info.plist` (iOS) added to
the repo, and Google Play Services becomes a hard Android dependency — not a
new category of dependency, since `google_mobile_ads` already pulls in
Google's ad SDK.

## Architecture

Two new thin services in `lib/infrastructure/`, following the existing
one-package-per-service convention (`AdService` wraps `google_mobile_ads`,
`AuthService` wraps Supabase auth, `NotificationService` wraps
`flutter_local_notifications`):

- **`CrashReportingService`** (wraps `firebase_crashlytics`)
  - `void recordError(Object error, StackTrace? stack, {bool fatal = false})`
  - `void log(String message)` — breadcrumb, no PII
- **`AnalyticsService`** (wraps `firebase_analytics`)
  - `void logEvent(String name, {Map<String, Object?>? params})`
  - `NavigatorObserver get navigatorObserver` — automatic screen-view
    tracking, attached via `MaterialApp.navigatorObservers`

Both take an injectable underlying client in their constructor (defaulting
to the real Firebase plugin singleton), mirroring how `AuthService` takes a
`SupabaseClient` rather than importing `supabase_flutter` APIs directly
throughout the app. This is what makes them testable without a platform
channel present.

### Initialization (`main.dart`)

- `Firebase.initializeApp()` is called before `runApp()`, wrapped in the same
  try/catch graceful-degradation pattern `initSupabase()` already uses today:
  on failure (missing config, or a test/CI environment with no platform
  channels), both services become no-ops rather than blocking cold launch —
  matching how `auth`/`leaderboard`/`friends` are already nullable and the
  app already runs fully offline without Supabase.
- `runZonedGuarded` wraps the existing `runApp(...)` call.
- `FlutterError.onError` and `PlatformDispatcher.instance.onError` both
  forward into `CrashReportingService.recordError` (non-fatal by default,
  matching Firebase's standard Flutter crash-capture recipe).
- `AnalyticsService.navigatorObserver` is added to
  `MaterialApp.navigatorObservers` in `ConnectMergeApp.build`.

This is additive to `main.dart` — no restructuring of the existing
Supabase/ads/notifications initialization sequence.

## Instrumentation plan

### Crash/error reporting

- **Automatic**: every uncaught exception, via the global handlers above. No
  per-call-site work required.
- **Explicit non-fatal `recordError` calls**, added at the existing
  swallow-and-fallback points, without changing their fallback behavior —
  this only adds visibility on top of behavior that stays the same:
  - `main.dart`: the `catch (_) { auth = null; leaderboard = null; friends = null; }`
    block around Supabase init/sign-in.
  - `main.dart`: `_redeemInvite`'s `catch (_) { message = 'Network error adding friend.'; }`.
  - Equivalent silent catches inside `AdService`, `LeaderboardService`, and
    `FriendsService` (audited during implementation — any `catch` that
    currently discards its error without rethrowing or logging gets a
    `recordError` call added).

### Analytics (v1 event set)

Deliberately narrow — a fuller taxonomy (cosmetics, loot chest, almanac,
etc.) is out of scope for this spec and should be a fast follow once this
integration proves useful:

| Event | Params | Fired from |
|---|---|---|
| `screen_view` | (automatic) | `NavigatorObserver`, all screens |
| `run_completed` | `difficulty`, `score`, `highestTier`, `moveCount` | `GameCubit`, on run completion (moves exhausted or deadlock) |
| `onboarding_completed` | — | `DisplayNameScreen`, on successful `setDisplayName` |
| `ad_load_failed` | `adType` (moves/hints/undos/continue) | `AdService`, on load failure callback |
| `ad_shown` | `adType` | `AdService`, on successful ad completion |
| `duel_started` | `difficulty` | `DuelCubit`, on `receiveChallenge` |
| `duel_completed` | `difficulty`, `won` | `DuelCubit`, on duel resolution |
| `streak_broken` | `streakType` (daily/per-tier), `length` | `EngagementCubit`, wherever streak-break is currently detected |

## Fail-safe behavior

Observability must never become a new failure mode. Every call into
`CrashReportingService`/`AnalyticsService` is wrapped so a Firebase-side
failure (network down, plugin missing, quota exceeded) is swallowed
internally and never bubbles up — it cannot block or delay gameplay, ad
flow, or Supabase calls. This mirrors `ConsentService`'s existing
`PlatformException`/`MissingPluginException` handling for the UMP channel.

## Testing

`flutter_test` has no real platform channels, so both services are
constructed with a fake/null underlying client in tests, exactly like
`AuthService` is tested against a fake `SupabaseClient`. No existing test
needs to change. New tests:

- `CrashReportingService`/`AnalyticsService` unit tests (fake client,
  assert calls made, assert no exception escapes on a simulated failure).
- Call-site tests confirming each v1 analytics event fires with the right
  params at the right trigger (e.g. `GameCubit` test asserting
  `run_completed` fires once per completed run with correct `score`).

## Privacy

No PII is collected. Auth is fully anonymous
(`AuthService.ensureSignedIn` calls `signInAnonymously()`); event params are
limited to gameplay data (difficulty, score, tier, streak length) and crash
stack traces. The existing UMP consent flow (`ConsentService`,
`isPrivacyOptionsRequired`/`showPrivacyOptionsForm`) is scoped specifically
to *ad personalization* consent (EEA/UK) and is untouched by this design.

**Assumption**: no additional consent gate is needed for crash/analytics
collection, since it is non-personalized, contains no identifying data, and
is not used for ad targeting. If this assumption is wrong for your
jurisdiction/legal requirements, the fix is a small gate
(`AnalyticsService`/`CrashReportingService` check a stored consent flag
before initializing) — not a redesign.

## Out of scope

- **CI pipeline** (running `flutter test`/`deno test` on PRs) — a separate,
  previously-identified gap; not part of this spec.
- **Fuller analytics taxonomy** — cosmetics/loot-chest economy events,
  almanac progress, XP/level events. Deferred until the v1 event set proves
  useful.
- **User-identifier correlation** between crash reports and a specific
  player's move log (e.g. `setUserIdentifier` with the anonymous Supabase
  user id) — a natural follow-up for debugging replay-determinism issues,
  but not needed for v1 crash visibility.
- **Firebase console configuration** — dashboards, alerting rules, BigQuery
  export, budget alerts. Console setup, not code; done separately once the
  SDKs are integrated.
- **Existing test suite changes** — no current test should need modification
  under this design (see Testing section).
