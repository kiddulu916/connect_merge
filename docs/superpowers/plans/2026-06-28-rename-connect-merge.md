# Connect Merge Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the app from "Merge Count" to "Connect Merge" across every layer — display name, Android/iOS identity, deep-link domain, Dart package name, in-app copy, and test imports.

**Architecture:** Four sequential tasks: (1) Dart package name + test imports, (2) Dart source strings & constants + their test assertions, (3) Android config + Kotlin package directory, (4) iOS config. Each task ends with a passing test run and a commit. No game logic or UI layout changes.

**Tech Stack:** Flutter/Dart, Kotlin (Android), Xcode project (iOS plist + pbxproj), Gradle (build.gradle.kts).

## Global Constraints

- New Dart package name: `connect_merge`
- New Android applicationId/namespace: `com.kiddulu.connect_merge`
- New iOS bundle identifier: `com.kiddulu.connectMerge`
- New deep-link custom scheme: `connectmerge://`
- New domain for App Links / Universal Links: `connectmerge.app`
- Hive box name is already `connect_merge` — do NOT change it
- `channelName` in `MainActivity.kt` is already `connect_merge/facebook_share` — do NOT change it
- No game logic, UI layout, or database schema changes

---

## Task 1: Dart package name + test file imports

Renames the Flutter package from `merge_count` to `connect_merge` in `pubspec.yaml`, then bulk-replaces all `package:merge_count/` import paths in the 63 test files. The lib/ source files are NOT touched here — only the package declaration and test imports.

**Files:**
- Modify: `pubspec.yaml`
- Modify (bulk): all `test/**/*.dart` (63 files) — import paths only

**Interfaces:**
- Produces: a Flutter project whose package is `connect_merge`; test imports resolve; `flutter test` passes

---

- [ ] **Step 1: Update `pubspec.yaml`**

Replace lines 1–2:

```yaml
name: connect_merge
description: A deterministic daily spatial merge puzzle.
```

The rest of `pubspec.yaml` (from line 3 onward) is unchanged.

- [ ] **Step 2: Bulk-replace test imports (PowerShell)**

Run from the repo root:

```powershell
Get-ChildItem -Path "test" -Recurse -Filter "*.dart" | ForEach-Object {
    $content = Get-Content $_.FullName -Raw
    $updated = $content -replace 'package:merge_count/', 'package:connect_merge/'
    if ($content -ne $updated) { Set-Content -Path $_.FullName -Value $updated -NoNewline }
}
```

Expected: no output (silent success). Verify with:

```powershell
Select-String -Path "test/**/*.dart" -Pattern "package:merge_count/" -Recurse
```

Expected: no matches.

- [ ] **Step 3: Fetch updated dependencies**

```powershell
flutter pub get
```

Expected output ends with: `Got dependencies!`

- [ ] **Step 4: Run the full test suite**

```powershell
flutter test
```

Expected: all tests pass. If any test fails with `Unable to resolve package 'merge_count'`, re-check Step 2 missed a file.

- [ ] **Step 5: Commit**

```powershell
git add pubspec.yaml
git add test/
git commit -m "refactor(rename): update Dart package name and test imports to connect_merge"
```

---

## Task 2: Dart source strings, constants, and test assertions

Updates every user-visible string, URL constant, and doc comment in `lib/` that still says "Merge Count" or "mergecount". Also updates the 3 test assertions that match against old strings. No change to deep-link scheme strings (`connectmerge://`) that were already updated in a prior pass.

**Files:**
- Modify: `lib/domain/models/duel_challenge.dart`
- Modify: `lib/domain/engine/share_grid_builder.dart`
- Modify: `lib/presentation/screens/friends_screen.dart`
- Modify: `lib/presentation/screens/score_share_screen.dart`
- Modify: `lib/infrastructure/friends_service.dart`
- Modify: `lib/infrastructure/deep_link_service.dart`
- Modify: `lib/presentation/theme/tokens.dart`
- Modify: `lib/main.dart`
- Modify: `test/domain/engine/share_grid_builder_test.dart`
- Modify: `test/infrastructure/friends_service_test.dart`
- Modify: `test/infrastructure/deep_link_service_test.dart`

**Interfaces:**
- Consumes: package renamed in Task 1 (test imports resolve)
- Produces: zero occurrences of `Merge Count` or `mergecount` anywhere in `lib/` or `test/`

---

- [ ] **Step 1: Fix `lib/domain/models/duel_challenge.dart`**

Three changes in this file:

