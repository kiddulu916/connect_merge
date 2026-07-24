import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Thrown by [AuthService.setDisplayName] when the name is already in use by
/// another player (unique index on lower(display_name), migration 0008).
class DisplayNameTakenException implements Exception {}

enum GoogleAuthResult { linked, collision, adopted }

/// The native credential is kept as one value so a collision warning and its
/// later confirmation can never refer to different Google accounts.
class GoogleCredential {
  final String idToken;
  final String accessToken;

  const GoogleCredential({
    required this.idToken,
    required this.accessToken,
  });

  @override
  bool operator ==(Object other) =>
      other is GoogleCredential &&
      other.idToken == idToken &&
      other.accessToken == accessToken;

  @override
  int get hashCode => Object.hash(idToken, accessToken);
}

typedef GoogleCredentialAction = Future<void> Function(
  GoogleCredential credential,
  String nonce,
);

/// Anonymous auth, Google identity linking, and display-name management.
///
/// This is deliberately the only class that imports either auth plugin. The
/// rest of the app works in terms of account outcomes, so native credentials
/// and provider sessions cannot leak across presentation or application code.
class AuthService {
  static const _webClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');
  static final String _processNonce = _generateNonce();
  static Future<void>? _googleInitialization;

  final SupabaseClient? _client;
  final String _nonce;
  final Future<GoogleCredential> Function() _acquireGoogleCredential;
  final GoogleCredentialAction _linkGoogleCredential;
  final GoogleCredentialAction _adoptGoogleCredential;
  final Future<void> Function() _supabaseSignOut;
  final Future<void> Function() _googleSignOut;

  GoogleCredential? _collisionCredential;

  AuthService(SupabaseClient client)
      : _client = client,
        _nonce = _processNonce,
        _acquireGoogleCredential = _acquireProductionCredential,
        _linkGoogleCredential = ((credential, nonce) async {
          await client.auth.linkIdentityWithIdToken(
            provider: OAuthProvider.google,
            idToken: credential.idToken,
            accessToken: credential.accessToken,
            nonce: nonce,
          );
        }),
        _adoptGoogleCredential = ((credential, nonce) async {
          await client.auth.signInWithIdToken(
            provider: OAuthProvider.google,
            idToken: credential.idToken,
            accessToken: credential.accessToken,
            nonce: nonce,
          );
        }),
        _supabaseSignOut = client.auth.signOut,
        _googleSignOut = (() async {
          // A restored Supabase session can reach Sign out before any Google
          // picker has initialized the v7 singleton in this process.
          await _initializeGoogle();
          await GoogleSignIn.instance.signOut();
        });

  /// Test-only seams keep the consent/cache state machine independently
  /// testable without platform channels or a live Supabase project.
  AuthService.withGoogleSeams({
    required String nonce,
    required Future<GoogleCredential> Function() acquireGoogleCredential,
    required GoogleCredentialAction linkGoogleCredential,
    required GoogleCredentialAction adoptGoogleCredential,
    required Future<void> Function() supabaseSignOut,
    required Future<void> Function() googleSignOut,
  })  : _client = null,
        _nonce = nonce,
        _acquireGoogleCredential = acquireGoogleCredential,
        _linkGoogleCredential = linkGoogleCredential,
        _adoptGoogleCredential = adoptGoogleCredential,
        _supabaseSignOut = supabaseSignOut,
        _googleSignOut = googleSignOut;

  SupabaseClient get _requiredClient =>
      _client ?? (throw StateError('This auth seam has no Supabase client.'));

  /// The current authenticated user id, or null when signed out.
  String? get currentUserId => _client?.auth.currentUser?.id;

  /// True when there is an active session.
  bool get isSignedIn => _client?.auth.currentSession != null;

  /// Whether the current Supabase user has a linked Google identity.
  bool get hasGoogleIdentity =>
      _client?.auth.currentUser?.identities
          ?.any((identity) => identity.provider == 'google') ??
      false;

  /// Ensure an anonymous session exists. Idempotent: returns immediately if a
  /// session is already present, otherwise signs in anonymously.
  Future<void> ensureSignedIn() async {
    if (_requiredClient.auth.currentSession != null) return;
    await _requiredClient.auth.signInAnonymously();
  }

