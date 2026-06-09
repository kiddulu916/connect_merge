# Rebrand: "Merge Loop" → "Merge Count"

**Date:** 2026-06-08
**Status:** Approved design, pending implementation plan
**Type:** Full rebrand (display name, identity, deep links, copy, internal code, config)

## Summary

Rename the app from **Merge Loop** to **Merge Count** across every layer:
user-facing display name, app identity (applicationId / bundle ID), deep-link
scheme and domain, in-app and share copy, internal Dart package and class names,
and project config. The app has **not** been published, so identity changes are
free (no orphaned installs) and a fresh release keystore will be created
out-of-band.

## Decisions (locked)

| Concern | Old | New |
|---|---|---|
| Display name | `Merge Loop` | `Merge Count` |
| Android applicationId / namespace | `com.kiddulu.merge_loop` | `com.kiddulu.merge_count` |
| iOS bundle identifier | `com.mergeloop.mergeLoop` | `com.kiddulu.mergeCount` |
| Deep-link custom scheme | `mergeloop://` | `mergecount://` |
| App Links / Universal Links domain | `mergeloop.app` | `mergecount.app` |
| iOS URL-type id | `com.mergeloop.invite` | `com.mergecount.invite` |
| Dart package name | `merge_loop` | `merge_count` |
| Root Dart classes | `MergeLoopApp` / `_MergeLoopAppState` | `MergeCountApp` / `_MergeCountAppState` |
| MethodChannel name | `merge_loop/facebook_share` | `merge_count/facebook_share` |
| Hive box name | `merge_loop` | `merge_count` |

### Platform constraint
Apple bundle identifiers permit only alphanumerics, hyphens, and periods — **no
underscores**. Therefore Android uses `com.kiddulu.merge_count` (underscore legal)
and iOS uses the camelCase `com.kiddulu.mergeCount`. Same brand and org prefix,
platform-legal spelling on each side.

### Hidden coupling
The Facebook-share `MethodChannel` name is a string contract duplicated in Dart
(`lib/infrastructure/score_sharer.dart`) and Kotlin
(`android/.../MainActivity.kt`). It produces no compile error if the two sides
drift — the share button fails silently. **Both sides must change together.**

## Change inventory

### A. App identity
- `android/app/build.gradle.kts`: `namespace` and `applicationId` → `com.kiddulu.merge_count`.
- Move `android/app/src/main/kotlin/com/kiddulu/merge_loop/MainActivity.kt` →
  `.../kotlin/com/kiddulu/merge_count/MainActivity.kt`; update the
  `package com.kiddulu.merge_loop` declaration to `com.kiddulu.merge_count`.
- `ios/Runner.xcodeproj/project.pbxproj` (6 occurrences):
  `com.mergeloop.mergeLoop` → `com.kiddulu.mergeCount` and
  `com.mergeloop.mergeLoop.RunnerTests` → `com.kiddulu.mergeCount.RunnerTests`.

### B. Display name
- `android/app/src/main/AndroidManifest.xml`: `android:label` → `Merge Count`.
- `ios/Runner/Info.plist`: `CFBundleDisplayName` and `CFBundleName` → `Merge Count`.
- `lib/main.dart`: `MaterialApp.title` → `Merge Count`.
- `lib/presentation/screens/tier_select_screen.dart`: header `Text('Merge Count')`.

### C. Deep links
- Custom scheme `mergeloop` → `mergecount`; domain `mergeloop.app` → `mergecount.app`;
  iOS URL-type id `com.mergeloop.invite` → `com.mergecount.invite`.
- Files: `AndroidManifest.xml` (scheme/host data + comments),
  `ios/Runner/Info.plist` (URL scheme, URL-type id, comments),
  `lib/infrastructure/friends_service.dart` (`inviteLink`, https link),
  `lib/infrastructure/deep_link_service.dart` (doc comments + `uri.scheme == 'mergecount'`),
  `lib/main.dart` (comment).

### D. User-facing copy
Replace every visible "Merge Loop" with "Merge Count":
- `ios/Runner/Info.plist` `NSContactsUsageDescription`.
- `lib/presentation/screens/score_share_screen.dart` (share text + subject).
- `lib/presentation/screens/friends_screen.dart` (invite text, subject, empty/found states).
- `lib/domain/engine/share_grid_builder.dart` (`'Merge Count $date'`).
- `lib/infrastructure/score_sharer.dart` (share subject).
- Comments in `AndroidManifest.xml` / `Info.plist` referencing the name.

### E. Internal code identifiers
- `pubspec.yaml`: `name: merge_count`.
- All **177** `package:merge_loop/...` imports across `lib/` and `test/` →
  `package:merge_count/...`.
- `lib/main.dart`: `MergeLoopApp` → `MergeCountApp`, `_MergeLoopAppState` →
  `_MergeCountAppState`, and `runApp(MergeCountApp(...))`.
- `MethodChannel` name `merge_loop/facebook_share` → `merge_count/facebook_share`
  in **both** `lib/infrastructure/score_sharer.dart` and `MainActivity.kt`.
- `lib/infrastructure/hive_storage_service.dart`: `_boxName` → `merge_count`
  (orphans any local dev data; acceptable while unpublished).
- `lib/infrastructure/score_sharer.dart`: temp file `merge_loop_score.png` →
  `merge_count_score.png` (cosmetic).

### F. Config & docs
- `supabase/config.toml`: `project_id` → `merge_count`.
- `.env.example`: header comment.
- `README.md`: title + body references.
- `docs/BUILD.md`: references.

## Deliberately NOT changed
- Historical records under `docs/superpowers/plans/`, `docs/superpowers/specs/`,
  and `docs/ideation/` (including files named `*merge-loop*`). These document
  past work; rewriting them would falsify the record.

## Out of scope (manual / external, owner: user)
- Generate a new release keystore and wire the signing config.
- Acquire `mergecount.app` and host `assetlinks.json` (Android App Links) and
  `apple-app-site-association` (iOS Universal Links). The `https://` invite
  fallback only verifies once the domain serves these; the `mergecount://`
  custom scheme works without any domain.
- Rename the Supabase project in the dashboard (the local `config.toml`
  `project_id` is the linked-project label only).
- Optionally rename the repo folder `Projects\merge_loop`.

## Testing / verification
1. `flutter analyze` — must pass; catches every broken import and renamed class.
2. `flutter test` — must pass; proves the 177 import renames, the MethodChannel
   rename, and the box-name change are internally consistent.
3. Final grep sweep: zero matches for `merge_loop|mergeloop|mergeLoop|MergeLoop`
   outside the preserved historical docs in §"Deliberately NOT changed".
4. Spot-check: the Dart `MethodChannel` string equals the Kotlin `channelName`
   string exactly.