Line 14 — update doc comment scheme:
```
// old:
///   `mergecount://duel/<date>/<diff>/<score>/<name>`
// new:
///   `connectmerge://duel/<date>/<diff>/<score>/<name>`
```

Line 15 — update doc comment domain:
```
// old:
///   `https://mergecount.app/duel/<date>/<diff>/<score>/<name>`
// new:
///   `https://connectmerge.app/duel/<date>/<diff>/<score>/<name>`
```

Line 40 — update the runtime constant (this is the only non-comment change in this file):
```dart
// old:
static const String _httpsHost = 'mergecount.app';
// new:
static const String _httpsHost = 'connectmerge.app';
```

- [ ] **Step 2: Fix `lib/domain/engine/share_grid_builder.dart` line 11**

```dart
// old:
      ..writeln('Merge Count $date')
// new:
      ..writeln('Connect Merge $date')
```

- [ ] **Step 3: Fix `lib/presentation/screens/friends_screen.dart` (4 strings)**

Line 114:
```dart
// old:
    final text = 'Add me on Merge Count! $link';
// new:
    final text = 'Add me on Connect Merge! $link';
```

Line 117:
```dart
// old:
            .share(ShareParams(text: t, subject: 'Merge Count invite'));
// new:
            .share(ShareParams(text: t, subject: 'Connect Merge invite'));
```

Line 143:
```dart
// old:
            ? 'No contacts are on Merge Count yet.'
// new:
            ? 'No contacts are on Connect Merge yet.'
```

Line 144:
```dart
// old:
            : 'Found ${matches.length} contact(s) on Merge Count.';
// new:
            : 'Found ${matches.length} contact(s) on Connect Merge.';
```

- [ ] **Step 4: Fix `lib/presentation/screens/score_share_screen.dart` (3 strings)**

Line 295:
```dart
// old:
    final buf = StringBuffer('Merge Count — ${difficulty.label}: '
// new:
    final buf = StringBuffer('Connect Merge — ${difficulty.label}: '
```

Line 304:
```dart
// old:
    final text = 'Add me on Merge Count! ${FriendsService.inviteLink(code)}';
// new:
    final text = 'Add me on Connect Merge! ${FriendsService.inviteLink(code)}';
```

Line 312:
```dart
// old:
      .share(ShareParams(text: text, subject: 'Merge Count'));
// new:
      .share(ShareParams(text: text, subject: 'Connect Merge'));
```

- [ ] **Step 5: Fix `lib/infrastructure/friends_service.dart` line 85**

```dart
// old:
      'https://mergecount.app/invite/$code';
// new:
      'https://connectmerge.app/invite/$code';
```

- [ ] **Step 6: Fix `lib/infrastructure/deep_link_service.dart` (2 comment lines)**

Line 12:
```
// old:
///   https://mergecount.app/invite/<code>  (App Links / Universal Links fallback)
// new:
///   https://connectmerge.app/invite/<code>  (App Links / Universal Links fallback)
```

Line 14:
```
// old:
///   `https://mergecount.app/duel/<date>/<diff>/<score>/<name>`   (https fallback)
// new:
///   `https://connectmerge.app/duel/<date>/<diff>/<score>/<name>`   (https fallback)
```

- [ ] **Step 7: Fix `lib/presentation/theme/tokens.dart` line 3**

```dart
// old:
/// Design tokens for Merge Count.
// new:
/// Design tokens for Connect Merge.
```

- [ ] **Step 8: Fix `lib/main.dart` (2 comment lines)**

Lines 95–96:
```dart
// old:
  // Deep links: invites (mergecount://invite/<code>) AND duels
  // (mergecount://duel/...). Duels need no backend (the challenge rides in the
// new:
  // Deep links: invites (connectmerge://invite/<code>) AND duels
  // (connectmerge://duel/...). Duels need no backend (the challenge rides in the
```

- [ ] **Step 9: Fix test assertions — `test/domain/engine/share_grid_builder_test.dart` line 27**

```dart
// old:
    expect(lines[0], 'Merge Count 2026-06-06');
// new:
    expect(lines[0], 'Connect Merge 2026-06-06');
```

- [ ] **Step 10: Fix test assertions — `test/infrastructure/friends_service_test.dart` line 54**

```dart
// old:
          'https://mergecount.app/invite/ABCD2345');
// new:
          'https://connectmerge.app/invite/ABCD2345');
```

- [ ] **Step 11: Fix test assertions — `test/infrastructure/deep_link_service_test.dart` line 18**

```dart
// old:
            'https://mergecount.app/invite/WXYZ7654'),
// new:
            'https://connectmerge.app/invite/WXYZ7654'),
