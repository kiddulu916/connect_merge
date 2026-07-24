import 'package:connect_merge/infrastructure/auth_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _first = GoogleCredential(
  idToken: 'first-id-token',
  accessToken: 'first-access-token',
);
const _second = GoogleCredential(
  idToken: 'second-id-token',
  accessToken: 'second-access-token',
);

void main() {
  test('collision caches the exact credential and confirm consumes it once',
      () async {
    GoogleCredential? adopted;
    final auth = AuthService.withGoogleSeams(
      nonce: 'raw-nonce',
      acquireGoogleCredential: () async => _first,
      linkGoogleCredential: (_, __) async => throw const AuthException(
        'already linked',
        statusCode: '422',
        code: 'identity_already_exists',
      ),
      adoptGoogleCredential: (credential, nonce) async {
        adopted = credential;
        expect(nonce, 'raw-nonce');
      },
      supabaseSignOut: () async {},
      googleSignOut: () async {},
    );

    expect(await auth.signInWithGoogle(), GoogleAuthResult.collision);
    expect(await auth.confirmAdopt(), GoogleAuthResult.adopted);
    expect(adopted, _first);
    await expectLater(auth.confirmAdopt(), throwsStateError);
  });

  test('cancel clears the cached collision credential', () async {
    final auth = _collidingAuth();
    expect(await auth.signInWithGoogle(), GoogleAuthResult.collision);
    auth.cancelGoogleAdoption();
    await expectLater(auth.confirmAdopt(), throwsStateError);
  });

  test('a new attempt clears an older collision before acquiring', () async {
    var attempts = 0;
    final auth = AuthService.withGoogleSeams(
      nonce: 'nonce',
      acquireGoogleCredential: () async {
        attempts++;
        if (attempts == 1) return _first;
        throw StateError('second picker failed');
      },
      linkGoogleCredential: (_, __) async => throw const AuthException(
        'already linked',
        statusCode: '422',
        code: 'identity_already_exists',
      ),
      adoptGoogleCredential: (_, __) async {},
      supabaseSignOut: () async {},
      googleSignOut: () async {},
    );

    expect(await auth.signInWithGoogle(), GoogleAuthResult.collision);
    await expectLater(auth.signInWithGoogle(), throwsStateError);
    await expectLater(auth.confirmAdopt(), throwsStateError);
  });

  test('link and adopt failures leave no cached credential', () async {
    final linkFailure = AuthService.withGoogleSeams(
      nonce: 'nonce',
      acquireGoogleCredential: () async => _first,
      linkGoogleCredential: (_, __) async => throw const AuthException(
        'not a collision',
        statusCode: '400',
        code: 'bad_token',
      ),
      adoptGoogleCredential: (_, __) async {},
      supabaseSignOut: () async {},
      googleSignOut: () async {},
    );
    await expectLater(
        linkFailure.signInWithGoogle(), throwsA(isA<AuthException>()));
    await expectLater(linkFailure.confirmAdopt(), throwsStateError);

    final adoptFailure = _collidingAuth(
      adopt: (_, __) async => throw StateError('adopt failed'),
    );
    expect(await adoptFailure.signInWithGoogle(), GoogleAuthResult.collision);
    await expectLater(adoptFailure.confirmAdopt(), throwsStateError);
    await expectLater(adoptFailure.confirmAdopt(), throwsStateError);
  });

  test('sign out clears cache and attempts both providers on failure',
      () async {
    var supabaseCalls = 0;
    var googleCalls = 0;
    final auth = _collidingAuth(
      supabaseSignOut: () async {
        supabaseCalls++;
        throw StateError('Supabase sign-out failed');
      },
      googleSignOut: () async => googleCalls++,
    );
    expect(await auth.signInWithGoogle(), GoogleAuthResult.collision);

    await expectLater(auth.signOut(), throwsStateError);
    expect(supabaseCalls, 1);
    expect(googleCalls, 1);
    await expectLater(auth.confirmAdopt(), throwsStateError);
  });

  test('successful link passes both tokens and raw nonce', () async {
    GoogleCredential? linked;
    String? linkedNonce;
    final auth = AuthService.withGoogleSeams(
      nonce: 'raw-nonce',
      acquireGoogleCredential: () async => _second,
      linkGoogleCredential: (credential, nonce) async {
        linked = credential;
        linkedNonce = nonce;
      },
      adoptGoogleCredential: (_, __) async {},
      supabaseSignOut: () async {},
      googleSignOut: () async {},
    );

    expect(await auth.signInWithGoogle(), GoogleAuthResult.linked);
    expect(linked, _second);
    expect(linkedNonce, 'raw-nonce');
  });
}

AuthService _collidingAuth({
  GoogleCredentialAction? adopt,
  Future<void> Function()? supabaseSignOut,
  Future<void> Function()? googleSignOut,
}) =>
    AuthService.withGoogleSeams(
      nonce: 'nonce',
      acquireGoogleCredential: () async => _first,
      linkGoogleCredential: (_, __) async => throw const AuthException(
        'already linked',
        statusCode: '422',
        code: 'identity_already_exists',
      ),
      adoptGoogleCredential: adopt ?? (_, __) async {},
      supabaseSignOut: supabaseSignOut ?? () async {},
      googleSignOut: googleSignOut ?? () async {},
    );
