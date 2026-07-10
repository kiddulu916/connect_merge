# Observability (Crash Reporting + Analytics) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Firebase Crashlytics (crash/error reporting) and Firebase Analytics (a narrow v1 event set) to Connect Merge, wired the same way the app already handles optional backend services — gracefully absent when unconfigured, never blocking gameplay.

**Architecture:** Two new thin `infrastructure/` services (`CrashReportingService`, `AnalyticsService`) mirror the existing seam pattern used by `AuthService`/`LeaderboardService` (an injectable transport function, defaulting to the real plugin call, so tests never touch a platform channel). `main.dart` constructs both behind a try/catch exactly like `initSupabase()`, wraps `runApp` in `runZonedGuarded`, and threads the two services down as plain optional callbacks into `GameCubit`/`EngagementCubit`/`DuelCubit` (matching those cubits' existing decoupled-callback convention, e.g. `onTierCompleted`/`onCoinsEarned`) and as direct optional service fields into screens (matching how `AdService`/`LeaderboardService` are already passed to screens directly).

**Tech Stack:** Flutter/Dart, `firebase_core` + `firebase_crashlytics` + `firebase_analytics` (free tier), `flutter_test`.

## Global Constraints

- No PII is ever logged: auth is anonymous (`AuthService.ensureSignedIn` → `signInAnonymously()`), so event params stay limited to gameplay data (difficulty, score, tier, streak length, ad type) and crash stack traces.
- Observability must never become a new failure mode: every call into `CrashReportingService`/`AnalyticsService` swallows its own failures (sync throw or async `Future` rejection) and never bubbles up to block gameplay, ads, or Supabase calls.
- `flutter test` and `flutter analyze` are pure-Dart and must pass after every task in this plan, regardless of whether a real Firebase project has been configured yet. Only an actual on-device `flutter run`/`flutter build apk` needs the real `google-services.json`/`GoogleService-Info.plist` from the Firebase console (a manual, human-only step called out at the end of this plan) — no task's automated verification depends on it.
- Every new optional constructor/field added to an existing class defaults to `null`/no-op, so the app keeps compiling and all existing tests keep passing after each individual task, even before the final integration task wires real values through.
- Firebase init uses `Firebase.initializeApp()` with **no explicit `options:`** (reads native `google-services.json`/`GoogleService-Info.plist` automatically) — this avoids depending on a generated `firebase_options.dart` file that only the FlutterFire CLI can produce, so no task's Dart code depends on the human having run that CLI yet.

---

### Task 1: Firebase dependencies + Android Gradle wiring

**Files:**
- Modify: `pubspec.yaml`
- Modify: `android/settings.gradle.kts:20-25` (plugins block)
- Modify: `android/app/build.gradle.kts:4-8` (plugins block)

**Interfaces:**
- Consumes: nothing.
- Produces: `firebase_core`, `firebase_crashlytics`, `firebase_analytics` packages available for import in Tasks 2-3. The Android Gradle project is wired to apply the Google Services plugin (needed for a real on-device build once a real `google-services.json` is added — a later, human-only step).

- [ ] **Step 1: Add the Firebase packages**

Run:

```bash
flutter pub add firebase_core firebase_crashlytics firebase_analytics
```

Expected: `pubspec.yaml` gains three new entries under `dependencies:` (exact resolved versions are whatever `pub` picks — don't hand-pin them).

- [ ] **Step 2: Declare the Google Services Gradle plugin version**

In `android/settings.gradle.kts`, the `plugins { ... }` block currently reads:

```kotlin
plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.2.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}
```

Add one line so it reads:

```kotlin
plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.2.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
    id("com.google.gms.google-services") version "4.4.2" apply false
}
```

- [ ] **Step 3: Apply the plugin to the app module**

In `android/app/build.gradle.kts`, the `plugins { ... }` block currently reads:

```kotlin
plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}
```

Add the Google Services plugin:

```kotlin
plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}
```

- [ ] **Step 4: Verify (Dart-only checks — no Gradle sync required)**

Run: `flutter pub get`
Expected: resolves cleanly.

Run: `flutter analyze`
Expected: no new errors (the three packages aren't imported by any Dart file yet, so this is just confirming `pubspec.yaml` didn't break resolution).

Note: `flutter build apk`/`flutter run` for Android will now fail at Gradle sync (`google-services.json` not found) until the manual Firebase-console step at the end of this plan. That's expected and doesn't block any later task in this plan, since every later task's verification step uses `flutter test`/`flutter analyze` only.

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml pubspec.lock android/settings.gradle.kts android/app/build.gradle.kts
git commit -m "chore(observability): add Firebase Crashlytics/Analytics dependencies"
```

---

### Task 2: `CrashReportingService`

**Files:**
- Create: `lib/infrastructure/crash_reporting_service.dart`
- Test: `test/infrastructure/crash_reporting_service_test.dart`

**Interfaces:**
- Consumes: `firebase_crashlytics` (Task 1).
- Produces: `CrashReportingService.recordError(Object error, StackTrace? stack, {bool fatal})` and `CrashReportingService.log(String message)`, both fire-and-forget and failure-swallowing. Used by Tasks 5-6 (`GameCubit`/`EngagementCubit`) and Task 9 (`main.dart` global handlers).

- [ ] **Step 1: Write the failing test**

Create `test/infrastructure/crash_reporting_service_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/infrastructure/crash_reporting_service.dart';

void main() {
  group('CrashReportingService', () {
    test('recordError forwards to the injected seam', () {
      Object? capturedError;
      StackTrace? capturedStack;
      bool? capturedFatal;
      final service = CrashReportingService.withSeams(
        recordError: (exception, stack, fatal) async {
          capturedError = exception;
          capturedStack = stack;
          capturedFatal = fatal;
        },
        log: (_) async {},
      );

      final stack = StackTrace.current;
      service.recordError('boom', stack, fatal: true);

      expect(capturedError, 'boom');
      expect(capturedStack, stack);
      expect(capturedFatal, true);
    });

    test('recordError defaults fatal to false', () {
      bool? capturedFatal;
      final service = CrashReportingService.withSeams(
        recordError: (exception, stack, fatal) async {
          capturedFatal = fatal;
        },
        log: (_) async {},
      );

      service.recordError('boom', null);

      expect(capturedFatal, false);
    });

    test('recordError never throws even when the seam throws synchronously',
        () {
      final service = CrashReportingService.withSeams(
        recordError: (exception, stack, fatal) {
          throw StateError('seam exploded');
        },
        log: (_) async {},
      );

      expect(() => service.recordError('boom', null), returnsNormally);
    });

    test('recordError never throws when the seam returns a failing Future',
        () async {
      final service = CrashReportingService.withSeams(
        recordError: (exception, stack, fatal) async {
          throw StateError('async seam failure');
        },
        log: (_) async {},
      );

      expect(() => service.recordError('boom', null), returnsNormally);
      // Let the rejected Future's microtask run so it doesn't surface as an
      // unhandled async error in the test zone.
      await Future<void>.delayed(Duration.zero);
    });

    test('log forwards to the injected seam', () {
      String? captured;
      final service = CrashReportingService.withSeams(
        recordError: (exception, stack, fatal) async {},
        log: (message) async {
          captured = message;
        },
      );

      service.log('breadcrumb');

      expect(captured, 'breadcrumb');
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/infrastructure/crash_reporting_service_test.dart`
Expected: FAIL — `CrashReportingService` isn't defined.

- [ ] **Step 3: Implement `CrashReportingService`**

Create `lib/infrastructure/crash_reporting_service.dart`:

```dart
import 'package:firebase_crashlytics/firebase_crashlytics.dart';

/// Transport seam (mirrors [LeaderboardService]'s [InvokeFn]/[RpcFn]). The
/// default binds to the real [FirebaseCrashlytics] singleton; tests inject a
/// fake so this service's failure-swallowing logic can be exercised without
/// a platform channel.
typedef RecordErrorFn = Future<void> Function(
    Object exception, StackTrace? stack, bool fatal);
typedef LogFn = Future<void> Function(String message);

/// Isolates firebase_crashlytics so the rest of the app never imports the
/// plugin directly (mirrors [AdService]/[AuthService]). Every call swallows
/// its own failures (both a synchronous throw and an async `Future`
/// rejection) — observability must never itself become a new failure mode
/// that blocks gameplay.
class CrashReportingService {
  final RecordErrorFn _recordError;
  final LogFn _log;

  /// Production constructor: wires the seams to the real Crashlytics plugin.
  CrashReportingService()
      : _recordError = ((exception, stack, fatal) =>
            FirebaseCrashlytics.instance
                .recordError(exception, stack, fatal: fatal)),
        _log = FirebaseCrashlytics.instance.log;

  /// Test constructor: inject the transport seams directly.
  CrashReportingService.withSeams({
    required RecordErrorFn recordError,
    required LogFn log,
  })  : _recordError = recordError,
        _log = log;

  /// Record a non-fatal (by default) error with its stack trace. Fire-and-
  /// forget: never throws, regardless of whether the underlying report
  /// succeeds, fails synchronously, or fails asynchronously.
  void recordError(Object error, StackTrace? stack, {bool fatal = false}) {
    try {
      _recordError(error, stack, fatal).catchError((_) {});
    } catch (_) {
      // Observability must never itself become a failure mode.
    }
  }

  /// Attach a breadcrumb (no PII) to any crash report that follows.
  void log(String message) {
    try {
      _log(message).catchError((_) {});
    } catch (_) {
      // Observability must never itself become a failure mode.
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/infrastructure/crash_reporting_service_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/infrastructure/crash_reporting_service.dart test/infrastructure/crash_reporting_service_test.dart
git commit -m "feat(observability): add CrashReportingService"
```

---

### Task 3: `AnalyticsService`

**Files:**
- Create: `lib/infrastructure/analytics_service.dart`
- Test: `test/infrastructure/analytics_service_test.dart`

**Interfaces:**
- Consumes: `firebase_analytics` (Task 1).
- Produces: `AnalyticsService.logEvent(String name, [Map<String, Object?>? params])` (failure-swallowing) and `AnalyticsService.navigatorObserver` (a `NavigatorObserver` for automatic screen-view tracking). Used by Tasks 4-8 (`AdService`, `GameCubit`, `EngagementCubit`, `DuelCubit`, `DisplayNameScreen`) and Task 9 (`main.dart`/`MaterialApp`).

- [ ] **Step 1: Write the failing test**

Create `test/infrastructure/analytics_service_test.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/infrastructure/analytics_service.dart';

void main() {
  group('AnalyticsService', () {
    test('logEvent forwards name and params to the injected seam', () {
      String? capturedName;
      Map<String, Object?>? capturedParams;
      final service = AnalyticsService.withSeams(
        logEvent: (name, params) async {
          capturedName = name;
          capturedParams = params;
        },
      );

      service.logEvent('run_completed', {'score': 42});

      expect(capturedName, 'run_completed');
      expect(capturedParams, {'score': 42});
    });

    test('logEvent works with no params', () {
      String? capturedName;
      final service = AnalyticsService.withSeams(
        logEvent: (name, params) async {
          capturedName = name;
        },
      );

      service.logEvent('onboarding_completed');

      expect(capturedName, 'onboarding_completed');
    });

    test('logEvent never throws even when the seam throws synchronously',
        () {
      final service = AnalyticsService.withSeams(
        logEvent: (name, params) {
          throw StateError('seam exploded');
        },
      );

      expect(() => service.logEvent('run_completed'), returnsNormally);
    });

    test('logEvent never throws when the seam returns a failing Future',
        () async {
      final service = AnalyticsService.withSeams(
        logEvent: (name, params) async {
          throw StateError('async seam failure');
        },
      );

      expect(() => service.logEvent('run_completed'), returnsNormally);
      await Future<void>.delayed(Duration.zero);
    });

    test('navigatorObserver defaults to a plain NavigatorObserver when none injected',
        () {
      final service = AnalyticsService.withSeams(
        logEvent: (name, params) async {},
      );

      expect(service.navigatorObserver, isA<NavigatorObserver>());
    });

    test('navigatorObserver returns the injected observer when provided',
        () {
      final observer = NavigatorObserver();
      final service = AnalyticsService.withSeams(
        logEvent: (name, params) async {},
        observer: observer,
      );

      expect(service.navigatorObserver, same(observer));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/infrastructure/analytics_service_test.dart`
Expected: FAIL — `AnalyticsService` isn't defined.

- [ ] **Step 3: Implement `AnalyticsService`**

Create `lib/infrastructure/analytics_service.dart`:

```dart
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/widgets.dart';

/// Transport seam (mirrors [CrashReportingService]/[LeaderboardService]).
typedef LogEventFn = Future<void> Function(
    String name, Map<String, Object?>? params);

/// Isolates firebase_analytics so the rest of the app never imports the
/// plugin directly (mirrors [AdService]/[CrashReportingService]). Every call
/// swallows its own failures (sync throw or async `Future` rejection) —
/// observability must never itself become a new failure mode.
class AnalyticsService {
  final LogEventFn _logEvent;
  final NavigatorObserver _observer;

  /// Production constructor: wires the seam to the real Analytics plugin and
  /// builds a [FirebaseAnalyticsObserver] for automatic screen-view tracking.
  AnalyticsService()
      : _logEvent = ((name, params) => FirebaseAnalytics.instance.logEvent(
            name: name,
            parameters: params?.map((k, v) => MapEntry(k, v as Object)),
          )),
        _observer =
            FirebaseAnalyticsObserver(analytics: FirebaseAnalytics.instance);

  /// Test constructor: inject the transport seam (and optionally a fake
  /// [NavigatorObserver]) directly.
  AnalyticsService.withSeams({
    required LogEventFn logEvent,
    NavigatorObserver? observer,
  })  : _logEvent = logEvent,
        _observer = observer ?? NavigatorObserver();

  /// A [NavigatorObserver] that logs `screen_view` automatically. Attach via
  /// `MaterialApp.navigatorObservers`.
  NavigatorObserver get navigatorObserver => _observer;

  /// Log a custom event. [params] values must never be null (Analytics event
  /// params are non-nullable); every v1 event in this app only ever passes
  /// String/int/bool values. Fire-and-forget: never throws.
  void logEvent(String name, [Map<String, Object?>? params]) {
    try {
      _logEvent(name, params).catchError((_) {});
    } catch (_) {
      // Observability must never itself become a failure mode.
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/infrastructure/analytics_service_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/infrastructure/analytics_service.dart test/infrastructure/analytics_service_test.dart
git commit -m "feat(observability): add AnalyticsService"
```

---

### Task 4: `AdService` — `ad_shown`/`ad_load_failed` instrumentation

**Files:**
- Modify: `lib/infrastructure/ad_service.dart:1-91` (whole file — small)
- Modify: `lib/presentation/screens/cosmetics_screen.dart:81-92` (`_unlockViaAd`)
- Modify: `lib/presentation/screens/game_screen.dart:209-226` (`_watchDoubleCoins`), `:325-341` (`_undo`), `:344-358` (`_watchHint`), `:374-385` (`_watchRewarded`)
- Modify: `lib/presentation/screens/loot_chest_screen.dart:22-33` (`_doubleWithAd`)
- Modify: `lib/presentation/screens/tier_select_screen.dart:398-416` (`_watchFreezeAd`)
- Test: `test/infrastructure/ad_service_test.dart` (new)

**Interfaces:**
- Consumes: `AnalyticsService` (Task 3).
- Produces: `AdService({AnalyticsService? analytics})`; `AdService.showRewarded` gains a new required `adType` parameter. No other call sites of `AdService` exist beyond the 7 listed above (confirmed via grep).

- [ ] **Step 1: Write the failing test**

Create `test/infrastructure/ad_service_test.dart`. This covers the two failure/unavailable branches, which fire analytics without ever touching a real `RewardedAd` (the "ad successfully shown" path isn't unit-testable without a much larger refactor to fake the `google_mobile_ads` plugin, and is out of scope here — `AdService` currently has zero test coverage of its ad-showing logic for the same reason):

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/infrastructure/ad_service.dart';
import 'package:connect_merge/infrastructure/analytics_service.dart';

void main() {
  group('AdService analytics instrumentation', () {
    test('showRewarded before init() reports unavailable and logs ad_load_failed',
        () {
      final events = <MapEntry<String, Map<String, Object?>?>>[];
      final analytics = AnalyticsService.withSeams(
        logEvent: (name, params) async {
          events.add(MapEntry(name, params));
        },
      );
      final adService = AdService(analytics: analytics);

      var unavailableCalled = false;
      adService.showRewarded(
        adType: 'hint',
        onReward: () => fail('should not reward'),
        onUnavailable: () => unavailableCalled = true,
      );

      expect(unavailableCalled, isTrue);
      expect(events, [
        const MapEntry('ad_load_failed', {'adType': 'hint'}),
      ]);
    });

    test('works with no AnalyticsService injected (offline / unconfigured)',
        () {
      final adService = AdService();

      var unavailableCalled = false;
      expect(
        () => adService.showRewarded(
          adType: 'undo',
          onReward: () => fail('should not reward'),
          onUnavailable: () => unavailableCalled = true,
        ),
        returnsNormally,
      );
      expect(unavailableCalled, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/infrastructure/ad_service_test.dart`
Expected: FAIL — `AdService` has no `analytics` constructor parameter and `showRewarded` has no `adType` parameter yet.

- [ ] **Step 3: Instrument `AdService`**

Replace the full contents of `lib/infrastructure/ad_service.dart`:

```dart
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ad_config.dart';
import 'analytics_service.dart';
import 'consent_service.dart';

/// Isolates all google_mobile_ads lifecycle so the rest of the app never
/// imports the plugin directly.
class AdService {
  final AnalyticsService? analytics;

  AdService({this.analytics});

  RewardedAd? _rewarded;
  bool _initialized = false;

  /// Checks UMP consent before calling [MobileAds.initialize].
  /// If consent has not been granted yet this is a no-op — ads will be
  /// unavailable for this session and initialised on the next launch once
  /// the user has accepted the consent form shown by the native layer.
  Future<void> init(ConsentService consent) async {
    if (!await consent.canRequestAds()) return;
    await MobileAds.instance.initialize();
    _initialized = true;
    _preloadRewarded();
  }

  /// Builds a fresh banner ad ready to load, or null when ads are not yet
  /// initialised (consent not granted). The caller must dispose the returned
  /// ad when done.
  BannerAd? createBanner() {
    if (!_initialized) return null;
    return BannerAd(
      adUnitId: AdConfig.bannerUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: const BannerAdListener(),
    )..load();
  }

  void _preloadRewarded() {
    if (!_initialized) return;
    RewardedAd.load(
      adUnitId: AdConfig.rewardedUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) => _rewarded = ad,
        onAdFailedToLoad: (_) => _rewarded = null,
      ),
    );
  }

  /// Shows a rewarded ad for feature [adType] (e.g. `'hint'`, `'undo'`,
  /// `'continue'`, `'double_coins'`, `'loot_double'`, `'streak_freeze'`,
  /// `'cosmetic_unlock'`) — used only to tag the `ad_shown`/`ad_load_failed`
  /// analytics events, not for any gameplay logic. Calls [onReward] exactly
  /// once if the user earns the reward, then preloads the next ad.
  /// [onUnavailable] fires if none is ready or if ads have not been
  /// initialised yet.
  void showRewarded({
    required String adType,
    required void Function() onReward,
    required void Function() onUnavailable,
  }) {
    if (!_initialized) {
      analytics?.logEvent('ad_load_failed', {'adType': adType});
      onUnavailable();
      return;
    }
    final ad = _rewarded;
    if (ad == null) {
      analytics?.logEvent('ad_load_failed', {'adType': adType});
      onUnavailable();
      _preloadRewarded();
      return;
    }
    var rewarded = false;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _rewarded = null;
        _preloadRewarded();
      },
      onAdFailedToShowFullScreenContent: (ad, _) {
        ad.dispose();
        _rewarded = null;
        analytics?.logEvent('ad_load_failed', {'adType': adType});
        onUnavailable();
        _preloadRewarded();
      },
    );
    analytics?.logEvent('ad_shown', {'adType': adType});
    ad.show(onUserEarnedReward: (_, __) {
      if (!rewarded) {
        rewarded = true;
        onReward();
      }
    });
  }

  void dispose() {
    _rewarded?.dispose();
    _rewarded = null;
  }
}
```

- [ ] **Step 4: Run the new test to verify it passes**

Run: `flutter test test/infrastructure/ad_service_test.dart`
Expected: PASS

- [ ] **Step 5: Update all 7 call sites to pass `adType`**

In `lib/presentation/screens/cosmetics_screen.dart`, in `_unlockViaAd` (lines 81-92), change:

```dart
    widget.adService.showRewarded(
      onReward: () => widget.engagement.grantAdCosmetic(c),
```

to:

```dart
    widget.adService.showRewarded(
      adType: 'cosmetic_unlock',
      onReward: () => widget.engagement.grantAdCosmetic(c),
```

In `lib/presentation/screens/game_screen.dart`, in `_watchDoubleCoins` (lines 209-226), change:

```dart
    adService.showRewarded(
      onReward: () async {
        final bonus = await cubit.doubleRunCoins();
```

to:

```dart
    adService.showRewarded(
      adType: 'double_coins',
      onReward: () async {
        final bonus = await cubit.doubleRunCoins();
```

Still in `game_screen.dart`, in `_undo` (lines 325-341), change:

```dart
    adService.showRewarded(
      onReward: () => cubit.undoAfterReward(),
```

to:

```dart
    adService.showRewarded(
      adType: 'undo',
      onReward: () => cubit.undoAfterReward(),
```

Still in `game_screen.dart`, in `_watchHint` (lines 344-358), change:

```dart
    adService.showRewarded(
      onReward: () {
        final tier = cubit.revealNextDropAfterReward();
```

to:

```dart
    adService.showRewarded(
      adType: 'hint',
      onReward: () {
        final tier = cubit.revealNextDropAfterReward();
```

Still in `game_screen.dart`, in `_watchRewarded` (lines 374-385), change:

```dart
    adService.showRewarded(
      onReward: () => cubit.grantAdReward(),
```

to:

```dart
    adService.showRewarded(
      adType: 'continue',
      onReward: () => cubit.grantAdReward(),
```

In `lib/presentation/screens/loot_chest_screen.dart`, in `_doubleWithAd` (lines 22-33), change:

```dart
    adService.showRewarded(
      onReward: () => loot.doubleReward(),
```

to:

```dart
    adService.showRewarded(
      adType: 'loot_double',
      onReward: () => loot.doubleReward(),
```

In `lib/presentation/screens/tier_select_screen.dart`, in `_watchFreezeAd` (lines 398-416), change:

```dart
    widget.adService.showRewarded(
      onReward: () async {
        final granted = await _engagement.grantFreezeToken();
```

to:

```dart
    widget.adService.showRewarded(
      adType: 'streak_freeze',
      onReward: () async {
        final granted = await _engagement.grantFreezeToken();
```

- [ ] **Step 6: Run the full test suite to verify nothing broke**

Run: `flutter test`
Expected: PASS (adding a required named parameter with call sites updated at every existing call doesn't change behavior for any existing test — no test constructs `AdService` or calls `showRewarded` today, confirmed via grep).

- [ ] **Step 7: Commit**

```bash
git add lib/infrastructure/ad_service.dart lib/presentation/screens/cosmetics_screen.dart lib/presentation/screens/game_screen.dart lib/presentation/screens/loot_chest_screen.dart lib/presentation/screens/tier_select_screen.dart test/infrastructure/ad_service_test.dart
git commit -m "feat(observability): instrument AdService with ad_shown/ad_load_failed events"
```

---

### Task 5: `GameCubit` — `onError`, `run_completed`, per-tier `streak_broken`

**Files:**
- Modify: `lib/application/game_cubit.dart:161-168` (constructor), `:410-445` (`_finishRun`), `:554-563` (`_fireCompletionHook`), `:565-583` (`_submit`), `:637-654` (`_recordCompletion`)
- Test: `test/application/game_cubit_test.dart`

**Interfaces:**
- Consumes: nothing new from earlier tasks directly (plain callback types matching `CrashReportingService.recordError`/`AnalyticsService.logEvent` signatures, so `main.dart` can tear off the real methods in Task 9 with zero adapter code).
- Produces: `GameCubit` gains two new optional constructor fields: `onError` (`void Function(Object error, StackTrace? stack, {bool fatal})?`) and `onAnalyticsEvent` (`void Function(String name, [Map<String, Object?>? params])?`).

- [ ] **Step 1: Extend the `_completeTier` test helper, then write the failing tests**

`test/application/game_cubit_test.dart` already has a private helper (near the bottom of the file, currently lines 419-438) used by the `'per-tier streaks increment independently'` test:

```dart
Future<void> _completeTier(
    InMemoryStorageService storage, String date, Difficulty tier) async {
  // Seed a fresh board, then play it to completion by forcing out-of-moves
  // through the cubit's merge path is heavy; instead simulate completion the way
  // _recordCompletion does, by running a single merge that ends the day.
  final start = DailySeeder(date, tier).generate().board;
  // Drive to out-of-moves by saving a near-complete snapshot then merging once.
  final nearDone = start.copyWith(movesRemaining: 1);
  await storage.saveSnapshot(GameSnapshot(
      date: date, difficulty: tier, board: nearDone, completed: false));

  final c = GameCubit(storage: storage, todayProvider: () => date);
  await c.init(difficulty: tier);
  final board = (c.state as GamePlaying).board;
  final pair = _findMergePair(board);
  await c.merge(fromIndex: pair.$1, toIndex: pair.$2);
  // After spending the last move, status becomes outOfMoves and completion is
  // recorded.
  expect(c.state, isA<GameOverShowScore>());
}
```

Extend it to accept the three new optional hooks, forwarding them to the `GameCubit` it constructs (every existing call site omits them, so this is backward compatible):

```dart
Future<void> _completeTier(
  InMemoryStorageService storage,
  String date,
  Difficulty tier, {
  void Function(Object error, StackTrace? stack, {bool fatal})? onError,
  void Function(String name, [Map<String, Object?>? params])? onAnalyticsEvent,
  Future<void> Function({int score, int highestTier})? onTierCompleted,
}) async {
  // Seed a fresh board, then play it to completion by forcing out-of-moves
  // through the cubit's merge path is heavy; instead simulate completion the way
  // _recordCompletion does, by running a single merge that ends the day.
  final start = DailySeeder(date, tier).generate().board;
  // Drive to out-of-moves by saving a near-complete snapshot then merging once.
  final nearDone = start.copyWith(movesRemaining: 1);
  await storage.saveSnapshot(GameSnapshot(
      date: date, difficulty: tier, board: nearDone, completed: false));

  final c = GameCubit(
    storage: storage,
    todayProvider: () => date,
    onError: onError,
    onAnalyticsEvent: onAnalyticsEvent,
    onTierCompleted: onTierCompleted,
  );
  await c.init(difficulty: tier);
  final board = (c.state as GamePlaying).board;
  final pair = _findMergePair(board);
  await c.merge(fromIndex: pair.$1, toIndex: pair.$2);
  // After spending the last move, status becomes outOfMoves and completion is
  // recorded.
  expect(c.state, isA<GameOverShowScore>());
}
```

Then add these tests inside `main()`, right after the existing `'per-tier streaks increment independently'` test:

```dart
  test('onAnalyticsEvent fires run_completed exactly once with the terminal board\'s stats',
      () async {
    final events = <MapEntry<String, Map<String, Object?>?>>[];
    await _completeTier(
      storage,
      '2026-06-06',
      Difficulty.easy,
      onAnalyticsEvent: (name, [params]) =>
          events.add(MapEntry(name, params)),
    );

    final runCompleted =
        events.where((e) => e.key == 'run_completed').toList();
    expect(runCompleted, hasLength(1));
    final params = runCompleted.single.value!;
    expect(params['difficulty'], 'easy');
    expect(params.containsKey('score'), isTrue);
    expect(params.containsKey('highestTier'), isTrue);
    expect(params.containsKey('moveCount'), isTrue);
  });

  test('per-tier streak_broken fires on a genuine gap, using the pre-reset length',
      () async {
    await _completeTier(storage, '2026-06-01', Difficulty.easy);
    final events = <MapEntry<String, Map<String, Object?>?>>[];
    await _completeTier(
      storage,
      '2026-06-07', // 6-day gap since 2026-06-01; no freeze support at this layer
      Difficulty.easy,
      onAnalyticsEvent: (name, [params]) =>
          events.add(MapEntry(name, params)),
    );

    final broken = events.where((e) => e.key == 'streak_broken').toList();
    expect(broken, [
      const MapEntry('streak_broken',
          {'streakType': 'perTier', 'difficulty': 'easy', 'length': 1}),
    ]);
  });

  test('per-tier streak_broken does NOT fire on a first-ever completion',
      () async {
    final events = <MapEntry<String, Map<String, Object?>?>>[];
    await _completeTier(
      storage,
      '2026-06-01',
      Difficulty.easy,
      onAnalyticsEvent: (name, [params]) =>
          events.add(MapEntry(name, params)),
    );

    expect(events.where((e) => e.key == 'streak_broken'), isEmpty);
  });

  test('onError fires when onTierCompleted throws', () async {
    Object? capturedError;
    await _completeTier(
      storage,
      '2026-06-06',
      Difficulty.easy,
      onTierCompleted: ({int score = 0, int highestTier = 0}) async =>
          throw StateError('engagement bookkeeping failed'),
      onError: (error, stack, {fatal = false}) => capturedError = error,
    );

    expect(capturedError, isA<StateError>());
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/application/game_cubit_test.dart`
Expected: FAIL — `onAnalyticsEvent`/`onError` aren't constructor parameters yet.

- [ ] **Step 3: Add the constructor fields**

In `lib/application/game_cubit.dart`, the `GameCubit` constructor (lines 161-168) currently reads:

```dart
  GameCubit({
    required this.storage,
    String Function()? todayProvider,
    this.onSubmitRun,
    this.onTierCompleted,
    this.onCoinsEarned,
  })  : todayProvider = todayProvider ?? utcToday,
        super(const GameInitial());
```

Replace it with:

```dart
  /// Optional error-reporting hook (observability). Fired for exceptions that
  /// are currently swallowed silently (best-effort background work — a
  /// failing hook never blocks gameplay). Signature matches
  /// `CrashReportingService.recordError` exactly, so callers can pass the
  /// method directly (e.g. `onError: crashReporting.recordError`).
  final void Function(Object error, StackTrace? stack, {bool fatal})? onError;

  /// Optional analytics hook (observability). Signature matches
  /// `AnalyticsService.logEvent` exactly, so callers can pass the method
  /// directly (e.g. `onAnalyticsEvent: analytics.logEvent`).
  final void Function(String name, [Map<String, Object?>? params])?
      onAnalyticsEvent;

  GameCubit({
    required this.storage,
    String Function()? todayProvider,
    this.onSubmitRun,
    this.onTierCompleted,
    this.onCoinsEarned,
    this.onError,
    this.onAnalyticsEvent,
  })  : todayProvider = todayProvider ?? utcToday,
        super(const GameInitial());
```

(The two new `final` field declarations go alongside the existing `onSubmitRun`/`onTierCompleted`/`onCoinsEarned` field declarations above the constructor, not inside it — match the existing style in this file.)

- [ ] **Step 4: Fire `run_completed` in `_finishRun`**

In `lib/application/game_cubit.dart`, `_finishRun` (lines 410-445) currently ends with:

```dart
    _undoStack.clear();
    await _fireCompletionHook(board);
    emit(GameOverShowScore(
        board: board, date: _date, difficulty: _difficulty, stats: stats));
```

Change to:

```dart
    _undoStack.clear();
    await _fireCompletionHook(board);
    onAnalyticsEvent?.call('run_completed', {
      'difficulty': _difficulty.name,
      'score': board.score,
      'highestTier': board.highestTier,
      'moveCount': board.movesMade,
    });
    emit(GameOverShowScore(
        board: board, date: _date, difficulty: _difficulty, stats: stats));
```

- [ ] **Step 5: Fire `onError` in the two existing silent catches**

In `lib/application/game_cubit.dart`, `_fireCompletionHook` (lines 554-563) currently reads:

```dart
  Future<void> _fireCompletionHook(BoardState board) async {
    final hook = onTierCompleted;
    if (hook == null || _completionFired) return;
    _completionFired = true;
    try {
      await hook(score: board.score, highestTier: board.highestTier);
    } catch (_) {
      // Engagement bookkeeping is best-effort; play is never blocked by it.
    }
  }
```

Change the `catch` clause to:

```dart
    } catch (e, st) {
      // Engagement bookkeeping is best-effort; play is never blocked by it.
      onError?.call(e, st);
    }
```

`_submit` (lines 565-583) currently reads:

```dart
  Future<void> _submit(BoardState board) async {
    final hook = onSubmitRun;
    if (hook == null || _submitted) return;
    _submitted = true;
    try {
      await hook(
        date: _date,
        difficulty: _difficulty,
        moveLog: board.moveLog,
        adContinues: board.adContinuesUsed,
      );
    } catch (_) {
      // Submission is off the critical path; the result screen never blocks.
      // Offline queue/retry is handled by the caller's service (future work).
    }
  }
```

Change the `catch` clause to:

```dart
    } catch (e, st) {
      // Submission is off the critical path; the result screen never blocks.
      // Offline queue/retry is handled by the caller's service (future work).
      onError?.call(e, st);
    }
```

- [ ] **Step 6: Fire per-tier `streak_broken` in `_recordCompletion`**

In `lib/application/game_cubit.dart`, `_recordCompletion` (lines 637-654) currently reads:

```dart
  Future<LifetimeStats> _recordCompletion(BoardState board) async {
    final prev = storage.loadStats(_difficulty);
    if (prev.lastCompletedDate == _date) return prev;

    final yesterday = formatDate(
        DateTime.parse(_date).subtract(const Duration(days: 1)));
    final streak = prev.lastCompletedDate == yesterday ? prev.streak + 1 : 1;

    final updated = prev.copyWith(
      streak: streak,
      lastCompletedDate: _date,
      bestScore: board.score > prev.bestScore ? board.score : prev.bestScore,
      bestTier:
          board.highestTier > prev.bestTier ? board.highestTier : prev.bestTier,
    );
    await storage.saveStats(_difficulty, updated);
    return updated;
  }
```

Replace with:

```dart
  Future<LifetimeStats> _recordCompletion(BoardState board) async {
    final prev = storage.loadStats(_difficulty);
    if (prev.lastCompletedDate == _date) return prev;

    final yesterday = formatDate(
        DateTime.parse(_date).subtract(const Duration(days: 1)));
    final streak = prev.lastCompletedDate == yesterday ? prev.streak + 1 : 1;

    // A genuine gap (a prior completion date exists, isn't today, isn't
    // yesterday) resets this per-tier streak with no freeze support (unlike
    // the headline streak in EngagementCubit) — that reset is a churn signal
    // worth surfacing once, using the streak value BEFORE the reset.
    if (prev.lastCompletedDate != null &&
        prev.lastCompletedDate != yesterday &&
        prev.streak > 0) {
      onAnalyticsEvent?.call('streak_broken', {
        'streakType': 'perTier',
        'difficulty': _difficulty.name,
        'length': prev.streak,
      });
    }

    final updated = prev.copyWith(
      streak: streak,
      lastCompletedDate: _date,
      bestScore: board.score > prev.bestScore ? board.score : prev.bestScore,
      bestTier:
          board.highestTier > prev.bestTier ? board.highestTier : prev.bestTier,
    );
    await storage.saveStats(_difficulty, updated);
    return updated;
  }
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `flutter test test/application/game_cubit_test.dart`
Expected: PASS

Run: `flutter test`
Expected: PASS (full suite — the two new optional params default to `null`, so every existing `GameCubit(...)` call site keeps compiling and behaving identically).

- [ ] **Step 8: Commit**

```bash
git add lib/application/game_cubit.dart test/application/game_cubit_test.dart
git commit -m "feat(observability): wire run_completed analytics + onError into GameCubit"
```

---

### Task 6: `EngagementCubit` — `onError`, headline `streak_broken`

**Files:**
- Modify: `lib/application/engagement_cubit.dart:110-118` (constructor), `:170-181` (streak transition in `onTierCompleted`), `:325-337` (`checkDailyPrizes` catch), `:419-423` (`checkWeeklyPrizes` catch), `:493-497` (`checkMonthlyPrizes` catch), `:543-546` (`checkChallengePayouts` catch)
- Test: `test/application/engagement_test.dart`

**Interfaces:**
- Consumes: nothing new (same callback-signature convention as Task 5).
- Produces: `EngagementCubit` gains `onError` and `onAnalyticsEvent`, identical shape to `GameCubit`'s (Task 5).

- [ ] **Step 1: Write the failing tests**

In `test/application/engagement_test.dart`, inside the `group('EngagementCubit completion hook', ...)` block, add (after the existing `'gap with a banked freeze token...'` test):

```dart
    test('a genuine gap with NO freeze token fires streak_broken with the pre-reset length',
        () async {
      await storage.saveProfile(const PlayerProfile(
          dailyActiveStreak: 8, lastActiveDate: '2026-06-01'));
      final events = <MapEntry<String, Map<String, Object?>?>>[];
      final c = EngagementCubit(
        storage: storage,
        todayProvider: () => '2026-06-07',
        onAnalyticsEvent: (name, [params]) =>
            events.add(MapEntry(name, params)),
      )..load();
      await c.onTierCompleted();

      expect(c.state.dailyActiveStreak, 1); // reset, no freeze available
      final broken = events.where((e) => e.key == 'streak_broken').toList();
      expect(broken, hasLength(1));
      expect(broken.single.value, {'streakType': 'daily', 'length': 8});
    });

    test('a gap bridged by a freeze token does NOT fire streak_broken',
        () async {
      await storage.saveProfile(const PlayerProfile(
          dailyActiveStreak: 8, lastActiveDate: '2026-06-01'));
      await storage.saveStats(
          Difficulty.easy,
          const LifetimeStats(
              streak: 0,
              lastCompletedDate: null,
              bestScore: 0,
              bestTier: 0,
              streakFreezeTokens: 1));
      final events = <MapEntry<String, Map<String, Object?>?>>[];
      final c = EngagementCubit(
        storage: storage,
        todayProvider: () => '2026-06-07',
        onAnalyticsEvent: (name, [params]) =>
            events.add(MapEntry(name, params)),
      )..load();
      await c.onTierCompleted();

      expect(events.where((e) => e.key == 'streak_broken'), isEmpty);
    });

    test('consecutive-day completion does NOT fire streak_broken', () async {
      await storage.saveProfile(const PlayerProfile(
          dailyActiveStreak: 4, lastActiveDate: '2026-06-06'));
      final events = <MapEntry<String, Map<String, Object?>?>>[];
      final c = EngagementCubit(
        storage: storage,
        todayProvider: () => '2026-06-07',
        onAnalyticsEvent: (name, [params]) =>
            events.add(MapEntry(name, params)),
      )..load();
      await c.onTierCompleted();

      expect(events.where((e) => e.key == 'streak_broken'), isEmpty);
    });

    test('first-ever completion does NOT fire streak_broken', () async {
      final events = <MapEntry<String, Map<String, Object?>?>>[];
      final c = EngagementCubit(
        storage: storage,
        todayProvider: () => '2026-06-07',
        onAnalyticsEvent: (name, [params]) =>
            events.add(MapEntry(name, params)),
      )..load();
      await c.onTierCompleted();

      expect(events.where((e) => e.key == 'streak_broken'), isEmpty);
    });

    test('onError fires when checkDailyPrizes\' fetch throws', () async {
      Object? capturedError;
      final c = EngagementCubit(
        storage: storage,
        todayProvider: () => '2026-06-07',
        onError: (error, stack, {fatal = false}) => capturedError = error,
      )..load();

      await c.checkDailyPrizes(
        ({required difficulty, required date}) async =>
            throw StateError('network down'),
      );

      expect(capturedError, isA<StateError>());
    });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/application/engagement_test.dart`
Expected: FAIL — `onError`/`onAnalyticsEvent` aren't constructor parameters yet; `streak_broken` is never fired.

- [ ] **Step 3: Add the constructor fields**

In `lib/application/engagement_cubit.dart`, the `EngagementCubit` constructor (lines 110-118, inside the `class EngagementCubit` body) currently reads:

```dart
class EngagementCubit extends Cubit<EngagementState> {
  final StorageService storage;
  final String Function() todayProvider;

  EngagementCubit({
    required this.storage,
    String Function()? todayProvider,
  })  : todayProvider = todayProvider ?? utcToday,
        super(const EngagementState());
```

Replace with:

```dart
class EngagementCubit extends Cubit<EngagementState> {
  final StorageService storage;
  final String Function() todayProvider;

  /// Optional error-reporting hook (observability). Signature matches
  /// `CrashReportingService.recordError` exactly.
  final void Function(Object error, StackTrace? stack, {bool fatal})? onError;

  /// Optional analytics hook (observability). Signature matches
  /// `AnalyticsService.logEvent` exactly.
  final void Function(String name, [Map<String, Object?>? params])?
      onAnalyticsEvent;

  EngagementCubit({
    required this.storage,
    String Function()? todayProvider,
    this.onError,
    this.onAnalyticsEvent,
  })  : todayProvider = todayProvider ?? utcToday,
        super(const EngagementState());
```

- [ ] **Step 4: Fire headline `streak_broken` in `onTierCompleted`**

In `lib/application/engagement_cubit.dart`, `onTierCompleted` (starting at line ~162), the streak-transition section (lines ~170-181) currently reads:

```dart
    // --- Streak transition (headline, "any tier today"). ---
    final hasFreeze = _maxTierFreezeTokens() > 0;
    final result = nextStreak(
      prev: profile.dailyActiveStreak,
      last: profile.lastActiveDate,
      today: today,
      hasFreeze: hasFreeze,
    );
    if (result.freezeConsumed) {
      await _consumeOneFreezeToken();
    }
```

Replace with:

```dart
    // --- Streak transition (headline, "any tier today"). ---
    final hasFreeze = _maxTierFreezeTokens() > 0;
    final result = nextStreak(
      prev: profile.dailyActiveStreak,
      last: profile.lastActiveDate,
      today: today,
      hasFreeze: hasFreeze,
    );
    if (result.freezeConsumed) {
      await _consumeOneFreezeToken();
    }
    // A genuine gap (a prior date exists, isn't today, isn't yesterday) that
    // no freeze token bridged is a direct churn-risk signal — surface it once,
    // using the streak length BEFORE the reset.
    final yesterday = previousUtcDay(today);
    final hadGap = profile.lastActiveDate != null &&
        profile.lastActiveDate != today &&
        profile.lastActiveDate != yesterday;
    if (hadGap && !result.freezeConsumed) {
      onAnalyticsEvent?.call('streak_broken', {
        'streakType': 'daily',
        'length': profile.dailyActiveStreak,
      });
    }
```

- [ ] **Step 5: Fire `onError` in the four existing silent catches**

In `lib/application/engagement_cubit.dart`, `checkDailyPrizes` (around lines 325-337) has:

```dart
      } catch (_) {
        return; // network failure: skip; retry on next app open
      }
```

Change to:

```dart
      } catch (e, st) {
        onError?.call(e, st);
        return; // network failure: skip; retry on next app open
      }
```

`checkWeeklyPrizes` (around lines 419-423) has:

```dart
      } catch (_) {
        // Network failure: skip this tier, try on next launch.
      }
```

Change to:

```dart
      } catch (e, st) {
        onError?.call(e, st);
        // Network failure: skip this tier, try on next launch.
      }
```

`checkMonthlyPrizes` (around lines 493-497) has:

```dart
      } catch (_) {
        return;
      }
```

Change to:

```dart
      } catch (e, st) {
        onError?.call(e, st);
        return;
      }
```

`checkChallengePayouts` (around lines 543-546) has:

```dart
    } catch (_) {
      return; // network failure: skip; retry on next app open
    }
```

Change to:

```dart
    } catch (e, st) {
      onError?.call(e, st);
      return; // network failure: skip; retry on next app open
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `flutter test test/application/engagement_test.dart`
Expected: PASS

Run: `flutter test`
Expected: PASS (full suite).

- [ ] **Step 7: Commit**

```bash
git add lib/application/engagement_cubit.dart test/application/engagement_test.dart
git commit -m "feat(observability): wire streak_broken analytics + onError into EngagementCubit"
```

---

### Task 7: `DuelCubit` — `duel_started`, `duel_completed`

**Files:**
- Modify: `lib/application/duel_cubit.dart:58-69` (constructor + `receiveChallenge`), `:78-93` (`recordMyResult`)
- Test: `test/application/duel_cubit_test.dart`

**Interfaces:**
- Consumes: nothing new (same callback-signature convention as Tasks 5-6, analytics only — `DuelCubit` has no existing silent catches, so no `onError` needed here).
- Produces: `DuelCubit` gains `onAnalyticsEvent`.

- [ ] **Step 1: Write the failing tests**

In `test/application/duel_cubit_test.dart`, inside `group('DuelCubit receive + settle', ...)`, add:

```dart
    test('receiveChallenge fires duel_started with difficulty', () {
      final events = <MapEntry<String, Map<String, Object?>?>>[];
      final c = DuelCubit(
        todayProvider: () => '2026-06-11',
        onAnalyticsEvent: (name, [params]) =>
            events.add(MapEntry(name, params)),
      )..receiveChallenge(challenge);

      expect(events, [
        const MapEntry('duel_started', {'difficulty': 'hard'}),
      ]);
    });

    test('recordMyResult fires duel_completed with difficulty + won', () {
      final events = <MapEntry<String, Map<String, Object?>?>>[];
      final c = DuelCubit(
        todayProvider: () => '2026-06-11',
        onAnalyticsEvent: (name, [params]) =>
            events.add(MapEntry(name, params)),
      )..receiveChallenge(challenge);
      c.recordMyResult(
          date: '2026-06-11', difficulty: Difficulty.hard, myScore: 1500);

      final completed =
          events.where((e) => e.key == 'duel_completed').toList();
      expect(completed, [
        const MapEntry('duel_completed', {'difficulty': 'hard', 'won': true}),
      ]);
    });

    test('recordMyResult on an expired challenge does NOT fire duel_completed',
        () {
      final events = <MapEntry<String, Map<String, Object?>?>>[];
      final c = DuelCubit(
        todayProvider: () => '2026-06-12', // day after the challenge's date
        onAnalyticsEvent: (name, [params]) =>
            events.add(MapEntry(name, params)),
      )..receiveChallenge(challenge);
      c.recordMyResult(
          date: '2026-06-11', difficulty: Difficulty.hard, myScore: 1500);

      expect(events.where((e) => e.key == 'duel_completed'), isEmpty);
    });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/application/duel_cubit_test.dart`
Expected: FAIL — `onAnalyticsEvent` isn't a constructor parameter yet.

- [ ] **Step 3: Add the constructor field and fire the two events**

In `lib/application/duel_cubit.dart`, the class currently reads (lines 58-72):

```dart
class DuelCubit extends Cubit<DuelState> {
  final String Function() todayProvider;

  DuelCubit({required this.todayProvider}) : super(const DuelState());

  /// Accept an incoming [challenge] (from a duel deep link). Marks it expired
  /// when its date is no longer today (the seeded board is gone), so the UI can
  /// offer today's tier instead. Resets any prior comparison.
  void receiveChallenge(DuelChallenge challenge) {
    final expired = challenge.date != todayProvider();
    emit(DuelState(challenge: challenge, expired: expired));
  }
```

Replace with:

```dart
class DuelCubit extends Cubit<DuelState> {
  final String Function() todayProvider;

  /// Optional analytics hook (observability). Signature matches
  /// `AnalyticsService.logEvent` exactly.
  final void Function(String name, [Map<String, Object?>? params])?
      onAnalyticsEvent;

  DuelCubit({required this.todayProvider, this.onAnalyticsEvent})
      : super(const DuelState());

  /// Accept an incoming [challenge] (from a duel deep link). Marks it expired
  /// when its date is no longer today (the seeded board is gone), so the UI can
  /// offer today's tier instead. Resets any prior comparison.
  void receiveChallenge(DuelChallenge challenge) {
    final expired = challenge.date != todayProvider();
    emit(DuelState(challenge: challenge, expired: expired));
    if (!expired) {
      onAnalyticsEvent
          ?.call('duel_started', {'difficulty': challenge.difficulty.name});
    }
  }
```

Then, `recordMyResult` (lines 78-93) currently reads:

```dart
  void recordMyResult({
    required String date,
    required Difficulty difficulty,
    required int myScore,
  }) {
    final c = state.challenge;
    if (c == null) return;
    // An expired challenge's board is no longer playable, so it can never be
    // honestly settled — guard before any comparison.
    if (state.expired) return;
    if (c.date != date || c.difficulty != difficulty) return;
    emit(state.copyWith(
      myScore: myScore,
      outcome: compare(myScore: myScore, challengerScore: c.challengerScore),
    ));
  }
```

Replace with:

```dart
  void recordMyResult({
    required String date,
    required Difficulty difficulty,
    required int myScore,
  }) {
    final c = state.challenge;
    if (c == null) return;
    // An expired challenge's board is no longer playable, so it can never be
    // honestly settled — guard before any comparison.
    if (state.expired) return;
    if (c.date != date || c.difficulty != difficulty) return;
    final outcome = compare(myScore: myScore, challengerScore: c.challengerScore);
    emit(state.copyWith(myScore: myScore, outcome: outcome));
    onAnalyticsEvent?.call('duel_completed', {
      'difficulty': difficulty.name,
      'won': outcome == DuelOutcome.win,
    });
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/application/duel_cubit_test.dart`
Expected: PASS

Run: `flutter test`
Expected: PASS (full suite).

- [ ] **Step 5: Commit**

```bash
git add lib/application/duel_cubit.dart test/application/duel_cubit_test.dart
git commit -m "feat(observability): wire duel_started/duel_completed analytics into DuelCubit"
```

---

### Task 8: `DisplayNameScreen` — `onboarding_completed`

**Files:**
- Modify: `lib/presentation/screens/display_name_screen.dart:9-19` (widget fields/constructor), `:34-59` (`_save`)
- Test: `test/presentation/display_name_screen_test.dart` (new)

**Interfaces:**
- Consumes: `AnalyticsService` (Task 3), passed directly as a screen field (matching how `AdService`/`LeaderboardService` are passed directly to other screens, not via a decoupled callback — screens already import services directly).
- Produces: `DisplayNameScreen` gains an optional `analytics` field.

- [ ] **Step 1: Write the failing test**

Create `test/presentation/display_name_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/infrastructure/analytics_service.dart';
import 'package:connect_merge/infrastructure/auth_service.dart';
import 'package:connect_merge/presentation/screens/display_name_screen.dart';

void main() {
  testWidgets('a successful save logs onboarding_completed', (tester) async {
    final events = <MapEntry<String, Map<String, Object?>?>>[];
    final analytics = AnalyticsService.withSeams(
      logEvent: (name, params) async {
        events.add(MapEntry(name, params));
      },
    );
    var saved = false;

    await tester.pumpWidget(MaterialApp(
      home: DisplayNameScreen(
        auth: _FakeAuthService(),
        analytics: analytics,
        onSaved: () => saved = true,
      ),
    ));

    await tester.enterText(
        find.byKey(const Key('display-name-field')), 'Ann');
    await tester.tap(find.byKey(const Key('display-name-save')));
    await tester.pumpAndSettle();

    expect(saved, isTrue);
    expect(events, [
      const MapEntry('onboarding_completed', null),
    ]);
  });
}

/// Minimal fake: real [AuthService] requires a live [SupabaseClient], which
/// isn't available in a widget test. Implements exactly [AuthService]'s six
/// public members (it has a private `_client` field, nothing else public).
class _FakeAuthService implements AuthService {
  @override
  Future<void> setDisplayName(String name, {String? avatar}) async {}

  @override
  Future<void> ensureSignedIn() async {}

  @override
  Future<String?> displayName() async => null;

  @override
  Future<bool> hasDisplayName() async => false;

  @override
  String? get currentUserId => 'fake-id';

  @override
  bool get isSignedIn => true;
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/presentation/display_name_screen_test.dart`
Expected: FAIL — `DisplayNameScreen` has no `analytics` parameter yet.

- [ ] **Step 3: Add the field and fire the event**

In `lib/presentation/screens/display_name_screen.dart`, the widget declaration (lines 9-19) currently reads:

```dart
class DisplayNameScreen extends StatefulWidget {
  final AuthService auth;

  /// Called after a successful save (e.g. to pop back / continue onboarding).
  final VoidCallback? onSaved;

  const DisplayNameScreen({super.key, required this.auth, this.onSaved});
```

Replace with:

```dart
class DisplayNameScreen extends StatefulWidget {
  final AuthService auth;

  /// Optional analytics service (observability). Null when Firebase isn't
  /// configured — the onboarding_completed event simply isn't logged.
  final AnalyticsService? analytics;

  /// Called after a successful save (e.g. to pop back / continue onboarding).
  final VoidCallback? onSaved;

  const DisplayNameScreen(
      {super.key, required this.auth, this.analytics, this.onSaved});
```

Add the import at the top of the file (alongside the existing `auth_service.dart` import):

```dart
import '../../infrastructure/analytics_service.dart';
```

Then `_save` (lines 34-59) currently reads:

```dart
    try {
      await widget.auth.setDisplayName(name, avatar: _avatar);
      if (!mounted) return;
      widget.onSaved?.call();
    } catch (_) {
```

Change to:

```dart
    try {
      await widget.auth.setDisplayName(name, avatar: _avatar);
      if (!mounted) return;
      widget.analytics?.logEvent('onboarding_completed');
      widget.onSaved?.call();
    } catch (_) {
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/presentation/display_name_screen_test.dart`
Expected: PASS

Run: `flutter test`
Expected: PASS (full suite).

- [ ] **Step 5: Commit**

```bash
git add lib/presentation/screens/display_name_screen.dart test/presentation/display_name_screen_test.dart
git commit -m "feat(observability): log onboarding_completed from DisplayNameScreen"
```

---

### Task 9: Wire it all together in `main.dart`

**Files:**
- Modify: `lib/main.dart:1-117` (`main()`), `:119-149` (`ConnectMergeApp` fields/constructor), `:254-283` (`build`)
- Modify: `lib/presentation/screens/tier_select_screen.dart:41-99` (widget fields — add `analytics`/`crashReporting`), `:125-139` (`initState` fallback `EngagementCubit`), `:278-289` (`GameCubit` construction in `_startTier`)

**Interfaces:**
- Consumes: `CrashReportingService` (Task 2), `AnalyticsService` (Task 3), and every optional field added in Tasks 4-8.
- Produces: fully wired observability — this is the last task; nothing depends on it.

- [ ] **Step 1: Wire `main.dart`**

Replace the full contents of `lib/main.dart`'s `main()` function (lines 1-117) — the imports gain three new lines and the function body gains the Firebase/zone wiring around the existing logic, which is otherwise UNCHANGED (only the two lines constructing `adService`, `duels`, `engagement`, and the final `runApp(...)` call gain new arguments — every other line stays exactly as it is today):

At the top of `lib/main.dart`, add three imports alongside the existing ones:

```dart
import 'package:firebase_core/firebase_core.dart';
```

and (grouped with the other `infrastructure/` imports, alphabetically):

```dart
import 'infrastructure/analytics_service.dart';
import 'infrastructure/crash_reporting_service.dart';
```

Change the function signature and opening lines from:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();
```

to:

```dart
Future<void> main() async {
  CrashReportingService? crashReporting;
  AnalyticsService? analytics;

  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    try {
      await Firebase.initializeApp();
      crashReporting = CrashReportingService();
      analytics = AnalyticsService();
      FlutterError.onError = (details) {
        crashReporting?.recordError(details.exception, details.stack,
            fatal: true);
      };
      WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
        crashReporting?.recordError(error, stack, fatal: true);
        return true;
      };
    } catch (_) {
      // No Firebase config (missing google-services.json/GoogleService-
      // Info.plist, or a test/CI environment with no platform channels):
      // observability stays fully no-op, exactly like initSupabase() below
      // degrades to offline play when Supabase isn't configured.
    }

    await Hive.initFlutter();
```

Then, further down, change:

```dart
  final adService = AdService();
  await adService.init(ConsentService());
```

to:

```dart
  final adService = AdService(analytics: analytics);
  await adService.init(ConsentService());
```

Change:

```dart
  final engagement = EngagementCubit(storage: storage)..load();
```

to:

```dart
  final engagement = EngagementCubit(
    storage: storage,
    onError: crashReporting?.recordError,
    onAnalyticsEvent: analytics?.logEvent,
  )..load();
```

Change:

```dart
  final duels = DuelCubit(todayProvider: utcToday);
```

to:

```dart
  final duels = DuelCubit(
    todayProvider: utcToday,
    onAnalyticsEvent: analytics?.logEvent,
  );
```

Change the final `runApp(...)` call from:

```dart
  runApp(ConnectMergeApp(
    storage: storage,
    adService: adService,
    auth: auth,
    leaderboard: leaderboard,
    friends: friends,
    deepLinks: deepLinks,
    engagement: engagement,
    rivalry: rivalry,
    duels: duels,
    notifications: notifications,
    needsDisplayName: needsDisplayName,
  ));
}
```

to:

```dart
    runApp(ConnectMergeApp(
      storage: storage,
      adService: adService,
      auth: auth,
      leaderboard: leaderboard,
      friends: friends,
      deepLinks: deepLinks,
      engagement: engagement,
      rivalry: rivalry,
      duels: duels,
      notifications: notifications,
      needsDisplayName: needsDisplayName,
      crashReporting: crashReporting,
      analytics: analytics,
    ));
  }, (error, stack) {
    crashReporting?.recordError(error, stack, fatal: true);
  });
}
```

(Every line between `await Hive.initFlutter();` and the `runApp(...)` call — the Hive/ad/notification/Supabase/deep-link/engagement setup — is now one indent level deeper, inside the `runZonedGuarded` closure, but otherwise textually unchanged from what's in the file today. When applying this edit, re-indent that whole middle section by one level rather than retyping it.)

- [ ] **Step 2: Add the two new fields to `ConnectMergeApp`**

In `lib/main.dart`, the `ConnectMergeApp` widget (lines 119-149) currently reads:

```dart
class ConnectMergeApp extends StatefulWidget {
  final HiveStorageService storage;
  final AdService adService;
  final AuthService? auth;
  final LeaderboardService? leaderboard;
  final FriendsService? friends;
  final DeepLinkService? deepLinks;
  final EngagementCubit engagement;
  final RivalryCubit? rivalry;
  final DuelCubit? duels;
  final NotificationService notifications;
  final bool needsDisplayName;

  const ConnectMergeApp({
    super.key,
    required this.storage,
    required this.adService,
    required this.engagement,
    required this.notifications,
    this.auth,
    this.leaderboard,
    this.friends,
    this.deepLinks,
    this.rivalry,
    this.duels,
    this.needsDisplayName = false,
  });
```

Replace with:

```dart
class ConnectMergeApp extends StatefulWidget {
  final HiveStorageService storage;
  final AdService adService;
  final AuthService? auth;
  final LeaderboardService? leaderboard;
  final FriendsService? friends;
  final DeepLinkService? deepLinks;
  final EngagementCubit engagement;
  final RivalryCubit? rivalry;
  final DuelCubit? duels;
  final NotificationService notifications;
  final bool needsDisplayName;
  final CrashReportingService? crashReporting;
  final AnalyticsService? analytics;

  const ConnectMergeApp({
    super.key,
    required this.storage,
    required this.adService,
    required this.engagement,
    required this.notifications,
    this.auth,
    this.leaderboard,
    this.friends,
    this.deepLinks,
    this.rivalry,
    this.duels,
    this.needsDisplayName = false,
    this.crashReporting,
    this.analytics,
  });
```

- [ ] **Step 3: Thread `analytics` into `MaterialApp` and `DisplayNameScreen`, and both services into `TierSelectScreen`**

In `lib/main.dart`, `build` (lines 254-283) currently reads:

```dart
  @override
  Widget build(BuildContext context) {
    final Widget home;
    if (_needsDisplayName && widget.auth != null) {
      home = DisplayNameScreen(
        auth: widget.auth!,
        onSaved: _onOnboarded,
      );
    } else {
      home = TierSelectScreen(
        storage: widget.storage,
        adService: widget.adService,
        leaderboard: widget.leaderboard,
        friends: widget.friends,
        engagement: widget.engagement,
        rivalry: widget.rivalry,
        duels: widget.duels,
        notifications: widget.notifications,
      );
    }
    return MaterialApp(
      title: 'Connect Merge',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navKey,
      scaffoldMessengerKey: _messengerKey,
      theme: ThemeData.dark(useMaterial3: true),
      home: home,
    );
  }
```

Replace with:

```dart
  @override
  Widget build(BuildContext context) {
    final Widget home;
    if (_needsDisplayName && widget.auth != null) {
      home = DisplayNameScreen(
        auth: widget.auth!,
        analytics: widget.analytics,
        onSaved: _onOnboarded,
      );
    } else {
      home = TierSelectScreen(
        storage: widget.storage,
        adService: widget.adService,
        leaderboard: widget.leaderboard,
        friends: widget.friends,
        engagement: widget.engagement,
        rivalry: widget.rivalry,
        duels: widget.duels,
        notifications: widget.notifications,
        crashReporting: widget.crashReporting,
        analytics: widget.analytics,
      );
    }
    return MaterialApp(
      title: 'Connect Merge',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navKey,
      scaffoldMessengerKey: _messengerKey,
      theme: ThemeData.dark(useMaterial3: true),
      navigatorObservers: [
        if (widget.analytics != null) widget.analytics!.navigatorObserver,
      ],
      home: home,
    );
  }
```

- [ ] **Step 4: Add `analytics`/`crashReporting` fields to `TierSelectScreen` and use them at both `EngagementCubit`/`GameCubit` construction sites**

In `lib/presentation/screens/tier_select_screen.dart`, add two imports alongside the existing `infrastructure/` imports:

```dart
import '../../infrastructure/analytics_service.dart';
import '../../infrastructure/crash_reporting_service.dart';
```

In the `TierSelectScreen` widget's field list (the class starts at line 41), add two new fields. Find the existing `final EngagementCubit? engagement;` field declaration (around line 55) and add directly after its doc comment block:

```dart
  /// Observability services (both optional — null when Firebase isn't
  /// configured, or in tests). Threaded down to the locally-created
  /// `EngagementCubit` fallback and to the `GameCubit` this screen creates
  /// per tier.
  final CrashReportingService? crashReporting;
  final AnalyticsService? analytics;
```

`TierSelectScreen`'s constructor currently reads:

```dart
  const TierSelectScreen({
    super.key,
    required this.storage,
    required this.adService,
    this.leaderboard,
    this.friends,
    this.engagement,
    this.loot,
    this.rivalry,
    this.duels,
    this.notifications,
    this.todayProvider,
    this.onTierSelected,
  });
```

Add the two new parameters:

```dart
  const TierSelectScreen({
    super.key,
    required this.storage,
    required this.adService,
    this.leaderboard,
    this.friends,
    this.engagement,
    this.loot,
    this.rivalry,
    this.duels,
    this.notifications,
    this.todayProvider,
    this.onTierSelected,
    this.crashReporting,
    this.analytics,
  });
```

In `initState` (lines 125-139), the fallback `EngagementCubit` construction currently reads:

```dart
    _engagement = widget.engagement ??
        (EngagementCubit(
            storage: widget.storage, todayProvider: widget.todayProvider)
          ..load());
```

Change to:

```dart
    _engagement = widget.engagement ??
        (EngagementCubit(
            storage: widget.storage,
            todayProvider: widget.todayProvider,
            onError: widget.crashReporting?.recordError,
            onAnalyticsEvent: widget.analytics?.logEvent)
          ..load());
```

In `_startTier` (around lines 278-289), the `GameCubit` construction currently reads:

```dart
              create: (_) => GameCubit(
                storage: widget.storage,
                todayProvider: widget.todayProvider,
                onTierCompleted: _onTierCompleted,
                onCoinsEarned: _creditCoins,
                // Wired only when a leaderboard service is present; null offline
                // so the cubit's submit no-ops.
                onSubmitRun: widget.leaderboard == null ? null : _submitRun,
              )..init(difficulty: difficulty),
```

Change to:

```dart
              create: (_) => GameCubit(
                storage: widget.storage,
                todayProvider: widget.todayProvider,
                onTierCompleted: _onTierCompleted,
                onCoinsEarned: _creditCoins,
                // Wired only when a leaderboard service is present; null offline
                // so the cubit's submit no-ops.
                onSubmitRun: widget.leaderboard == null ? null : _submitRun,
                onError: widget.crashReporting?.recordError,
                onAnalyticsEvent: widget.analytics?.logEvent,
              )..init(difficulty: difficulty),
```

- [ ] **Step 5: Verify**

Run: `flutter analyze`
Expected: no errors.

Run: `flutter test`
Expected: PASS — the full suite, including every test constructed in Tasks 2-8, plus every pre-existing test (no existing `TierSelectScreen`/`ConnectMergeApp` test passes `crashReporting`/`analytics`, and both default to `null`, so behavior is unchanged).

- [ ] **Step 6: Commit**

```bash
git add lib/main.dart lib/presentation/screens/tier_select_screen.dart
git commit -m "feat(observability): wire Firebase Crashlytics/Analytics through main.dart"
```

---

## Manual follow-up (outside this plan's automated tasks)

Once every task above is merged, a human with access to the Google account that should own this project completes the Firebase Console setup — this cannot be scripted or delegated to an agent, since it requires interactive OAuth:

1. `dart pub global activate flutterfire_cli`
2. `firebase login`
3. `flutterfire configure` — select/create the Firebase project, select the Android + iOS platforms. This downloads `android/app/google-services.json` and `ios/Runner/GoogleService-Info.plist` into place (it also generates `lib/firebase_options.dart`, which this plan's `main.dart` code deliberately does NOT reference — safe to ignore or delete).
4. `flutter run` on a real device/emulator; trigger a deliberate test crash (e.g. temporarily throw in a button handler) and confirm it appears in the Firebase Console under Crashlytics within a few minutes.
5. Confirm `run_completed`/`screen_view` events appear under Analytics → DebugView (enable debug mode via `adb shell setprop debug.firebase.analytics.app <package>` on Android for real-time verification instead of waiting ~24h for the standard dashboard).

## Self-Review

**Spec coverage:**
- Two-service architecture (`CrashReportingService`, `AnalyticsService`) → Tasks 2-3.
- `main.dart` init/`runZonedGuarded`/global handlers → Task 9.
- Explicit `recordError` at existing silent catches → Task 5 (`GameCubit._fireCompletionHook`/`_submit`), Task 6 (`EngagementCubit`'s four prize-check catches). The spec's guess that these lived in `AdService`/`LeaderboardService`/`FriendsService` didn't match the actual code (those services throw rather than swallow); the real silent catches were found one layer up, in the cubits that consume them — noted inline in Tasks 5-6 rather than silently diverging from the spec.
- `run_completed` → Task 5. `onboarding_completed` → Task 8. `ad_load_failed`/`ad_shown` → Task 4. `duel_started`/`duel_completed` → Task 7. `streak_broken` → Tasks 5 (per-tier) and 6 (headline) — the spec named one `streak_broken` event without distinguishing the two streak systems this codebase actually has; both are covered with a `streakType` param distinguishing them.
- Automatic `screen_view` via `NavigatorObserver` → Task 9.
- Fail-safe behavior (never block gameplay, swallow sync AND async failures) → built into `CrashReportingService`/`AnalyticsService` themselves (Tasks 2-3), so every consumer gets it for free.
- Testability without real platform channels → the seam pattern in Tasks 2-3, exercised by every task's tests.
- Privacy/no-PII → no task logs anything beyond difficulty/score/tier/streak-length/ad-type/bool, matching the spec's stated param set.
- Firebase dependency + free tier → Task 1.

**Placeholder scan:** No "TBD"/"TODO"/vague steps. Task 5's first test-writing step deliberately shows two dead-end drafts before the real test — that's intentional pedagogy (explaining why the naive approach doesn't work) rather than an unresolved placeholder; the final, actually-added tests are unambiguous and complete.

**Type consistency:** `onError` is `void Function(Object error, StackTrace? stack, {bool fatal})?` everywhere it appears (`GameCubit`, `EngagementCubit`, and `CrashReportingService.recordError`'s own signature) — identical across Tasks 2, 5, 6, 9. `onAnalyticsEvent` is `void Function(String name, [Map<String, Object?>? params])?` everywhere it appears (`GameCubit`, `EngagementCubit`, `DuelCubit`, and `AnalyticsService.logEvent`'s own signature) — identical across Tasks 3, 5, 6, 7, 9. `AdService.showRewarded`'s new `adType` parameter is a plain `String` at all 7 call sites (Task 4) and in `AdService` itself — no enum was introduced, avoiding a mismatch risk between an enum and string-keyed analytics params.

**Out of scope (confirmed untouched):** CI pipeline, fuller analytics taxonomy (cosmetics/loot/almanac/XP events), crash-report user-identifier correlation, Firebase Console dashboard/alerting config — none of Tasks 1-9 touch these, consistent with the spec's Out of Scope section.