```

- [ ] **Step 12: Verify no old strings remain in lib/ or test/**

```powershell
Select-String -Path "lib/**/*.dart","test/**/*.dart" -Pattern "merge_count|mergecount|Merge Count" -Recurse
```

Expected: zero matches.

- [ ] **Step 13: Run the full test suite**

```powershell
flutter test
```

Expected: all tests pass.

- [ ] **Step 14: Commit**

```powershell
git add lib/ test/infrastructure/deep_link_service_test.dart test/infrastructure/friends_service_test.dart test/domain/engine/share_grid_builder_test.dart
git commit -m "refactor(rename): update Dart source strings and constants to Connect Merge"
```

---

## Task 3: Android identity and Kotlin package directory

Updates `build.gradle.kts`, `AndroidManifest.xml`, and moves `MainActivity.kt` into the new package directory. The `channelName` inside `MainActivity.kt` (`connect_merge/facebook_share`) is already correct and must not be changed.

**Files:**
- Modify: `android/app/build.gradle.kts`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Create: `android/app/src/main/kotlin/com/kiddulu/connect_merge/MainActivity.kt`
- Delete: `android/app/src/main/kotlin/com/kiddulu/merge_count/MainActivity.kt`

**Interfaces:**
- Produces: `flutter build apk --debug` succeeds with applicationId `com.kiddulu.connect_merge`

---

- [ ] **Step 1: Update `android/app/build.gradle.kts`**

Change lines 19 and 31:

```kotlin
// old (line 19):
    namespace = "com.kiddulu.merge_count"
// new:
    namespace = "com.kiddulu.connect_merge"

// old (line 31):
        applicationId = "com.kiddulu.merge_count"
// new:
        applicationId = "com.kiddulu.connect_merge"
```

- [ ] **Step 2: Update `android/app/src/main/AndroidManifest.xml`**

Make these targeted replacements (all other lines are unchanged):

Line 2 comment:
```xml
<!-- old: -->
    <!-- Contacts is OPT-IN and used ONLY to find friends already on Merge Count.
<!-- new: -->
    <!-- Contacts is OPT-IN and used ONLY to find friends already on Connect Merge.
```

Line 9 label:
```xml
<!-- old: -->
        android:label="Merge Count"
<!-- new: -->
        android:label="Connect Merge"
```

Line 36 comment:
```xml
<!-- old: -->
            <!-- Invite deep links: mergecount://invite/<code> -->
<!-- new: -->
            <!-- Invite deep links: connectmerge://invite/<code> -->
```

Line 41 scheme (custom-scheme intent filter):
```xml
<!-- old: -->
                <data android:scheme="mergecount" android:host="invite"/>
<!-- new: -->
                <data android:scheme="connectmerge" android:host="invite"/>
```

Line 43 comment:
```xml
<!-- old: -->
            <!-- App Links (https) fallback: https://mergecount.app/invite/<code>.
<!-- new: -->
            <!-- App Links (https) fallback: https://connectmerge.app/invite/<code>.
```

Line 50 https host:
```xml
<!-- old: -->
                <data android:scheme="https" android:host="mergecount.app"
<!-- new: -->
                <data android:scheme="https" android:host="connectmerge.app"
```

- [ ] **Step 3: Create the new Kotlin package directory and move `MainActivity.kt`**

Create `android/app/src/main/kotlin/com/kiddulu/connect_merge/MainActivity.kt` with this exact content (only the package declaration changes from `merge_count` to `connect_merge`; `channelName` stays as-is):

```kotlin
package com.kiddulu.connect_merge

import android.content.ActivityNotFoundException
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "connect_merge/facebook_share"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "shareImage") {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null) {
                        result.success(false)
                    } else {
                        result.success(shareToFacebook(bytes))
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    /** Write the PNG and hand it to the Facebook app. Returns false if FB is
     *  not installed so Dart can fall back to the OS share sheet. */
    private fun shareToFacebook(bytes: ByteArray): Boolean {
        return try {
            val dir = File(cacheDir, "shared").apply { mkdirs() }
            val file = File(dir, "score.png")
            file.writeBytes(bytes)
            val uri = FileProvider.getUriForFile(
                this, "$packageName.fileprovider", file
            )
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "image/png"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                setPackage("com.facebook.katana")
            }
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        } catch (e: Exception) {
            false
        }
    }
}
```

- [ ] **Step 4: Delete the old Kotlin package directory**

```powershell
Remove-Item -Recurse -Force "android/app/src/main/kotlin/com/kiddulu/merge_count"
```

- [ ] **Step 5: Smoke-test Android build**

```powershell
flutter build apk --debug
```

Expected: `✓ Built build/app/outputs/flutter-apk/app-debug.apk`

If it fails with `package com.kiddulu.merge_count does not exist`, the old directory was not fully removed — re-run Step 4.

- [ ] **Step 6: Commit**

```powershell
git add android/
git commit -m "refactor(rename): update Android identity to com.kiddulu.connect_merge"
```

---

## Task 4: iOS identity (Info.plist + project.pbxproj)

Updates the iOS bundle identifier in the Xcode project file (5 occurrences) and all Connect Merge display/scheme entries in Info.plist. iOS builds require a Mac; on Windows you can only verify the file changes are correct — the full `flutter build ios` smoke-test is noted as a Mac-only step.

**Files:**
- Modify: `ios/Runner/Info.plist`
- Modify: `ios/Runner.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `CFBundleDisplayName` = `Connect Merge`; bundle ID = `com.kiddulu.connectMerge`; URL scheme = `connectmerge`

