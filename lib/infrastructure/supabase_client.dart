import 'package:supabase_flutter/supabase_flutter.dart';

/// Single initialized Supabase client. URL + anon key default to the
/// production project below (the publishable key is safe to ship in the
/// client app — see .env.example) and can be overridden per-build via
/// `--dart-define`. Isolates the plugin so the rest of the app uses
/// [AuthService] / [LeaderboardService] instead of importing supabase_flutter.
class SupabaseConfig {
  /// Overridable via:
  ///   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
  static const String url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://nnoqqchqprfikhabrrjt.supabase.co',
  );
  static const String anonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_PvT0UB1Sfb2tNlrShKLMpw_6EXNdAi_',
  );

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
