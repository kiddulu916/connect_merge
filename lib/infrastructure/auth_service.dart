import 'package:supabase_flutter/supabase_flutter.dart';

/// Thrown by [AuthService.setDisplayName] when the name is already in use by
/// another player (unique index on lower(display_name), migration 0008).
class DisplayNameTakenException implements Exception {}

/// Anonymous sign-in + display-name management.
///
/// Isolates supabase_flutter auth so the rest of the app never imports the
/// plugin directly (mirrors [AdService]). Identity is anonymous-first: a fresh
/// install gets an anonymous session; the player then sets a display name which
/// is stored in the `players` table.
class AuthService {
  final SupabaseClient _client;

  AuthService(this._client);

  /// The current authenticated user id, or null when signed out.
  String? get currentUserId => _client.auth.currentUser?.id;

  /// True when there is an active session.
  bool get isSignedIn => _client.auth.currentSession != null;

  /// Ensure an anonymous session exists. Idempotent: returns immediately if a
  /// session is already present, otherwise signs in anonymously.
  Future<void> ensureSignedIn() async {
    if (_client.auth.currentSession != null) return;
    await _client.auth.signInAnonymously();
  }

  /// The current player's display name, or null if they haven't set one yet
  /// (first run). Reads the player's own `players` row.
  Future<String?> displayName() async {
    final id = currentUserId;
    if (id == null) return null;
    final row = await _client
        .from('players')
        .select('display_name')
        .eq('id', id)
        .maybeSingle();
    if (row == null) return null;
    return row['display_name'] as String?;
  }

  /// True once a display name has been set (i.e. the player has onboarded).
  Future<bool> hasDisplayName() async => (await displayName()) != null;

  /// Display name + avatar in a single row read (Profile screen). Both null
  /// pre-onboarding or when signed out.
  Future<({String? name, String? avatar})> profile() async {
    final id = currentUserId;
    if (id == null) return (name: null, avatar: null);
    final row = await _client
        .from('players')
        .select('display_name, avatar')
        .eq('id', id)
        .maybeSingle();
    return (
      name: row?['display_name'] as String?,
      avatar: row?['avatar'] as String?,
    );
  }

  /// Persist the player's display name (+ optional avatar). Upserts the
  /// player's own row, keyed by their auth id.
  Future<void> setDisplayName(String name, {String? avatar}) async {
    final id = currentUserId;
    if (id == null) {
      throw StateError('Cannot set display name before signing in.');
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 20) {
      throw ArgumentError('Display name must be 1-20 characters.');
    }
    try {
      await _client.from('players').upsert({
        'id': id,
        'display_name': trimmed,
        if (avatar != null) 'avatar': avatar,
      });
    } on PostgrestException catch (e) {
      // 23505 = unique_violation: another player owns this name
      // (case-insensitive, migration 0008).
      if (e.code == '23505') throw DisplayNameTakenException();
      rethrow;
    }
  }

  /// Permanently delete the player's account and all server-side data.
  ///
  /// Calls the delete-account Edge Function with the caller's own session JWT
  /// (the function deletes auth.uid(); no id is sent, so nothing to spoof),
  /// then signs out locally. Callers are responsible for wiping on-device
  /// storage and returning to onboarding.
  Future<void> deleteAccount() async {
    if (currentUserId == null) {
      throw StateError('Cannot delete an account before signing in.');
    }
    await _client.functions.invoke('delete-account');
    await _client.auth.signOut();
  }
}