---

- [ ] **Step 1: Update `ios/Runner/Info.plist`**

Make these targeted replacements (all other lines are unchanged):

Line 7 comment:
```xml
	<!-- old: Contacts is OPT-IN and used ONLY to find friends already on Merge Count. -->
	<!-- new: Contacts is OPT-IN and used ONLY to find friends already on Connect Merge. -->
```

Line 12 usage description:
```xml
	<!-- old: -->
	<string>Merge Count can find friends who already play. Your contacts never leave your device — only secure, anonymized fingerprints are checked. You can always add friends by code instead.</string>
	<!-- new: -->
	<string>Connect Merge can find friends who already play. Your contacts never leave your device — only secure, anonymized fingerprints are checked. You can always add friends by code instead.</string>
```

Line 13 comment:
```xml
	<!-- old: Invite deep links: mergecount://invite/<code> -->
	<!-- new: Invite deep links: connectmerge://invite/<code> -->
```

Line 20 URL name:
```xml
			<!-- old: -->
			<string>com.mergecount.invite</string>
			<!-- new: -->
			<string>com.connectmerge.invite</string>
```

Line 23 URL scheme:
```xml
				<!-- old: -->
				<string>mergecount</string>
				<!-- new: -->
				<string>connectmerge</string>
```

Line 28 comment:
```xml
	<!-- old: apple-app-site-association hosted on mergecount.app; see spec Open Items. -->
	<!-- new: apple-app-site-association hosted on connectmerge.app; see spec Open Items. -->
```

Line 35 CFBundleDisplayName:
```xml
	<!-- old: -->
	<string>Merge Count</string>   ← under key CFBundleDisplayName
	<!-- new: -->
	<string>Connect Merge</string>
```

Line 43 CFBundleName:
```xml
	<!-- old: -->
	<string>Merge Count</string>   ← under key CFBundleName
	<!-- new: -->
	<string>Connect Merge</string>
```

- [ ] **Step 2: Update `ios/Runner.xcodeproj/project.pbxproj` (5 occurrences)**

Use PowerShell to do two find-and-replace passes (Runner tests first, then Runner itself, to avoid partial matches):

```powershell
$file = "ios/Runner.xcodeproj/project.pbxproj"
$content = Get-Content $file -Raw
$content = $content -replace 'com\.kiddulu\.mergeCount\.RunnerTests', 'com.kiddulu.connectMerge.RunnerTests'
$content = $content -replace 'com\.kiddulu\.mergeCount', 'com.kiddulu.connectMerge'
Set-Content -Path $file -Value $content -NoNewline
```

Verify:
```powershell
Select-String -Path "ios/Runner.xcodeproj/project.pbxproj" -Pattern "mergeCount"
```

Expected: zero matches.

- [ ] **Step 3: Verify no old iOS identifiers remain**

```powershell
Select-String -Path "ios/" -Pattern "mergecount|mergeCount|Merge Count" -Recurse
```

Expected: zero matches.

- [ ] **Step 4: Flutter analyze (cross-platform check)**

```powershell
flutter analyze
```

Expected: `No issues found!` (or only pre-existing warnings unrelated to this rename).

- [ ] **Step 5: [Mac only] iOS smoke-test**

On a Mac with Xcode:
```bash
flutter build ios --no-codesign
```

Expected: `Build complete.`

- [ ] **Step 6: Commit**

```powershell
git add ios/
git commit -m "refactor(rename): update iOS identity to com.kiddulu.connectMerge / Connect Merge"
```

---

## Post-implementation manual steps (not automated)

After all 4 tasks are merged:

1. **Android signing keystore** — if `android/key.properties` points to a keystore whose alias references `merge_count`, generate a new keystore for `connect_merge`. The app is unpublished so no migration is needed.
2. **Supabase Edge Functions / RLS** — search for any policy or function that hardcodes `com.kiddulu.merge_count` as an app identifier and update it.
3. **`connectmerge.app` domain** — host `assetlinks.json` (Android App Links) and `apple-app-site-association` (iOS Universal Links) on this domain when it is registered.
4. **Store listings** — create new app entries on Google Play Console and App Store Connect under the new bundle IDs if the old entries were registered.
