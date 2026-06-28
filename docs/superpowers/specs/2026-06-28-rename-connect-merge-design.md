# Rebrand: "Merge Count" → "Connect Merge"

**Date:** 2026-06-28
**Status:** Approved design — ready for implementation planning
**Type:** Full rebrand (display name, identity, deep links, copy, internal package)

---

## Summary

Rename the app from **Merge Count** to **Connect Merge** across every layer:
user-facing display name, Android applicationId, iOS bundle identifier, deep-link
scheme and domain references, in-app copy, and the Dart package name. The app
remains unpublished, so identity changes carry no orphaned-install risk.

The Hive box name (`connect_merge`) is already correct and requires no change.

---

## Decisions (locked)

| Concern | Old | New |
|---|---|---|
| Display name | `Merge Count` | `Connect Merge` |
| Dart package name (`pubspec.yaml`) | `merge_count` | `connect_merge` |
| Android `namespace` | `com.kiddulu.merge_count` | `com.kiddulu.connect_merge` |
| Android `applicationId` | `com.kiddulu.merge_count` | `com.kiddulu.connect_merge` |
| iOS `PRODUCT_BUNDLE_IDENTIFIER` (Runner) | `com.kiddulu.mergeCount` | `com.kiddulu.connectMerge` |
| iOS `PRODUCT_BUNDLE_IDENTIFIER` (RunnerTests) | `com.kiddulu.mergeCount.RunnerTests` | `com.kiddulu.connectMerge.RunnerTests` |
| Deep-link custom scheme | `mergecount://` | `connectmerge://` |
| App Links / Universal Links domain | `mergecount.app` | `connectmerge.app` |
| iOS URL-type name | `com.mergecount.invite` | `com.connectmerge.invite` |
| Hive box name | `connect_merge` | *(already correct — no change)* |

---

## Files to change

### Config files

#### `pubspec.yaml`
- `name: merge_count` → `name: connect_merge`
- `description:` — update wording to reflect new name

#### `android/app/build.gradle.kts`
- `namespace = "com.kiddulu.merge_count"` → `"com.kiddulu.connect_merge"`
- `applicationId = "com.kiddulu.merge_count"` → `"com.kiddulu.connect_merge"`

#### `android/app/src/main/AndroidManifest.xml`
- `android:label="Merge Count"` → `android:label="Connect Merge"`
- `android:scheme="mergecount"` (×2 intent-filter data entries) → `"connectmerge"`
- `android:host="mergecount.app"` → `"connectmerge.app"`
- `android:pathPrefix="/invite"` and `/duel` — unchanged
- Comments referencing `mergecount://` and `mergecount.app` — update text

#### `ios/Runner/Info.plist`
- `CFBundleDisplayName`: `Merge Count` → `Connect Merge`
- `CFBundleName`: `Merge Count` → `Connect Merge`
- `CFBundleURLSchemes` array entry: `mergecount` → `connectmerge`
- `CFBundleURLName`: `com.mergecount.invite` → `com.connectmerge.invite`
- `NSContactsUsageDescription`: replace "Merge Count" with "Connect Merge"
- Comments referencing `mergecount://` and `mergecount.app` — update text

#### `ios/Runner.xcodeproj/project.pbxproj`
- All 5 occurrences of `PRODUCT_BUNDLE_IDENTIFIER`:
  - `com.kiddulu.mergeCount` → `com.kiddulu.connectMerge`
  - `com.kiddulu.mergeCount.RunnerTests` → `com.kiddulu.connectMerge.RunnerTests`

---

### Dart source files

#### `lib/domain/models/duel_challenge.dart`
- `static const String _httpsHost = 'mergecount.app'` → `'connectmerge.app'`
- Doc comment scheme references: `mergecount://` → `connectmerge://`
- Doc comment domain references: `mergecount.app` → `connectmerge.app`

#### `lib/domain/engine/share_grid_builder.dart`
- `'Merge Count $date'` → `'Connect Merge $date'`

#### `lib/presentation/screens/friends_screen.dart`
- `'Add me on Merge Count! $link'` → `'Add me on Connect Merge! $link'`
- `subject: 'Merge Count invite'` → `subject: 'Connect Merge invite'`
- `'No contacts are on Merge Count yet.'` → `'No contacts are on Connect Merge yet.'`
- `'Found ${matches.length} contact(s) on Merge Count.'` → `'... on Connect Merge.'`

#### `lib/presentation/screens/score_share_screen.dart`
- `'Merge Count — ${difficulty.label}: '` → `'Connect Merge — ${difficulty.label}: '`
- `'Add me on Merge Count! ...'` → `'Add me on Connect Merge! ...'`
- `subject: 'Merge Count'` → `subject: 'Connect Merge'`

#### `lib/infrastructure/friends_service.dart`
- `'https://mergecount.app/invite/$code'` → `'https://connectmerge.app/invite/$code'`

#### `lib/infrastructure/deep_link_service.dart`
- Doc comment domain and scheme references → `connectmerge.app` / `connectmerge://`

#### `lib/presentation/theme/tokens.dart`
- Doc comment: `/// Design tokens for Merge Count.` → `/// Design tokens for Connect Merge.`

#### `lib/main.dart`
- Code comments referencing `mergecount://` → `connectmerge://`

---

### Test files (63 files)

All test files import `package:merge_count/...`. These must all change to
`package:connect_merge/...`. This is a mechanical find-and-replace; no test
logic changes.

Affected test directories:
- `test/application/` (13 files)
- `test/domain/` (18 files)
- `test/infrastructure/` (9 files)
- `test/presentation/` (13 files)

---

## Manual steps (out of scope for automation)

These cannot be done by code changes alone and must be handled separately:

1. **Android signing keystore** — if `android/key.properties` references an alias
   tied to the old `merge_count` identity, generate a new keystore for
   `connect_merge` (app is unpublished so no migration needed).
2. **Supabase project config** — if any Edge Function or RLS policy stores the
   bundle ID `com.kiddulu.merge_count`, update it there.
3. **`connectmerge.app` domain** — configure `assetlinks.json` (Android) and
   `apple-app-site-association` (iOS) when the domain is set up.
4. **App Store Connect / Google Play Console** — create new app listings under
   the new bundle ID if the old ones were registered.

---

## Non-goals

- No game logic changes
- No UI layout changes
- No database schema changes
- No Hive box name change (already `connect_merge`)
