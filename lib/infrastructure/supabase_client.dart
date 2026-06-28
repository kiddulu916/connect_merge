import 'package:supabase_flutter/supabase_flutter.dart';

/// Single initialized Supabase client. URL + anon key come from `--dart-define`
/// (never committed). Isolates the plugin so the rest of the app uses
/// [AuthService] / [LeaderboardService] instead of importing supabase_flutter.
class SupabaseConfig {
  /// Compile-time injected via:
  ///   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
  static const String url = String.fromEnvironment('SUPABASE_URL');
  static const String anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// True only when both values were provided at build time. When false, the
  /// app runs in offline/local-only mode (leaderboard disabled) rather than
  /// crashing — Phase 1 stands alone.
  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;
}

/// Initializes the global Supabase singleton. No-op when not configured.
/// Returns true when Supabase is ready to use.
Future<bool> initSupabase() async {
  if (!SupabaseConfig.isConfigured) return false;
  await Supabase.initialize(
    url: SupabaseConfig.url,
    // The publishable (anon) key arrives via --dart-define SUPABASE_ANON_KEY.
    publishableKey: SupabaseConfig.anonKey,
  );
  return true;
}

/// The initialized client. Only valid after [initSupabase] returned true.
SupabaseClient get supabase => Supabase.instance.client;