  /// Link Google into the anonymous user in place. A collision does not touch
  /// the Supabase session; it retains only this attempt's credential until the
  /// destructive account-switch warning is either confirmed or cancelled.
  Future<GoogleAuthResult> signInWithGoogle() async {
    _collisionCredential = null;
    try {
      final credential = await _acquireGoogleCredential();
      try {
        await _linkGoogleCredential(credential, _nonce);
        return GoogleAuthResult.linked;
      } on AuthException catch (error) {
        if (error.statusCode == '422' &&
            error.code == 'identity_already_exists') {
          _collisionCredential = credential;
          return GoogleAuthResult.collision;
        }
        rethrow;
      }
    } catch (_) {
      if (_collisionCredential == null) cancelGoogleAdoption();
      rethrow;
    }
  }

  /// Consume the credential whose collision the player actually saw. It is
  /// cleared before network I/O so failure and double-tap paths cannot reuse a
  /// stale consent decision.
  Future<GoogleAuthResult> confirmAdopt() async {
    final credential = _collisionCredential;
    if (credential == null) {
      throw StateError('No Google account adoption is awaiting confirmation.');
    }
    _collisionCredential = null;
    await _adoptGoogleCredential(credential, _nonce);
    return GoogleAuthResult.adopted;
  }

  void cancelGoogleAdoption() {
    _collisionCredential = null;
  }

  /// Sign out both providers even if the first one fails. Leaving Google's
  /// native session alive would silently select the old account next time.
  Future<void> signOut() async {
    _collisionCredential = null;
    Object? firstError;
    StackTrace? firstStack;
    try {
      await _supabaseSignOut();
    } catch (error, stack) {
      firstError = error;
      firstStack = stack;
    }
    try {
      await _googleSignOut();
    } catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }

  /// The current player's display name, or null if they haven't set one yet.
  Future<String?> displayName() async {
    final id = currentUserId;
    if (id == null) return null;
    final row = await _requiredClient
        .from('players')
        .select('display_name')
        .eq('id', id)
        .maybeSingle();
    if (row == null) return null;
    return row['display_name'] as String?;
  }

  Future<bool> hasDisplayName() async => (await displayName()) != null;

  Future<({String? name, String? avatar})> profile() async {
    final id = currentUserId;
    if (id == null) return (name: null, avatar: null);
    final row = await _requiredClient
        .from('players')
        .select('display_name, avatar')
        .eq('id', id)
        .maybeSingle();
    return (
      name: row?['display_name'] as String?,
      avatar: row?['avatar'] as String?,
    );
  }

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
      await _requiredClient.from('players').upsert({
        'id': id,
        'display_name': trimmed,
        if (avatar != null) 'avatar': avatar,
      });
    } on PostgrestException catch (error) {
      if (error.code == '23505') throw DisplayNameTakenException();
      rethrow;
    }
  }

  Future<void> deleteAccount() async {
    if (currentUserId == null) {
      throw StateError('Cannot delete an account before signing in.');
    }
    await _requiredClient.functions.invoke('delete-account');
    await signOut();
  }

  static String _generateNonce() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static Future<void> _initializeGoogle() =>
      _googleInitialization ??= (() async {
        if (_webClientId.isEmpty) {
          throw StateError(
            'GOOGLE_WEB_CLIENT_ID must be supplied as a dart-define.',
          );
        }
        final hashedNonce =
            sha256.convert(utf8.encode(_processNonce)).toString();
        await GoogleSignIn.instance.initialize(
          serverClientId: _webClientId,
          nonce: hashedNonce,
        );
      })();

  static Future<GoogleCredential> _acquireProductionCredential() async {
    await _initializeGoogle();
    final account = await GoogleSignIn.instance.authenticate();
    final idToken = account.authentication.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw StateError('Google did not return an ID token.');
    }
    final authorization = await account.authorizationClient.authorizeScopes(
      const ['email', 'profile'],
    );
    return GoogleCredential(
      idToken: idToken,
      accessToken: authorization.accessToken,
    );
  }
}
