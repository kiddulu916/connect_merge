# Flutter wraps release builds with R8 (minify + resource shrink). The rules
# below keep classes that are resolved reflectively and would otherwise be
# stripped/renamed, causing startup crashes in the release APK.

# --- WorkManager + Room ---------------------------------------------------
# flutter_local_notifications schedules notifications via androidx.work, which
# is backed by a Room database (WorkDatabase). Room loads its generated *_Impl
# class by name at runtime, so R8 must not remove or rename it.
-keep class androidx.work.** { *; }
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keepclassmembers class * extends androidx.room.RoomDatabase { <init>(); }
-keep class * extends androidx.work.Worker
-keep class * extends androidx.work.ListenableWorker { <init>(...); }

# --- flutter_local_notifications -----------------------------------------
-keep class com.dexterous.** { *; }

# --- Google Mobile Ads ----------------------------------------------------
-keep class com.google.android.gms.ads.** { *; }
